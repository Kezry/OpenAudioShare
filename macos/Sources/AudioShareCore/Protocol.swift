import Foundation

/// Wire protocol shared with the existing Android app.
///
/// Audio connection:
///   "picapico-audio-share" | command(1) | sampleRate(Int32 LE)
///   | channelConfig(Int32 LE) | ... length-prefixed PCM16 frames ...
///   Android answers the handshake with a single ACK byte.
///
/// Control connection:
///   "picapico-audio-share" | command(1) | optional payload
///   Android closes the socket when the command has been handled.
public enum AudioShareProtocol {
    public static let headerString = "picapico-audio-share"
    public static let discoveryProbeString = "picapico-audio-share-find"
    public static let header = Data(headerString.utf8)

    public enum Command: UInt8 {
        case none = 0
        case audioData = 1
        case volume = 2
        case syncTime = 3
        case stop = 4
        case measureLatency = 5
        case setDelay = 6
    }

    public enum AndroidConstants {
        /// AudioFormat.CHANNEL_OUT_STEREO
        public static let channelOutStereo: Int32 = 12
        /// AudioFormat.CHANNEL_OUT_MONO
        public static let channelOutMono: Int32 = 4
    }

    public static let heartbeat = Data([0, 0, 0, 0])

    public static func audioHandshake(sampleRate: Int, channels: Int) -> Data {
        var data = Data()
        data.append(header)
        data.append(Command.audioData.rawValue)
        data.append(int32LE(Int32(sampleRate)))
        data.append(int32LE(channels >= 2
                            ? AndroidConstants.channelOutStereo
                            : AndroidConstants.channelOutMono))
        return data
    }

    public static func controlMessage(_ command: Command, payload: Data = Data()) -> Data {
        var data = Data()
        data.append(header)
        data.append(command.rawValue)
        data.append(payload)
        return data
    }

    public static func volumePayload(_ value: Int) -> Data {
        int32LE(Int32(max(0, min(100, value))))
    }

    public static func delayPayload(milliseconds: Int, applyNow: Bool) -> Data {
        var data = int32LE(Int32(max(0, milliseconds)))
        data.append(applyNow ? 1 : 0)
        return data
    }

    /// A length-prefixed PCM16 frame. `samples` must already be interleaved and
    /// contain exactly the channel layout announced in the handshake.
    public static func audioPacket(samples: [Int16]) -> Data {
        let byteCount = samples.count * MemoryLayout<Int16>.size
        var data = Data(capacity: 4 + byteCount)
        data.append(int32LE(Int32(byteCount)))
        samples.withUnsafeBytes { raw in
            data.append(contentsOf: raw)
        }
        return data
    }

    public static func int32LE(_ value: Int32) -> Data {
        var little = value.littleEndian
        return withUnsafeBytes(of: &little) { Data($0) }
    }

    public static func readInt32LE(_ data: Data, at offset: Int = 0) -> Int32? {
        guard data.count >= offset + 4 else { return nil }
        var value: UInt32 = 0
        for i in 0..<4 {
            value |= UInt32(data[data.startIndex + offset + i]) << (8 * i)
        }
        return Int32(bitPattern: value)
    }

    public static func parseDiscoveryReply(_ data: Data) -> (host: String, port: Int, httpPort: Int?)? {
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let parts = text.split(separator: "@", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, parts[0] == headerString,
              let port = Int(parts[1]), port > 0, port < 65_535 else { return nil }
        let httpPort = parts.count >= 3 ? Int(parts[2]) : nil
        return (headerString, port, httpPort)
    }
}

// MARK: - Endpoint parsing

public struct DeviceEndpoint: Equatable, Sendable, CustomStringConvertible {
    public var host: String
    public var port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    public static let defaultPort = 8088

    /// Accepts `192.168.1.20`, `192.168.1.20:8088`, `host:port` and
    /// `[fe80::1]:8088`.
    public init?(string: String, defaultPort: Int = DeviceEndpoint.defaultPort) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var host = trimmed
        var port = defaultPort
        if trimmed.hasPrefix("[") {
            guard let closing = trimmed.firstIndex(of: "]") else { return nil }
            host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closing])
            let remainder = trimmed[trimmed.index(after: closing)...]
            if remainder.hasPrefix(":") {
                guard let parsed = Int(remainder.dropFirst()), (1...65_535).contains(parsed) else { return nil }
                port = parsed
            } else if !remainder.isEmpty {
                return nil
            }
        } else {
            let colonCount = trimmed.filter { $0 == ":" }.count
            if colonCount == 1, let colon = trimmed.lastIndex(of: ":") {
                let possibleHost = String(trimmed[..<colon])
                let possiblePort = String(trimmed[trimmed.index(after: colon)...])
                if !possibleHost.isEmpty, !possiblePort.isEmpty,
                   possiblePort.allSatisfy(\.isNumber),
                   let parsed = Int(possiblePort), (1...65_535).contains(parsed) {
                    host = possibleHost
                    port = parsed
                } else if possiblePort.isEmpty {
                    return nil
                }
            }
        }

        host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !host.contains(" ") else { return nil }
        guard host.rangeOfCharacter(from: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".:-_"))) != nil else {
            return nil
        }
        self.host = host
        self.port = port
    }

    public var description: String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    public var normalizedID: String { description }
}

// MARK: - Frame extraction

public struct PCMFrame: Sendable {
    public var samples: [Int16]
    public var channels: Int
    public var sampleRate: Int

    public init(samples: [Int16], channels: Int, sampleRate: Int) {
        self.samples = samples
        self.channels = channels
        self.sampleRate = sampleRate
    }

    public var frameCount: Int {
        channels > 0 ? samples.count / channels : 0
    }
}

public enum ChannelExtractor {
    /// Returns interleaved samples for one logical output. A stereo target has
    /// two channels; every other target is mono.
    public static func extract(frame: PCMFrame,
                               channel: AudioChannel,
                               mode: ChannelMode,
                               sourceChannels: Int) -> [Int16]? {
        guard let indices = mode.sourceIndex(for: channel, sourceChannels: sourceChannels),
              !indices.isEmpty, frame.channels > 0 else { return nil }
        let frames = frame.samples.count / frame.channels
        guard frames > 0, indices.allSatisfy({ $0 < frame.channels }) else { return nil }

        var output = [Int16]()
        output.reserveCapacity(frames * indices.count)
        for frameIndex in 0..<frames {
            let base = frameIndex * frame.channels
            for index in indices {
                output.append(frame.samples[base + index])
            }
        }
        return output
    }
}
