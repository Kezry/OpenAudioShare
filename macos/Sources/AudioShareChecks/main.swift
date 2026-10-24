import Foundation
import AudioShareCore

var failures = 0

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if condition() {
        print("  ok  \(message)")
    } else {
        failures += 1
        print("FAIL  \(message)")
    }
}

print("Protocol")
check(AudioShareProtocol.header.count == 20, "header is 20 bytes")
check(String(data: AudioShareProtocol.header, encoding: .utf8) == "picapico-audio-share", "header text")

let handshake = AudioShareProtocol.audioHandshake(sampleRate: 48_000, channels: 2)
check(handshake.prefix(20) == AudioShareProtocol.header, "handshake header")
check(handshake[20] == 1, "audio command")
check(AudioShareProtocol.readInt32LE(handshake, at: 21) == 48_000, "sample rate LE")
check(AudioShareProtocol.readInt32LE(handshake, at: 25) == 12, "stereo channel config")
check(handshake.count == 29, "handshake length")
check(AudioShareProtocol.readInt32LE(AudioShareProtocol.audioHandshake(sampleRate: 96_000, channels: 1), at: 25) == 4, "mono channel config")
check(AudioShareProtocol.volumePayload(75) == Data([75, 0, 0, 0]), "volume payload")
check(AudioShareProtocol.delayPayload(milliseconds: 120, applyNow: true) == Data([120, 0, 0, 0, 1]), "delay payload")
let packet = AudioShareProtocol.audioPacket(samples: [1, -1, 2, -2])
check(packet.count == 12, "packet length")
check(AudioShareProtocol.readInt32LE(packet, at: 0) == 8, "packet byte count")
check(packet[4] == 1 && packet[5] == 0 && packet[6] == 0xFF && packet[7] == 0xFF, "PCM16 little endian")
check(AudioShareProtocol.parseDiscoveryReply(Data("picapico-audio-share@8088@8080".utf8))?.port == 8088, "discovery reply port")
check(AudioShareProtocol.parseDiscoveryReply(Data("nope".utf8)) == nil, "invalid discovery reply")

print("Endpoint")
check(DeviceEndpoint(string: "192.168.1.10")?.port == 8088, "default port")
check(DeviceEndpoint(string: "192.168.1.10:9000")?.normalizedID == "192.168.1.10:9000", "explicit port")
check(DeviceEndpoint(string: "[fe80::1]:8088")?.host == "fe80::1", "IPv6 host")
check(DeviceEndpoint(string: "[fe80::1]:8088")?.normalizedID == "[fe80::1]:8088", "IPv6 normalized")
check(DeviceEndpoint(string: "host:") == nil, "reject missing port")
check(DeviceEndpoint(string: "") == nil, "reject empty")

print("Channels")
check(ChannelMode.stereo.speakerChannels == [.left, .right], "stereo channels")
check(ChannelMode.ch21.speakerChannels == [.left, .right, .lfe], "2.1 channels")
check(ChannelMode.ch51.speakerChannels.count == 6, "5.1 channels")
check(ChannelMode.ch71.speakerChannels.count == 8, "7.1 channels")
check(ChannelMode.stereo.sourceIndex(for: .left, sourceChannels: 2) == [0], "left index")
check(ChannelMode.ch51.sourceIndex(for: .center, sourceChannels: 6) == [2], "center index")
check(ChannelMode.ch51.sourceIndex(for: .backLeft, sourceChannels: 6) == [4], "5.1 back left")
check(ChannelMode.ch71.sourceIndex(for: .backLeft, sourceChannels: 8) == [6], "7.1 back left")
check(ChannelMode.ch71.sourceIndex(for: .sideLeft, sourceChannels: 8) == [4], "7.1 side left")
check(ChannelMode.ch71.sourceIndex(for: .sideLeft, sourceChannels: 6) == nil, "7.1 side unavailable on 5.1")
check(!ChannelMode.ch71.availableSpeakerChannels(sourceChannels: 2).contains(.center), "stereo device hides centre")
check(ChannelMode.ch71.availableSpeakerChannels(sourceChannels: 8).contains(.sideLeft), "8ch device exposes side")

let frame = PCMFrame(samples: [10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120], channels: 6, sampleRate: 48_000)
check(ChannelExtractor.extract(frame: frame, channel: .stereo, mode: .stereo, sourceChannels: 6) == [10, 20, 70, 80], "stereo extraction")
check(ChannelExtractor.extract(frame: frame, channel: .center, mode: .ch51, sourceChannels: 6) == [30, 90], "centre extraction")

print("AGC")
let silenceAGC = AutoGainProcessor()
silenceAGC.setAutoGain(true)
var silence = [Int16](repeating: 0, count: 48_000)
silenceAGC.process(samples: &silence, sampleRate: 48_000, channels: 1)
check(abs(silenceAGC.currentGain - 1) < 0.0001, "silence keeps gain")
let loudAGC = AutoGainProcessor()
loudAGC.setAutoGain(true)
var quiet = [Int16]()
for _ in 0..<100 {
    quiet = [Int16](repeating: 1_000, count: 4_800)
    loudAGC.process(samples: &quiet, sampleRate: 48_000, channels: 1)
}
check(loudAGC.currentGain > 1, "quiet signal gains")
check(quiet[0] > 1_000, "samples scaled")
let manual = AutoGainProcessor()
manual.setManualGain(percent: 1_000)
var manualSamples: [Int16] = [5_000, -5_000]
manual.process(samples: &manualSamples, sampleRate: 48_000, channels: 1)
check(manualSamples == [20_000, -20_000], "manual gain applies 400%")

print("Settings")
var settings = AppSettings()
settings.audioUID = "device-1"
settings.ipDevices = [DeviceSetting(id: "192.168.1.2:8088", channel: .left)]
settings.channelMode = .ch51
settings.volume = 77
settings.sampleRate = 96_000
let url = FileManager.default.temporaryDirectory.appendingPathComponent("audioshare-check-\(UUID().uuidString).json")
try? SettingsStore.save(settings, to: url)
let loaded = SettingsStore.load(from: url)
check(loaded.audioUID == "device-1", "settings roundtrip uid")
check(loaded.ipDevices.first?.channel == .left, "settings roundtrip channel")
check(loaded.channelMode == .ch51, "settings roundtrip mode")
check(loaded.volume == 77, "settings roundtrip volume")
check(loaded.sampleRate == 96_000, "settings roundtrip rate")
try? FileManager.default.removeItem(at: url)

var clamped = AppSettings()
clamped.volume = 1_000
clamped.gain = 1
clamped.sampleRate = 123
clamped.sanitize()
check(clamped.volume == 100 && clamped.gain == 25 && clamped.sampleRate == 48_000, "sanitize clamps")

let legacy = """
{"audioUID":"abc","adbDevices":[],"ipDevices":[{"id":"1.2.3.4:8088","channel":4}],
 "channelMode":2,"sampleRate":48000,"volume":50,"gain":100,"captureMode":0,
 "captureProfile":0,"autoGain":false,"isUSB":false,"volumeFollowSystem":true,
 "acrylic":true,"autoConnect":false}
""".data(using: .utf8)!
var legacySettings = try JSONDecoder().decode(AppSettings.self, from: legacy)
legacySettings.sanitize()
check(legacySettings.ipDevices.first?.channel == .left, "legacy channel decodes")
check(legacySettings.channelMode == .ch51, "legacy mode decodes")

if failures > 0 {
    print("\n\(failures) check(s) failed")
    exit(1)
}
print("\nAll checks passed")
