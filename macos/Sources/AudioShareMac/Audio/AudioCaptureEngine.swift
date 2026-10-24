import AudioShareCore
import AudioToolbox
import CoreAudio
import Foundation

struct CaptureConfiguration {
    var deviceUID: String
    var sampleRate: Int
    var channelMode: ChannelMode
    var captureMode: CaptureMode
    var profile: CaptureProfile
    var gainPercent: Int
    var autoGain: Bool
}

struct CaptureInfo {
    var sourceChannels: Int
    var sourceSampleRate: Double
}

enum CaptureError: LocalizedError {
    case unsupportedOS
    case deviceMissing
    case tapCreation(OSStatus)
    case aggregateCreation(OSStatus)
    case aggregateNotAlive
    case noInputStreams
    case ioProcCreation(OSStatus)
    case startFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unsupportedOS: return "需要 macOS 14.2 或更高版本才能采集系统音频。"
        case .deviceMissing: return "找不到所选音频输出设备。"
        case .tapCreation(let s): return "创建系统音频 Tap 失败（\(s)）。请检查“系统音频录制”权限。"
        case .aggregateCreation(let s): return "创建音频聚合设备失败（\(s)）。"
        case .aggregateNotAlive: return "音频聚合设备未能启动。"
        case .noInputStreams: return "音频 Tap 没有输入声道。"
        case .ioProcCreation(let s): return "创建音频回调失败（\(s)）。"
        case .startFailed(let s): return "启动音频采集失败（\(s)）。"
        }
    }
}

/// Captures the system mix with a Core Audio process tap. The tap is scoped to
/// the selected output device's stream, so when that device is configured for
/// 5.1/7.1 the tap keeps those channels instead of downmixing to stereo.
final class AudioCaptureEngine {
    var onFrame: ((PCMFrame) -> Void)?
    var onError: ((String) -> Void)?
    var onResumed: (() -> Void)?
    var onFormat: ((CaptureInfo) -> Void)?

    private let controlQueue = DispatchQueue(label: "com.picapico.audioshare.capture.control")
    private let processQueue = DispatchQueue(label: "com.picapico.audioshare.capture.process",
                                             qos: .userInteractive)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var ioBlock: AudioDeviceIOBlock?
    private var format: TapFormat?
    private var formatASBD: AudioStreamBasicDescription?
    private var running = false
    private var config: CaptureConfiguration?
    private let agc = AutoGainProcessor()
    private var resampler = PCM16LinearResampler()
    private var wasSilent = true
    private var startDate = Date()

    func start(configuration: CaptureConfiguration, completion: ((Result<CaptureInfo, Error>) -> Void)? = nil) {
        controlQueue.async { [weak self] in
            guard let self else { return }
            self.stopLocked()
            do {
                let info = try self.startLocked(configuration)
                DispatchQueue.main.async { completion?(.success(info)) }
            } catch {
                DispatchQueue.main.async { completion?(.failure(error)) }
            }
        }
    }

    func stop() {
        controlQueue.async { [weak self] in
            self?.stopLocked()
        }
    }

    /// Applies settings that can change without rebuilding the tap.
    func updateProcessing(gainPercent: Int, autoGain: Bool, profile: CaptureProfile) {
        processQueue.async { [weak self] in
            guard let self else { return }
            self.agc.setManualGain(percent: gainPercent)
            self.agc.setAutoGain(autoGain)
            self.agc.setProfile(profile)
        }
    }

    var isRunning: Bool {
        controlQueue.sync { running }
    }

    // MARK: - Lifecycle (control queue only)

    private func startLocked(_ configuration: CaptureConfiguration) throws -> CaptureInfo {
        guard #available(macOS 14.2, *) else { throw CaptureError.unsupportedOS }
        guard let deviceID = AudioDeviceCatalog.deviceID(forUID: configuration.deviceUID) else {
            throw CaptureError.deviceMissing
        }

        config = configuration
        agc.setManualGain(percent: configuration.gainPercent)
        agc.setAutoGain(configuration.autoGain)
        agc.setProfile(configuration.profile)
        wasSilent = true
        resampler = PCM16LinearResampler()

        let excluded = CoreAudioProperty.processObjectID(for: getpid()).map { [$0] } ?? []
        let tapUUID = UUID()
        let deviceChannels = AudioDeviceCatalog.outputChannelCount(deviceID)
        let deviceScoped = deviceChannels > 2
        let description: CATapDescription
        if deviceScoped {
            // Keep the physical output stream's channel layout (5.1/7.1).
            description = CATapDescription(
                excludingProcesses: excluded,
                deviceUID: configuration.deviceUID,
                stream: 0
            )
        } else {
            // The global stereo tap is the most compatible path for normal
            // stereo outputs and does not need an output sub-device.
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        }
        description.uuid = tapUUID
        description.name = "AudioShare System Tap"
        description.isPrivate = true
        description.isExclusive = true
        description.muteBehavior = .unmuted

        var createdTap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &createdTap)
        guard tapStatus == noErr, createdTap != kAudioObjectUnknown else {
            throw CaptureError.tapCreation(tapStatus)
        }
        tapID = createdTap

        guard let asbd = CoreAudioProperty.tapFormat(tapID),
              let tapFormat = TapFormat(asbd) else {
            stopLocked()
            throw CaptureError.noInputStreams
        }
        format = tapFormat
        formatASBD = asbd

        var aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AudioShare Capture",
            kAudioAggregateDeviceUIDKey: "com.picapico.audioshare.capture.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapDriftCompensationQualityKey: kAudioAggregateDriftCompensationMaxQuality,
                ]
            ],
        ]
        if deviceScoped {
            // The output device is the aggregate's clock master. Without it a
            // multichannel tap would run on a virtual clock and deliver silence.
            aggregateDescription[kAudioAggregateDeviceMainSubDeviceKey] = configuration.deviceUID
            aggregateDescription[kAudioAggregateDeviceSubDeviceListKey] = [
                [kAudioSubDeviceUIDKey: configuration.deviceUID]
            ]
        }

        var createdAggregate = AudioObjectID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary, &createdAggregate
        )
        guard aggregateStatus == noErr, createdAggregate != kAudioObjectUnknown else {
            stopLocked()
            throw CaptureError.aggregateCreation(aggregateStatus)
        }
        aggregateID = createdAggregate

        guard CoreAudioProperty.waitUntilAlive(aggregateID) else {
            stopLocked()
            throw CaptureError.aggregateNotAlive
        }

        let bufferFrames = UInt32(max(128, min(4_096,
            Int(Double(configuration.sampleRate) * Double(configuration.captureMode.bufferMilliseconds) / 1_000))))
        CoreAudioProperty.setBufferFrameSize(aggregateID, frames: bufferFrames)

        var procID: AudioDeviceIOProcID?
        let block: AudioDeviceIOBlock = { [weak self] _, inputData, _, _, _ in
            self?.receive(inputData)
        }
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil, block)
        guard ioStatus == noErr, let procID else {
            stopLocked()
            throw CaptureError.ioProcCreation(ioStatus)
        }
        ioBlock = block
        ioProcID = procID

        running = true
        startDate = Date()
        let startStatus = AudioDeviceStart(aggregateID, procID)
        guard startStatus == noErr else {
            running = false
            stopLocked()
            throw CaptureError.startFailed(startStatus)
        }

        let info = CaptureInfo(sourceChannels: tapFormat.channels,
                               sourceSampleRate: tapFormat.sampleRate)
        DispatchQueue.main.async { [weak self] in
            self?.onFormat?(info)
        }
        Log.info("capture started: \(tapFormat.channels)ch @ \(Int(tapFormat.sampleRate))Hz, " +
                 "target \(configuration.sampleRate)Hz, buffer \(bufferFrames) frames")
        return info
    }

    private func stopLocked() {
        running = false
        if let procID = ioProcID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        ioProcID = nil
        ioBlock = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            if #available(macOS 14.2, *) {
                AudioHardwareDestroyProcessTap(tapID)
            }
            tapID = kAudioObjectUnknown
        }
        format = nil
        formatASBD = nil
        config = nil
    }

    // MARK: - Realtime callback

    private func receive(_ inputData: UnsafePointer<AudioBufferList>) {
        guard running, let format, let asbd = formatASBD, let cfg = config else { return }
        guard let samples = convert(inputData: inputData, format: format, asbd: asbd) else { return }

        // The HAL callback only copies samples. Resampling, AGC and network
        // fan-out run on a worker queue so the realtime thread never allocates
        // unbounded work or blocks on a speaker socket.
        processQueue.async { [weak self] in
            guard let self, self.running else { return }
            let resampled = self.resampler.process(
                samples, channels: format.channels,
                sourceRate: format.sampleRate, targetRate: Double(cfg.sampleRate)
            )
            guard !resampled.isEmpty else { return }

            var output = resampled
            self.agc.process(samples: &output, sampleRate: cfg.sampleRate, channels: format.channels)

            let peak = output.reduce(0) { max($0, abs(Int($1))) }
            if peak > 0 {
                if self.wasSilent {
                    self.wasSilent = false
                    DispatchQueue.main.async { [weak self] in self?.onResumed?() }
                }
            } else {
                self.wasSilent = true
            }

            let frame = PCMFrame(samples: output, channels: format.channels,
                                 sampleRate: cfg.sampleRate)
            self.onFrame?(frame)
        }
    }

    private func convert(inputData: UnsafePointer<AudioBufferList>,
                         format: TapFormat,
                         asbd: AudioStreamBasicDescription) -> [Int16]? {
        let list = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )
        guard !list.isEmpty else { return nil }
        let channels = format.channels
        let bytesPerSample = max(1, format.bitsPerChannel / 8)
        if !Self.loggedFormat {
            Self.loggedFormat = true
            var details = ""
            for (index, buffer) in list.enumerated() {
                details += " [b\(index) ch=\(buffer.mNumberChannels) bytes=\(buffer.mDataByteSize)]"
            }
            Log.info("tap buffers: \(list.count)\(details) fmt=\(format.channels)ch/\(format.bitsPerChannel)bit float=\(format.isFloat) nonInterleaved=\(format.isNonInterleaved)")
            if format.isFloat, let data = list[0].mData {
                let pointer = data.assumingMemoryBound(to: Float.self)
                let samples = (0..<min(8, Int(list[0].mDataByteSize) / 4)).map { String(pointer[$0]) }
                Log.info("tap first samples: \(samples.joined(separator: ","))")
            }
        }

        if format.isNonInterleaved {
            let tapBuffers = list.count > channels
                ? Array(list.suffix(channels))
                : Array(list)
            let frameCount = tapBuffers.map { Int($0.mDataByteSize) / bytesPerSample }.min() ?? 0
            guard frameCount > 0 else { return nil }
            var output = [Int16](repeating: 0, count: frameCount * channels)
            for channel in 0..<channels {
                guard channel < tapBuffers.count,
                      let data = tapBuffers[channel].mData else { continue }
                for frame in 0..<frameCount {
                    let offset = frame * bytesPerSample
                    let value: Int16
                    if format.isFloat {
                        let f = data.advanced(by: offset).assumingMemoryBound(to: Float.self).pointee
                        value = Self.pcm16(f)
                    } else if bytesPerSample == 2 {
                        value = data.advanced(by: offset).assumingMemoryBound(to: Int16.self).pointee
                    } else if bytesPerSample == 4 {
                        let i = data.advanced(by: offset).assumingMemoryBound(to: Int32.self).pointee
                        value = Int16(clamping: i >> 16)
                    } else {
                        value = 0
                    }
                    output[frame * channels + channel] = value
                }
            }
            return output
        }

        // A duplex output device contributes its hardware input streams ahead
        // of the tap. Pick the trailing buffer that matches the tap format.
        let tapBuffer = list.last(where: { Int($0.mNumberChannels) == channels })
            ?? list.last
        guard let buffer = tapBuffer, let data = buffer.mData else { return nil }
        let frameCount = Int(buffer.mDataByteSize) / (bytesPerSample * channels)
        guard frameCount > 0 else { return nil }
        var output = [Int16](repeating: 0, count: frameCount * channels)
        if format.isFloat {
            let pointer = data.assumingMemoryBound(to: Float.self)
            for i in 0..<(frameCount * channels) {
                output[i] = Self.pcm16(pointer[i])
            }
        } else if bytesPerSample == 2 {
            let pointer = data.assumingMemoryBound(to: Int16.self)
            output.withUnsafeMutableBufferPointer { destination in
                destination.baseAddress?.update(from: pointer, count: frameCount * channels)
            }
        } else if bytesPerSample == 4 {
            let pointer = data.assumingMemoryBound(to: Int32.self)
            for i in 0..<(frameCount * channels) {
                output[i] = Int16(clamping: pointer[i] >> 16)
            }
        }
        return output
    }

    private static var loggedFormat = false

    private static func pcm16(_ value: Float) -> Int16 {
        let scaled = Double(value) * 32_767.0
        return Int16(max(-32_768, min(32_767, Int(scaled.rounded()))))
    }
}

/// Streaming linear resampler. It keeps the fractional read position between
/// HAL buffers so 44.1/48/96 kHz selections work regardless of the device rate.
final class PCM16LinearResampler {
    private var position = 0.0

    func reset() {
        position = 0
    }

    func process(_ input: [Int16], channels: Int,
                 sourceRate: Double, targetRate: Double) -> [Int16] {
        guard channels > 0, sourceRate > 0, targetRate > 0 else { return [] }
        guard abs(sourceRate - targetRate) > 0.5 else { return input }
        let frames = input.count / channels
        guard frames > 0 else { return [] }

        let ratio = sourceRate / targetRate
        var output = [Int16]()
        output.reserveCapacity(Int(Double(frames) / ratio) * channels + channels)
        var cursor = position
        while cursor < Double(frames) {
            let index = min(frames - 1, Int(cursor))
            let next = min(frames - 1, index + 1)
            let fraction = cursor - Double(index)
            let a = index * channels
            let b = next * channels
            for channel in 0..<channels {
                let s0 = Double(input[a + channel])
                let s1 = Double(input[b + channel])
                let value = s0 + (s1 - s0) * fraction
                output.append(Int16(max(-32_768, min(32_767, Int(value.rounded())))))
            }
            cursor += ratio
        }
        position = cursor - Double(frames)
        if position < 0 { position = 0 }
        return output
    }
}
