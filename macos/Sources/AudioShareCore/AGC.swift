import Foundation

/// Loudness normalisation ported from the Windows AudioManager. The Windows
/// build measures the render loopback after endpoint volume; on macOS the tap
/// sees the same post-mix signal, so the same RMS target works well.
public final class AutoGainProcessor {
    public private(set) var manualGain: Float = 1
    public private(set) var autoGainEnabled: Bool = false
    public private(set) var profile: CaptureProfile = .generic
    public private(set) var currentGain: Double = 1
    public private(set) var envelope: Double = 0

    private let silencePeak = 64.0 / 32_768.0
    private let envelopeTau = 0.5
    private var target = 0.12
    private var maxGain = 8.0
    private var slewDbPerSecond = 6.0
    private let minGain = 0.25

    public init() {
        setProfile(.auto)
    }

    public func setProfile(_ profile: CaptureProfile) {
        self.profile = profile.effectiveForMac
        switch self.profile {
        case .dolby:
            target = 0.10
            maxGain = 2.0
            slewDbPerSecond = 3.0
        case .smartAudio:
            target = 0.11
            maxGain = 2.5
            slewDbPerSecond = 3.0
        case .realtek:
            target = 0.14
            maxGain = 8.0
            slewDbPerSecond = 6.0
        default:
            target = 0.12
            maxGain = 8.0
            slewDbPerSecond = 6.0
        }
        reset()
    }

    public func setManualGain(percent: Int) {
        manualGain = Float(max(25, min(400, percent))) / 100
    }

    public func setAutoGain(_ enabled: Bool) {
        autoGainEnabled = enabled
        reset()
    }

    public func reset() {
        currentGain = 1
        envelope = 0
    }

    /// Applies gain in place. `samples` is interleaved PCM16.
    public func process(samples: inout [Int16], sampleRate: Int, channels: Int) {
        guard !samples.isEmpty, sampleRate > 0, channels > 0 else { return }
        var gain = Double(manualGain)

        if autoGainEnabled {
            let frames = samples.count / channels
            guard frames > 0 else { return }
            var sumSquares = 0.0
            var peak = 0
            for sample in samples {
                let value = Int(sample)
                sumSquares += Double(value * value)
                peak = max(peak, abs(value))
            }
            let peakScalar = Double(peak) / 32_768.0
            if peakScalar >= silencePeak {
                let rms = sqrt(sumSquares / Double(samples.count)) / 32_768.0
                let frameSeconds = Double(frames) / Double(sampleRate)
                let alpha = 1.0 - exp(-frameSeconds / envelopeTau)
                envelope += (rms - envelope) * alpha
                if envelope > 1e-6 {
                    let desired = max(minGain, min(maxGain, target / envelope))
                    let slew = pow(10.0, slewDbPerSecond * frameSeconds / 20.0)
                    if desired > currentGain {
                        currentGain = min(desired, currentGain * slew)
                    } else {
                        currentGain = max(desired, currentGain / slew)
                    }
                }
            }
            gain *= currentGain
        }

        guard abs(gain - 1) > 0.0001 else { return }
        for i in samples.indices {
            let scaled = Int(Double(samples[i]) * gain)
            samples[i] = Int16(max(Int(Int16.min), min(Int(Int16.max), scaled)))
        }
    }

    /// Adds a 3 dB headroom trim when a frame would clip after gain is applied.
    /// The Windows implementation hard-clips; this helper is intentionally
    /// unused for wire parity, but kept available for future soft limiting.
    public static func clippedCount(samples: [Int16], gain: Double) -> Int {
        guard gain > 1 else { return 0 }
        return samples.reduce(into: 0) { count, sample in
            if Int(Double(sample) * gain) > Int(Int16.max)
                || Int(Double(sample) * gain) < Int(Int16.min) {
                count += 1
            }
        }
    }
}
