import AppKit
import AudioShareCore
import Foundation

@main
struct AudioShareMacApp {
    static func main() {
        if CommandLine.arguments.contains("--probe") {
            AudioProbe.run()
            return
        }
        if CommandLine.arguments.contains("--list-audio") {
            AudioProbe.list()
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--set-default"),
           index + 1 < CommandLine.arguments.count,
           let deviceID = AudioDeviceCatalog.deviceID(forUID: CommandLine.arguments[index + 1]) {
            print(AudioDeviceCatalog.setDefaultOutputDevice(deviceID) ? "ok" : "failed")
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        Self.keepAlive = delegate
        app.delegate = delegate
        // Menu-bar-only app: no Dock icon and no Dock indicator while the
        // window is closed. The status item in AppDelegate keeps it reachable.
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private static var keepAlive: AppDelegate?
}

private enum AudioProbe {
    static func list() {
        for device in AudioDeviceCatalog.outputDevices() {
            print("\(device.isDefault ? "*" : " ") \(device.name) | \(device.channelCount)ch @ \(Int(device.sampleRate))Hz | \(device.id)")
        }
    }

    static func run() {
        let args = CommandLine.arguments
        let requestedUID: String?
        if let index = args.firstIndex(of: "--probe"), index + 1 < args.count,
           !args[index + 1].hasPrefix("--") {
            requestedUID = args[index + 1]
        } else {
            requestedUID = nil
        }
        guard let device = requestedUID.flatMap({ uid in
            AudioDeviceCatalog.outputDevices().first(where: { $0.id == uid })
        }) ?? AudioDeviceCatalog.outputDevices().first(where: { $0.isDefault })
                ?? AudioDeviceCatalog.outputDevices().first else {
            print("No output device")
            return
        }
        print("Probing \(device.name) (\(device.channelCount)ch @ \(Int(device.sampleRate))Hz)")
        let engine = AudioCaptureEngine()
        var frames = 0
        var peak = 0
        var rms = 0.0
        engine.onFrame = { frame in
            frames += 1
            var localPeak = 0
            var sum = 0.0
            for sample in frame.samples {
                localPeak = max(localPeak, abs(Int(sample)))
                sum += Double(sample * sample)
            }
            peak = max(peak, localPeak)
            rms = max(rms, sqrt(sum / Double(max(1, frame.samples.count))) / 32768.0)
            if frames <= 5 || frames % 20 == 0 {
                let line = "frame \(frames): \(frame.frameCount) frames, \(frame.channels)ch, peak \(localPeak), rms \(String(format: "%.4f", sqrt(sum / Double(max(1, frame.samples.count))) / 32768.0))"
                print(line)
                Log.info("probe " + line)
            }
        }
        engine.onError = { message in
            print("capture error: \(message)")
            Log.error("probe error: \(message)")
        }
        let config = CaptureConfiguration(deviceUID: device.id, sampleRate: 48_000,
                                          channelMode: .stereo, captureMode: .default,
                                          profile: .generic, gainPercent: 100, autoGain: false)
        engine.start(configuration: config) { result in
            switch result {
            case .success(let info): print("started: \(info.sourceChannels)ch @ \(Int(info.sourceSampleRate))Hz")
            case .failure(let error): print("start failed: \(error.localizedDescription)")
            }
        }
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        engine.stop()
        let summary = "done frames=\(frames) peak=\(peak) maxRMS=\(String(format: "%.4f", rms))"
        print(summary)
        Log.info("probe " + summary)
        Thread.sleep(forTimeInterval: 0.5)
    }
}
