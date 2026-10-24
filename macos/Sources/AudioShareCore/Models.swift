import Foundation

// MARK: - Channels

public enum AudioChannel: Int, Codable, CaseIterable, Sendable {
    case none = 0
    case left = 4
    case right = 8
    case stereo = 12
    case center = 16
    case lfe = 17
    case sideLeft = 18
    case sideRight = 19
    case backLeft = 20
    case backRight = 21
    case backCenter = 22

    /// Values are kept identical to the Windows enum so a config copied from
    /// the Windows app still decodes to the same logical channel.
    public var key: String {
        switch self {
        case .none: return "none"
        case .left: return "left"
        case .right: return "right"
        case .stereo: return "stereo"
        case .center: return "center"
        case .lfe: return "lfe"
        case .sideLeft: return "sideLeft"
        case .sideRight: return "sideRight"
        case .backLeft: return "backLeft"
        case .backRight: return "backRight"
        case .backCenter: return "backCenter"
        }
    }

    public init?(key: String) {
        switch key {
        case "none": self = .none
        case "left": self = .left
        case "right": self = .right
        case "stereo": self = .stereo
        case "center": self = .center
        case "lfe": self = .lfe
        case "sideLeft": self = .sideLeft
        case "sideRight": self = .sideRight
        case "backLeft": self = .backLeft
        case "backRight": self = .backRight
        case "backCenter": self = .backCenter
        default: return nil
        }
    }
}

public enum ChannelMode: Int, Codable, CaseIterable, Sendable {
    case stereo = 0
    case ch21 = 1
    case ch51 = 2
    case ch71 = 3

    public var captureChannels: Int {
        switch self {
        case .stereo: return 2
        case .ch21, .ch51: return 6
        case .ch71: return 8
        }
    }

    public var speakerChannels: [AudioChannel] {
        switch self {
        case .stereo:
            return [.left, .right]
        case .ch21:
            return [.left, .right, .lfe]
        case .ch51:
            return [.left, .right, .center, .lfe, .backLeft, .backRight]
        case .ch71:
            return [.left, .right, .center, .lfe, .sideLeft, .sideRight, .backLeft, .backRight]
        }
    }

    public func isValid(_ channel: AudioChannel) -> Bool {
        if channel == .none || channel == .stereo { return true }
        return speakerChannels.contains(channel)
    }

    /// Channels the current hardware can actually provide. A stereo output can
    /// only offer stereo/left/right, while an 8-channel device additionally
    /// offers centre, LFE, side and rear channels.
    public func availableSpeakerChannels(sourceChannels: Int) -> [AudioChannel] {
        var channels: [AudioChannel] = [.stereo]
        for channel in speakerChannels {
            guard channel != .stereo else { continue }
            guard let _ = sourceIndex(for: channel, sourceChannels: sourceChannels) else { continue }
            if !channels.contains(channel) { channels.append(channel) }
        }
        channels.append(.none)
        return channels
    }

    /// Index of a logical channel inside the captured interleaved stream.
    /// Core Audio's standard layouts are:
    ///   5.1: L R C LFE Ls Rs
    ///   7.1: L R C LFE Ls Rs Lrs Rrs
    public func sourceIndex(for channel: AudioChannel, sourceChannels: Int) -> [Int]? {
        guard sourceChannels > 0 else { return nil }
        switch channel {
        case .stereo:
            if sourceChannels >= 2 { return [0, 1] }
            return nil
        case .left:
            return sourceChannels >= 2 ? [0] : nil
        case .right:
            return sourceChannels >= 2 ? [1] : nil
        case .center:
            return sourceChannels >= 6 ? [2] : nil
        case .lfe:
            return sourceChannels >= 6 ? [3] : nil
        case .backLeft:
            if sourceChannels >= 8 { return [6] }
            if sourceChannels >= 6 { return [4] }
            return nil
        case .backRight:
            if sourceChannels >= 8 { return [7] }
            if sourceChannels >= 6 { return [5] }
            return nil
        case .sideLeft:
            return sourceChannels >= 8 ? [4] : nil
        case .sideRight:
            return sourceChannels >= 8 ? [5] : nil
        case .backCenter:
            return nil
        case .none:
            return nil
        }
    }
}

// MARK: - Capture settings

public enum CaptureMode: Int, Codable, CaseIterable, Sendable {
    case `default` = 0
    case eventSync = 1
    case lowLatency = 2
    case compatible = 3

    /// The Windows selector maps to WASAPI sync/buffer choices. On macOS the
    /// closest equivalent is the HAL IO buffer size requested from Core Audio.
    public var bufferMilliseconds: Int {
        switch self {
        case .default: return 100
        case .eventSync: return 100
        case .lowLatency: return 20
        case .compatible: return 200
        }
    }
}

public enum CaptureProfile: Int, Codable, CaseIterable, Sendable {
    case auto = 0
    case generic = 1
    case realtek = 2
    case dolby = 3
    case smartAudio = 4

    public var effectiveForMac: CaptureProfile {
        self == .auto ? .generic : self
    }
}

public enum ConnectStatus: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
}

// MARK: - Settings

public struct DeviceSetting: Codable, Equatable, Sendable {
    public var id: String
    public var channel: AudioChannel

    public init(id: String, channel: AudioChannel = .none) {
        self.id = id
        self.channel = channel
    }
}

public struct AppSettings: Codable, Sendable {
    public var audioUID: String = ""
    public var adbDevices: [DeviceSetting] = []
    public var ipDevices: [DeviceSetting] = []
    public var channelMode: ChannelMode = .stereo
    public var sampleRate: Int = 48_000
    public var volume: Int = 50
    public var gain: Int = 100
    public var captureMode: CaptureMode = .default
    public var captureModeChosen: Bool = false
    public var captureProfile: CaptureProfile = .auto
    public var autoGain: Bool = false
    public var isUSB: Bool = true
    public var volumeFollowSystem: Bool = true
    public var acrylic: Bool = true
    public var autoConnect: Bool = false
    public var apkPath: String? = nil
    public var language: String? = nil

    public init() {}

    enum CodingKeys: String, CodingKey {
        case audioUID, adbDevices, ipDevices, channelMode, sampleRate, volume, gain
        case captureMode, captureModeChosen, captureProfile, autoGain, isUSB
        case volumeFollowSystem, acrylic, autoConnect, apkPath, language
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        audioUID = try c.decodeIfPresent(String.self, forKey: .audioUID) ?? audioUID
        adbDevices = try c.decodeIfPresent([DeviceSetting].self, forKey: .adbDevices) ?? adbDevices
        ipDevices = try c.decodeIfPresent([DeviceSetting].self, forKey: .ipDevices) ?? ipDevices
        channelMode = try c.decodeIfPresent(ChannelMode.self, forKey: .channelMode) ?? channelMode
        sampleRate = try c.decodeIfPresent(Int.self, forKey: .sampleRate) ?? sampleRate
        volume = try c.decodeIfPresent(Int.self, forKey: .volume) ?? volume
        gain = try c.decodeIfPresent(Int.self, forKey: .gain) ?? gain
        captureMode = try c.decodeIfPresent(CaptureMode.self, forKey: .captureMode) ?? captureMode
        captureModeChosen = try c.decodeIfPresent(Bool.self, forKey: .captureModeChosen) ?? captureModeChosen
        captureProfile = try c.decodeIfPresent(CaptureProfile.self, forKey: .captureProfile) ?? captureProfile
        autoGain = try c.decodeIfPresent(Bool.self, forKey: .autoGain) ?? autoGain
        isUSB = try c.decodeIfPresent(Bool.self, forKey: .isUSB) ?? isUSB
        volumeFollowSystem = try c.decodeIfPresent(Bool.self, forKey: .volumeFollowSystem) ?? volumeFollowSystem
        acrylic = try c.decodeIfPresent(Bool.self, forKey: .acrylic) ?? acrylic
        autoConnect = try c.decodeIfPresent(Bool.self, forKey: .autoConnect) ?? autoConnect
        apkPath = try c.decodeIfPresent(String.self, forKey: .apkPath)
        language = try c.decodeIfPresent(String.self, forKey: .language)
    }

    public mutating func sanitize() {
        sampleRate = [8_000, 16_000, 44_100, 48_000, 96_000, 176_400, 192_000]
            .contains(sampleRate) ? sampleRate : 48_000
        volume = max(0, min(100, volume))
        gain = max(25, min(400, gain))
        if !(0...3).contains(channelMode.rawValue) { channelMode = .stereo }
        if !(0...3).contains(captureMode.rawValue) { captureMode = .default }
        if !(0...4).contains(captureProfile.rawValue) { captureProfile = .auto }
        adbDevices = Self.deduplicate(adbDevices)
        ipDevices = Self.deduplicate(ipDevices)
    }

    private static func deduplicate(_ devices: [DeviceSetting]) -> [DeviceSetting] {
        var seen = Set<String>()
        return devices.filter { seen.insert($0.id).inserted }
    }
}

public enum SettingsStore {
    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("AudioShare", isDirectory: true)
            .appendingPathComponent("audio.share.config.json")
    }

    public static func load(from url: URL = defaultURL) -> AppSettings {
        do {
            let data = try Data(contentsOf: url)
            var settings = try JSONDecoder().decode(AppSettings.self, from: data)
            settings.sanitize()
            return settings
        } catch {
            var settings = AppSettings()
            settings.sanitize()
            return settings
        }
    }

    public static func save(_ settings: AppSettings, to url: URL = defaultURL) throws {
        var copy = settings
        copy.sanitize()
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(copy)
        try data.write(to: url, options: .atomic)
    }
}
