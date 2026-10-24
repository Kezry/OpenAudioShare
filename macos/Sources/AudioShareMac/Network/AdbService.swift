import Foundation
@preconcurrency import Darwin

struct AdbDevice {
    var serial: String
    var state: String
    var model: String?
    var product: String?
    var name: String
}

enum AdbError: LocalizedError {
    case notFound
    case commandFailed(String)
    case noPermission(String)
    case noDevice
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "adb not found"
        case .commandFailed(let message):
            return "adb: \(message)"
        case .noPermission(let serial):
            return "USB debugging not authorised for \(serial)"
        case .noDevice:
            return "No Android device connected"
        case .installFailed(let message):
            return "APK install failed: \(message)"
        }
    }
}

final class AdbService {
    private let queue = DispatchQueue(label: "com.picapico.audioshare.adb")
    private(set) var adbPath: String?

    init() {
        adbPath = Self.locateAdb()
    }

    static func locateAdb() -> String? {
        var candidates: [String] = []
        if let resource = Bundle.main.resourceURL?.appendingPathComponent("adb").path {
            candidates.append(resource)
        }
        if let executable = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("adb").path {
            candidates.append(executable)
        }
        candidates += [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb",
            "/Applications/Android Studio.app/Contents/sdk/platform-tools/adb",
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        // Fall back to PATH.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", "adb"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty,
           FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    func hasAdb() -> Bool {
        adbPath != nil
    }

    @discardableResult
    func run(_ arguments: [String], timeout: TimeInterval = 30) throws -> String {
        guard let adbPath else { throw AdbError.notFound }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = arguments
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.1)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            throw AdbError.commandFailed("timeout: adb \(arguments.joined(separator: " "))")
        }

        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: outputData, encoding: .utf8) ?? ""
        let stderr = String(data: errorData, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let message = (stderr.isEmpty ? stdout : stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw AdbError.commandFailed(message.isEmpty ? "exit \(process.terminationStatus)" : message)
        }
        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func startServer() throws {
        _ = try? run(["start-server"], timeout: 10)
    }

    func devices() throws -> [AdbDevice] {
        let output = try run(["devices", "-l"], timeout: 15)
        var result: [AdbDevice] = []
        for line in output.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, !text.hasPrefix("List of devices"),
                  !text.hasPrefix("*") else { continue }
            let fields = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.count >= 2 else { continue }
            let serial = fields[0]
            let state = fields[1]
            var model: String?
            var product: String?
            for field in fields.dropFirst(2) {
                if field.hasPrefix("model:") { model = String(field.dropFirst(6)) }
                if field.hasPrefix("product:") { product = String(field.dropFirst(8)) }
            }
            let display = (model ?? serial).replacingOccurrences(of: "_", with: " ")
            result.append(AdbDevice(serial: serial, state: state, model: model,
                                    product: product, name: display))
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func marketingName(serial: String, fallback: String) -> String {
        if let value = try? run(["-s", serial, "shell", "getprop", "ro.config.marketing_name"], timeout: 8) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let manufacturer = try? run(["-s", serial, "shell", "getprop", "ro.product.manufacturer"], timeout: 8),
           !manufacturer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(manufacturer.trimmingCharacters(in: .whitespacesAndNewlines)) \(fallback)"
        }
        return fallback
    }

    func packageInstalled(serial: String) -> Bool {
        guard let output = try? run(["-s", serial, "shell", "pm", "path", "com.picapico.audioshare"], timeout: 10) else {
            return false
        }
        return output.contains("package:")
    }

    /// Ensures the Android app is present and running, then creates a TCP
    /// forward to the app's local abstract socket. Returns the local port.
    func prepareUSB(serial: String, apkPath: String?) throws -> Int {
        try startServer()
        if !packageInstalled(serial: serial) {
            guard let apkPath, FileManager.default.fileExists(atPath: apkPath) else {
                throw AdbError.installFailed("AudioShare.apk not found")
            }
            let remote = "/data/local/tmp/audioshare.apk"
            _ = try run(["-s", serial, "push", apkPath, remote], timeout: 120)
            _ = try run(["-s", serial, "shell", "pm", "install", "-r", remote], timeout: 120)
            _ = try? run(["-s", serial, "shell", "rm", "-f", remote], timeout: 10)
            _ = try? run(["-s", serial, "shell", "dumpsys", "deviceidle",
                          "whitelist", "+com.picapico.audioshare"], timeout: 10)
        }
        _ = try? run(["-s", serial, "shell", "am", "start", "-W",
                      "-n", "com.picapico.audioshare/.MainActivity"], timeout: 20)
        let port = try freePort()
        _ = try? run(["-s", serial, "forward", "--remove", "tcp:\(port)"], timeout: 5)
        _ = try run(["-s", serial, "forward", "tcp:\(port)",
                     "localabstract:picapico-audio-share"], timeout: 10)
        return port
    }

    func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AdbError.commandFailed("socket() failed") }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw AdbError.commandFailed("bind failed") }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard nameResult == 0 else { throw AdbError.commandFailed("getsockname failed") }
        return Int(UInt16(bigEndian: actual.sin_port))
    }

    func perform<T>(_ operation: @escaping () throws -> T, completion: @escaping (Result<T, Error>) -> Void) {
        queue.async {
            do {
                let value = try operation()
                DispatchQueue.main.async { completion(.success(value)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }
}
