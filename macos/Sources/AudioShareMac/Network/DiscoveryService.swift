import AudioShareCore
import Foundation
@preconcurrency import Darwin

/// UDP discovery compatible with both the existing Android app and the
/// Windows client. It listens on one of the ports used by Android's broadcast
/// timer and can actively probe all 58261...58270 ports.
final class DiscoveryService {
    var onDevice: ((String, Int) -> Void)?

    private let queue = DispatchQueue(label: "com.picapico.audioshare.discovery")
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var started = false
    private var boundPort: UInt16 = 0

    func start() {
        queue.async { [weak self] in
            guard let self, !self.started else { return }
            self.openSocket()
            self.started = true
            self.searchLocked()
        }
    }

    func search() {
        queue.async { [weak self] in
            guard let self, self.started else { return }
            self.searchLocked()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.started = false
            self.source?.cancel()
            self.source = nil
            if self.fd >= 0 {
                close(self.fd)
                self.fd = -1
            }
        }
    }

    private func openSocket() {
        let socketFD = socket(AF_INET, SOCK_DGRAM, 0)
        guard socketFD >= 0 else {
            Log.error("discovery: socket() failed")
            return
        }

        var reuse: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(socketFD, SOL_SOCKET, SO_BROADCAST, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var selected: UInt16 = 0
        for port in 58_261...58_270 {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(port).bigEndian
            address.sin_addr = in_addr(s_addr: INADDR_ANY)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if result == 0 {
                selected = UInt16(port)
                break
            }
        }

        if selected == 0 {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = 0
            address.sin_addr = in_addr(s_addr: INADDR_ANY)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if result != 0 {
                close(socketFD)
                Log.error("discovery: unable to bind any UDP port")
                return
            }
        }

        let flags = fcntl(socketFD, F_GETFL, 0)
        _ = fcntl(socketFD, F_SETFL, flags | O_NONBLOCK)

        fd = socketFD
        boundPort = selected
        let readSource = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
        readSource.setEventHandler { [weak self] in
            self?.readAvailable()
        }
        readSource.setCancelHandler {
            // fd is closed by stop().
        }
        source = readSource
        readSource.resume()
        Log.info("discovery listening on UDP \(selected)")
    }

    private func readAvailable() {
        guard fd >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 512)
        while true {
            var sender = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let received = buffer.withUnsafeMutableBytes { raw in
                withUnsafeMutablePointer(to: &sender) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, raw.baseAddress, raw.count, 0, $0, &length)
                    }
                }
            }
            if received <= 0 { break }
            let data = Data(buffer.prefix(received))
            guard let reply = AudioShareProtocol.parseDiscoveryReply(data) else { continue }
            var hostBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            _ = withUnsafePointer(to: &sender.sin_addr) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(INET_ADDRSTRLEN)) {
                    inet_ntop(AF_INET, $0, &hostBuffer, socklen_t(INET_ADDRSTRLEN))
                }
            }
            let host = String(cString: hostBuffer)
            guard !host.isEmpty else { continue }
            Log.info("discovered \(host):\(reply.port)")
            DispatchQueue.main.async { [weak self] in
                self?.onDevice?(host, reply.port)
            }
        }
    }

    private func searchLocked() {
        guard fd >= 0 else { return }
        let destinations = Self.broadcastAddresses() + ["255.255.255.255"]
        let probe = Data(AudioShareProtocol.discoveryProbeString.utf8)
        for round in 0..<3 {
            queue.asyncAfter(deadline: .now() + Double(round) * 0.3) { [weak self] in
                guard let self, self.fd >= 0 else { return }
                for host in destinations {
                    for port in 58_261...58_270 {
                        self.send(probe: probe, host: host, port: UInt16(port))
                    }
                }
            }
        }
        Log.info("discovery probe sent on \(destinations.count) interface(s)")
    }

    private func send(probe: Data, host: String, port: UInt16) {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return }
        _ = probe.withUnsafeBytes { raw in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, raw.baseAddress, raw.count, 0, $0,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private static func broadcastAddresses() -> [String] {
        var result = Set<String>()
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return [] }
        defer { freeifaddrs(interfaces) }
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            guard let address = current.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  (current.pointee.ifa_flags & UInt32(IFF_BROADCAST)) != 0,
                  let broadcast = current.pointee.ifa_dstaddr else { continue }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var sin = broadcast.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            _ = withUnsafePointer(to: &sin.sin_addr) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(INET_ADDRSTRLEN)) {
                    inet_ntop(AF_INET, $0, &buffer, socklen_t(INET_ADDRSTRLEN))
                }
            }
            let value = String(cString: buffer)
            if !value.isEmpty { result.insert(value) }
        }
        return Array(result)
    }
}
