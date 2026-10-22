import CoreAudio
import Foundation

struct AudioDevice: Identifiable, Equatable {
    let id: String          // device UID, stable across launches
    let name: String
    let channelCount: Int
    let sampleRate: Double
    let streamCount: Int
    let isDefault: Bool

    var displayName: String { name }
}

enum AudioDeviceCatalog {
    static func outputDevices() -> [AudioDevice] {
        let defaultID = defaultOutputDeviceID()
        let ids = deviceIDs()
        return ids.compactMap { deviceID -> AudioDevice? in
            guard hasOutputStreams(deviceID),
                  let uid = stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(deviceID, selector: kAudioObjectPropertyName)
                    ?? stringProperty(deviceID, selector: kAudioDevicePropertyDeviceNameCFString)
            else { return nil }
            let channels = outputChannelCount(deviceID)
            guard channels > 0 else { return nil }
            let rate = doubleProperty(deviceID, selector: kAudioDevicePropertyNominalSampleRate) ?? 48_000
            let streams = outputStreamCount(deviceID)
            return AudioDevice(
                id: uid,
                name: name,
                channelCount: channels,
                sampleRate: rate,
                streamCount: streams,
                isDefault: defaultID == deviceID
            )
        }
        .sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    static func deviceID(forUID uid: String) -> AudioObjectID? {
        for id in deviceIDs() {
            if stringProperty(id, selector: kAudioDevicePropertyDeviceUID) == uid {
                return id
            }
        }
        return nil
    }

    static func defaultOutputDeviceID() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        return status == noErr && deviceID != kAudioObjectUnknown ? deviceID : nil
    }

    static func deviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }
        return ids
    }

    static func hasOutputStreams(_ deviceID: AudioObjectID) -> Bool {
        outputStreamCount(deviceID) > 0
    }

    static func outputStreamCount(_ deviceID: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    static func outputChannelCount(_ deviceID: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func stringProperty(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { return nil }
        let result = value as String
        return result.isEmpty ? nil : result
    }

    static func doubleProperty(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func volumePercent(deviceID: AudioObjectID) -> Int? {
        var muted = false
        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var muteValue: UInt32 = 0
        var muteSize = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(deviceID, &muteAddress, 0, nil, &muteSize, &muteValue) == noErr {
            muted = muteValue != 0
        }
        if muted { return 0 }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr,
           value.isFinite {
            return max(0, min(100, Int((value * 100).rounded())))
        }

        // Some devices expose volume only on channels 1 and 2.
        var values: [Float32] = []
        for channel in [UInt32(1), UInt32(2)] {
            var channelAddress = address
            channelAddress.mElement = channel
            var channelValue: Float32 = 0
            var channelSize = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(deviceID, &channelAddress, 0, nil, &channelSize, &channelValue) == noErr {
                values.append(channelValue)
            }
        }
        guard !values.isEmpty else { return nil }
        let average = values.reduce(0, +) / Float32(values.count)
        return max(0, min(100, Int((average * 100).rounded())))
    }

    static func setDefaultOutputDevice(_ deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = deviceID
        let size = UInt32(MemoryLayout<AudioObjectID>.size)
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, size, &value
        ) == noErr
    }
}

// MARK: - Tap format helpers

struct TapFormat {
    var sampleRate: Double
    var channels: Int
    var isFloat: Bool
    var isNonInterleaved: Bool
    var bitsPerChannel: Int

    init?(_ asbd: AudioStreamBasicDescription) {
        guard asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0 else { return nil }
        sampleRate = asbd.mSampleRate
        channels = Int(asbd.mChannelsPerFrame)
        isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        bitsPerChannel = Int(asbd.mBitsPerChannel)
    }
}

enum CoreAudioProperty {
    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func tapFormat(_ tapID: AudioObjectID) -> AudioStreamBasicDescription? {
        var address = address(kAudioTapPropertyFormat)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
        return status == noErr ? format : nil
    }

    static func tapUID(_ tapID: AudioObjectID) -> String? {
        var address = address(kAudioTapPropertyUID)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { return nil }
        return value as String
    }

    static func processObjectID(for pid: pid_t) -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var value = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var processID = pid
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &processID,
            &size,
            &value
        )
        guard status == noErr, value != kAudioObjectUnknown else { return nil }
        return value
    }

    static func waitUntilAlive(_ deviceID: AudioObjectID, timeout: TimeInterval = 3) -> Bool {
        var address = address(kAudioDevicePropertyDeviceIsAlive)
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr,
               value != 0 {
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return false
    }

    static func setBufferFrameSize(_ deviceID: AudioObjectID, frames: UInt32) {
        var address = address(kAudioDevicePropertyBufferFrameSize)
        var value = frames
        let size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &value)
    }
}
