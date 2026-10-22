import AudioShareCore
import Foundation
@preconcurrency import Darwin

final class Speaker: ObservableObject, Identifiable {
    let id = UUID()
    let isUSB: Bool
    let serial: String?
    let deviceName: String
    private(set) var endpointID: String

    @Published private(set) var status: ConnectStatus = .disconnected
    @Published private(set) var lastRTT: Int = 0
    @Published private(set) var channel: AudioChannel
    @Published private(set) var displayName: String

    var onStatusChanged: ((Speaker) -> Void)?
    var onUnexpectedDisconnect: ((Speaker) -> Void)?

    private let stateLock = NSLock()
    private let ioQueue: DispatchQueue
    private let readerQueue: DispatchQueue
    private let audioQueue: DispatchQueue
    private var socketFD: Int32 = -1
    private var isWriting = false
    private var lastWriteTime: UInt64 = 0
    private var currentStatus: ConnectStatus = .disconnected
    private var retried = false
    private var sampleRate = 48_000
    private var smoothedRTT = 0
    private var lastDelay = 0
    private var stopped = false

    private(set) var usbPort: Int?

    init(endpointID: String, channel: AudioChannel, isUSB: Bool = false,
         serial: String? = nil, name: String = "") {
        self.endpointID = endpointID
        self.channel = channel
        self.isUSB = isUSB
        self.serial = serial
        self.deviceName = name
        self.displayName = isUSB ? "\(name) [\(endpointID)]" : endpointID
        let token = UUID().uuidString
        self.ioQueue = DispatchQueue(label: "com.picapico.audioshare.speaker.io.\(token)")
        self.readerQueue = DispatchQueue(label: "com.picapico.audioshare.speaker.reader.\(token)")
        self.audioQueue = DispatchQueue(label: "com.picapico.audioshare.speaker.audio.\(token)")
    }

    var display: String {
        get { isUSB ? displayName : endpointID }
        set {
            guard !isUSB, status == .disconnected else { return }
            endpointID = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            displayName = endpointID
        }
    }

    var idReadOnly: Bool { isUSB || status != .disconnected }
    var removeVisible: Bool { !isUSB }
    var channelEnabled: Bool { status == .disconnected }
    var connectEnabled: Bool { channel != .none }
    var connected: Bool { status == .connected }
    var connecting: Bool { status == .connecting }
    var unconnected: Bool { status != .connected }
    var lastSentDelay: Int { lastDelay }
    var lastRTTValue: Int { lastRTT }

    var quality: Int {
        if lastRTT <= 0 { return 2 }
        if lastRTT <= 20 { return 0 }
        if lastRTT <= 50 { return 1 }
        return 2
    }

    func setChannel(_ channel: AudioChannel, force: Bool = false) {
        guard force || status == .disconnected else { return }
        self.channel = channel
    }

    func setUSBPort(_ port: Int) {
        usbPort = port
    }

    func setSampleRate(_ rate: Int) {
        sampleRate = rate
    }

    func connect(retry: Bool = false) {
        guard channel != .none else { return }
        if currentStatus == .connecting || currentStatus == .connected { return }
        stopped = false
        setStatus(.connecting, notify: true)
        let rate = sampleRate
        ioQueue.async { [weak self] in
            guard let self else { return }
            do {
                let endpoint = try self.endpoint()
                if !retry {
                    // Close a session left behind by a previous PC/app run.
                    _ = self.sendControl(.stop, timeout: 1.0, requireConnected: false,
                                         host: endpoint.host, port: endpoint.port)
                }
                let fd = try Self.openSocket(host: endpoint.host, port: endpoint.port, timeout: 3)
                try self.performHandshake(fd: fd, sampleRate: rate)
                self.stateLock.lock()
                self.socketFD = fd
                self.stateLock.unlock()
                self.retried = false
                self.setStatus(.connected, notify: true)
                self.startReader(fd: fd)
                Log.info("speaker connected: \(self.endpointID)")
            } catch {
                Log.error("speaker connect failed \(self.endpointID): \(error.localizedDescription)")
                self.closeSocket()
                self.setStatus(.disconnected, notify: true)
            }
        }
    }

    func disconnect(notify: Bool = false) {
        closeSocket()
        let wasConnected = currentStatus == .connected
        setStatus(.disconnected, notify: true)
        if notify && wasConnected {
            onUnexpectedDisconnect?(self)
        }
    }

    func dispose() {
        stopped = true
        closeSocket()
        setStatus(.disconnected, notify: false)
    }

    // MARK: - Endpoint

    private func endpoint() throws -> DeviceEndpoint {
        if isUSB {
            guard let usbPort, usbPort > 0 else {
                throw NSError(domain: "AudioShare", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "USB port forward is missing"])
            }
            return DeviceEndpoint(host: "127.0.0.1", port: usbPort)
        }
        guard let endpoint = DeviceEndpoint(string: endpointID) else {
            throw NSError(domain: "AudioShare", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: L10n.t("ipParseError")])
        }
        return endpoint
    }

    private func performHandshake(fd: Int32, sampleRate: Int) throws {
        let handshake = AudioShareProtocol.audioHandshake(sampleRate: sampleRate,
                                                           channels: channel == .stereo ? 2 : 1)
        try Self.sendAll(fd: fd, data: handshake)
        var ack: UInt8 = 0
        let received = try Self.receive(fd: fd, buffer: &ack, count: 1, timeout: 5)
        guard received == 1 else {
            throw NSError(domain: "AudioShare", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "player did not acknowledge stream"])
        }
    }

    // MARK: - Audio

    func send(frame: PCMFrame, mode: ChannelMode) {
        guard currentStatus == .connected else { return }
        guard let samples = ChannelExtractor.extract(
            frame: frame, channel: channel, mode: mode, sourceChannels: frame.channels
        ) else { return }
        let packet = AudioShareProtocol.audioPacket(samples: samples)

        stateLock.lock()
        if isWriting {
            stateLock.unlock()
            return
        }
        isWriting = true
        lastWriteTime = DispatchTime.now().uptimeNanoseconds
        let fd = socketFD
        stateLock.unlock()

        audioQueue.async { [weak self] in
            guard let self else { return }
            var failed = false
            if fd >= 0 {
                do {
                    try Self.sendAll(fd: fd, data: packet)
                } catch {
                    failed = true
                }
            } else {
                failed = true
            }
            self.stateLock.lock()
            self.isWriting = false
            self.stateLock.unlock()
            if failed {
                self.handleWriteFailure()
            }
        }
    }

    func sendHeartbeat() {
        guard currentStatus == .connected else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        stateLock.lock()
        let elapsed = now &- lastWriteTime
        if elapsed < 5_000_000_000 {
            stateLock.unlock()
            return
        }
        if isWriting {
            stateLock.unlock()
            return
        }
        isWriting = true
        lastWriteTime = now
        let fd = socketFD
        stateLock.unlock()

        audioQueue.async { [weak self] in
            guard let self else { return }
            var failed = false
            if fd >= 0 {
                do {
                    try Self.sendAll(fd: fd, data: AudioShareProtocol.heartbeat)
                } catch {
                    failed = true
                }
            } else {
                failed = true
            }
            self.stateLock.lock()
            self.isWriting = false
            self.stateLock.unlock()
            if failed { self.handleWriteFailure() }
        }
    }

    private func handleWriteFailure() {
        guard currentStatus == .connected else { return }
        Log.warning("speaker write failed: \(endpointID)")
        closeSocket()
        if !retried {
            retried = true
            setStatus(.connecting, notify: true)
            ioQueue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, !self.stopped else { return }
                let rate = self.sampleRate
                do {
                    let endpoint = try self.endpoint()
                    let fd = try Self.openSocket(host: endpoint.host, port: endpoint.port, timeout: 3)
                    try self.performHandshake(fd: fd, sampleRate: rate)
                    self.stateLock.lock()
                    self.socketFD = fd
                    self.stateLock.unlock()
                    self.retried = false
                    self.setStatus(.connected, notify: true)
                    self.startReader(fd: fd)
                    Log.info("speaker reconnected: \(self.endpointID)")
                } catch {
                    self.closeSocket()
                    self.setStatus(.disconnected, notify: true)
                    self.onUnexpectedDisconnect?(self)
                }
            }
        } else {
            setStatus(.disconnected, notify: true)
            onUnexpectedDisconnect?(self)
        }
    }

    // MARK: - Reader

    private func startReader(fd: Int32) {
        readerQueue.async { [weak self] in
            guard let self else { return }
            var byte: UInt8 = 0
            while !self.stopped {
                let count = recv(fd, &byte, 1, 0)
                if count > 0 { continue }
                if count == 0 { break }
                if errno == EINTR { continue }
                break
            }
            guard !self.stopped else { return }
            Log.info("speaker socket closed by remote: \(self.endpointID)")
            self.closeSocket()
            if self.currentStatus == .connected {
                self.setStatus(.disconnected, notify: true)
                self.onUnexpectedDisconnect?(self)
            }
        }
    }

    // MARK: - Control

    @discardableResult
    func setVolume(_ value: Int) -> Bool {
        guard currentStatus == .connected else { return false }
        let payload = AudioShareProtocol.volumePayload(value)
        ioQueue.async { [weak self] in
            self?.sendControl(.volume, payload: payload)
        }
        return true
    }

    @discardableResult
    func syncTime() -> Bool {
        guard currentStatus == .connected else { return false }
        ioQueue.async { [weak self] in
            self?.sendControl(.syncTime)
        }
        return true
    }

    @discardableResult
    func setDelay(milliseconds: Int, applyNow: Bool) -> Bool {
        lastDelay = max(0, milliseconds)
        guard currentStatus == .connected else { return false }
        let payload = AudioShareProtocol.delayPayload(milliseconds: milliseconds, applyNow: applyNow)
        ioQueue.async { [weak self] in
            self?.sendControl(.setDelay, payload: payload)
        }
        return true
    }

    func measureLatency(completion: @escaping (Int) -> Void) {
        guard currentStatus == .connected else {
            DispatchQueue.main.async { completion(-1) }
            return
        }
        ioQueue.async { [weak self] in
            guard let self else { return }
            let start = DispatchTime.now().uptimeNanoseconds
            let endpoint: DeviceEndpoint
            do { endpoint = try self.endpoint() } catch {
                DispatchQueue.main.async { completion(-1) }
                return
            }
            let ok = self.sendControl(.measureLatency, timeout: 3.0,
                                      requireConnected: false,
                                      host: endpoint.host, port: endpoint.port,
                                      waitForClose: true)
            let end = DispatchTime.now().uptimeNanoseconds
            let raw = ok ? Int((end - start) / 1_000_000) : -1
            if raw >= 0 {
                if self.smoothedRTT == 0 {
                    self.smoothedRTT = raw
                } else {
                    self.smoothedRTT = Int(0.6 * Double(raw) + 0.4 * Double(self.smoothedRTT))
                }
                DispatchQueue.main.async {
                    self.lastRTT = self.smoothedRTT
                    completion(raw)
                }
            } else {
                DispatchQueue.main.async {
                    self.lastRTT = -1
                    completion(-1)
                }
            }
        }
    }

    @discardableResult
    private func sendControl(_ command: AudioShareProtocol.Command,
                             payload: Data = Data(),
                             timeout: TimeInterval = 3.0,
                             requireConnected: Bool = true,
                             host: String? = nil,
                             port: Int? = nil,
                             waitForClose: Bool = true) -> Bool {
        if requireConnected && currentStatus != .connected { return false }
        do {
            let endpoint: DeviceEndpoint
            if let host, let port {
                endpoint = DeviceEndpoint(host: host, port: port)
            } else {
                endpoint = try self.endpoint()
            }
            let fd = try Self.openSocket(host: endpoint.host, port: endpoint.port, timeout: timeout)
            defer { close(fd) }
            let message = AudioShareProtocol.controlMessage(command, payload: payload)
            try Self.sendAll(fd: fd, data: message)
            _ = shutdown(fd, SHUT_WR)
            if waitForClose {
                var buffer = [UInt8](repeating: 0, count: 64)
                let deadline = Date().addingTimeInterval(timeout)
                while Date() < deadline {
                    let wait = Int32(max(0, min(200, deadline.timeIntervalSinceNow * 1_000)))
                    var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    let result = poll(&pollFD, 1, wait)
                    if result < 0 { break }
                    if result == 0 { continue }
                    let count = recv(fd, &buffer, buffer.count, 0)
                    if count <= 0 { break }
                }
            }
            return true
        } catch {
            return false
        }
    }

    // MARK: - State / socket helpers

    private func setStatus(_ newStatus: ConnectStatus, notify: Bool) {
        stateLock.lock()
        if currentStatus == newStatus {
            stateLock.unlock()
            return
        }
        currentStatus = newStatus
        stateLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.status = newStatus
            if notify { self.onStatusChanged?(self) }
        }
    }

    private func closeSocket() {
        stateLock.lock()
        let fd = socketFD
        socketFD = -1
        isWriting = false
        stateLock.unlock()
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
    }

    private struct SocketError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    private static func openSocket(host: String, port: Int, timeout: TimeInterval) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var results: UnsafeMutablePointer<addrinfo>?
        let lookup = getaddrinfo(host, String(port), &hints, &results)
        guard lookup == 0, let first = results else {
            throw SocketError(message: String(cString: gai_strerror(lookup)))
        }
        defer { freeaddrinfo(first) }

        var pointer: UnsafeMutablePointer<addrinfo>? = first
        var lastError = "connect failed"
        while let current = pointer {
            defer { pointer = current.pointee.ai_next }
            let fd = socket(current.pointee.ai_family, current.pointee.ai_socktype,
                            current.pointee.ai_protocol)
            if fd < 0 { continue }
            let flags = fcntl(fd, F_GETFL, 0)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            let result = Darwin.connect(fd, current.pointee.ai_addr, current.pointee.ai_addrlen)
            var connected = result == 0
            if result != 0 && errno == EINPROGRESS {
                var pollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let wait = Int32(timeout * 1_000)
                if poll(&pollFD, 1, wait) > 0 {
                    var socketError: Int32 = 0
                    var length = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length)
                    connected = socketError == 0
                    if !connected {
                        lastError = String(cString: strerror(socketError))
                    }
                } else {
                    lastError = "connect timeout"
                }
            } else if result != 0 {
                lastError = String(cString: strerror(errno))
            }
            if connected {
                _ = fcntl(fd, F_SETFL, flags)
                var noDelay: Int32 = 1
                setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &noDelay,
                           socklen_t(MemoryLayout<Int32>.size))
                var timeoutValue = timeval(tv_sec: 10, tv_usec: 0)
                setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeoutValue,
                           socklen_t(MemoryLayout<timeval>.size))
                return fd
            }
            close(fd)
        }
        throw SocketError(message: lastError)
    }

    private static func sendAll(fd: Int32, data: Data) throws {
        var sent = 0
        while sent < data.count {
            let result = data.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.send(fd, base.advanced(by: sent), data.count - sent, 0)
            }
            if result <= 0 {
                if errno == EINTR { continue }
                throw SocketError(message: String(cString: strerror(errno)))
            }
            sent += result
        }
    }

    private static func receive(fd: Int32, buffer: UnsafeMutableRawPointer,
                                count: Int, timeout: TimeInterval) throws -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let wait = Int32(max(0, min(250, deadline.timeIntervalSinceNow * 1_000)))
            let result = poll(&pollFD, 1, wait)
            if result < 0 {
                if errno == EINTR { continue }
                throw SocketError(message: String(cString: strerror(errno)))
            }
            if result == 0 { continue }
            let received = recv(fd, buffer, count, 0)
            if received >= 0 { return received }
            if errno == EINTR { continue }
            throw SocketError(message: String(cString: strerror(errno)))
        }
        throw SocketError(message: "timeout")
    }
}
