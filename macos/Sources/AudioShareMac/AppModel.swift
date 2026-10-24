import AppKit
import AudioShareCore
import UniformTypeIdentifiers
import Combine
import Foundation

struct AppAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

@MainActor
final class AppModel: ObservableObject {
    // Audio
    @Published private(set) var audioDevices: [AudioDevice] = []
    @Published private(set) var selectedAudioUID: String = ""
    @Published private(set) var sourceChannels: Int = 2
    @Published private(set) var audioControlsEnabled: Bool = true

    // Devices
    @Published private(set) var speakers: [Speaker] = []
    @Published private(set) var connectedCount: Int = 0
    @Published private(set) var connectingCount: Int = 0
    @Published private(set) var adbLoading: Bool = false

    // Settings exposed to the UI
    @Published private(set) var isUSB: Bool
    @Published private(set) var channelMode: ChannelMode
    @Published private(set) var sampleRate: Int
    @Published private(set) var captureMode: CaptureMode
    @Published private(set) var captureProfile: CaptureProfile
    @Published private(set) var volume: Int
    @Published private(set) var gain: Int
    @Published private(set) var autoGain: Bool
    @Published private(set) var followSystemVolume: Bool
    @Published private(set) var autoConnect: Bool
    let acrylic = true
    @Published private(set) var startupEnabled: Bool
    @Published private(set) var captureHint: String = ""

    @Published var alert: AppAlert?
    @Published var isAddIPPresented = false
    @Published var addIPText = ""
    @Published var showPermissionGuide = false

    // Dependencies
    private let audioEngine = AudioCaptureEngine()
    private let discovery = DiscoveryService()
    private let adb = AdbService()
    private let settingsURL: URL
    private var settings: AppSettings
    private var activeConfiguration: CaptureConfiguration?
    private var heartbeatTimer: Timer?
    private var volumeTimer: Timer?
    private var autoConnectTimer: Timer?
    private var syncWorkItem: DispatchWorkItem?
    private var discoveryConnectUntil: Date?
    private var usbPreparing = Set<String>()
    private var didInitialAutoConnect = false

    // Fan-out snapshot read by the audio worker thread.
    private struct FanoutSnapshot {
        var speakers: [Speaker] = []
        var mode: ChannelMode = .stereo
        var sourceChannels: Int = 2
    }
    private let fanoutLock = NSLock()
    private var fanout = FanoutSnapshot()

    init(settingsURL: URL = SettingsStore.defaultURL) {
        self.settingsURL = settingsURL
        var loaded = SettingsStore.load(from: settingsURL)
        if !loaded.isUSB, loaded.audioUID.isEmpty {
            loaded.audioUID = AudioDeviceCatalog.outputDevices().first?.id ?? ""
        }
        settings = loaded
        isUSB = loaded.isUSB
        channelMode = loaded.channelMode
        sampleRate = loaded.sampleRate
        captureMode = loaded.captureMode
        captureProfile = loaded.captureProfile
        volume = loaded.volume
        gain = loaded.gain
        autoGain = loaded.autoGain
        followSystemVolume = loaded.volumeFollowSystem
        autoConnect = loaded.autoConnect
        startupEnabled = LoginItemManager.isEnabled
        selectedAudioUID = loaded.audioUID
        captureHint = ""

        audioEngine.onFrame = { [weak self] frame in
            self?.fanOut(frame)
        }
        audioEngine.onResumed = { [weak self] in
            self?.audioResumed()
        }
        audioEngine.onError = { [weak self] message in
            Task { @MainActor in self?.showCaptureError(message) }
        }

        discovery.onDevice = { [weak self] host, port in
            self?.discovered(host: host, port: port)
        }
        NotificationService.shared.onReconnect = { [weak self] endpoint in
            self?.reconnect(endpoint: endpoint)
        }

        refreshAudioDevices(selectDefaultIfNeeded: true)
        if isUSB && !adb.hasAdb() {
            isUSB = false
            settings.isUSB = false
            saveSettings()
        }
        refreshSpeakers()
        startTimers()
        discovery.start()
        NotificationService.shared.requestAuthorization()
        updateCaptureHint()

        if autoConnect {
            autoConnectTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.performInitialAutoConnect() }
            }
        }
        let guideKey = "AudioShare.permissionGuideShown"
        if !UserDefaults.standard.bool(forKey: guideKey) {
            UserDefaults.standard.set(true, forKey: guideKey)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.showPermissionGuide = true
            }
        }
    }

    deinit {
        heartbeatTimer?.invalidate()
        volumeTimer?.invalidate()
        autoConnectTimer?.invalidate()
        discovery.stop()
        audioEngine.stop()
    }

    // MARK: - Audio devices

    var selectedAudioDevice: AudioDevice? {
        audioDevices.first { $0.id == selectedAudioUID }
    }

    var audioDeviceDisplay: String {
        selectedAudioDevice?.name ?? ""
    }

    func refreshAudioDevices() {
        refreshAudioDevices(selectDefaultIfNeeded: false)
    }

    private func refreshAudioDevices(selectDefaultIfNeeded: Bool) {
        let devices = AudioDeviceCatalog.outputDevices()
        audioDevices = devices
        if !devices.contains(where: { $0.id == selectedAudioUID }) {
            let fallback = devices.first(where: { $0.isDefault }) ?? devices.first
            selectedAudioUID = fallback?.id ?? ""
            settings.audioUID = selectedAudioUID
            saveSettings()
        }
        sourceChannels = selectedAudioDevice?.channelCount ?? 2
        updateChannelAvailability()
        if followSystemVolume {
            applySystemVolume()
        }
        updateCaptureHint()
    }

    func selectAudioDevice(_ uid: String) {
        guard audioControlsEnabled, uid != selectedAudioUID else { return }
        stopCapture()
        selectedAudioUID = uid
        settings.audioUID = uid
        sourceChannels = selectedAudioDevice?.channelCount ?? 2
        updateChannelAvailability()
        if followSystemVolume { applySystemVolume() }
        saveSettings()
        updateCaptureHint()
    }

    func selectSampleRate(_ rate: Int) {
        guard audioControlsEnabled, rate != sampleRate else { return }
        sampleRate = rate
        settings.sampleRate = rate
        stopCapture()
        saveSettings()
    }

    func setChannelMode(_ mode: ChannelMode) {
        guard mode != channelMode else { return }
        channelMode = mode
        settings.channelMode = mode
        updateChannelAvailability()
        for speaker in speakers {
            if speaker.connected && !availableChannels(sourceChannels: sourceChannels).contains(speaker.channel) {
                // A connected stream's channel count cannot change without a
                // new handshake. Drop that one device and reset it to stereo.
                speaker.disconnect()
                speaker.setChannel(.stereo, force: true)
            } else if !availableChannels(sourceChannels: sourceChannels).contains(speaker.channel) {
                speaker.setChannel(.stereo, force: true)
            }
        }
        resetSpeakerSettings()
        saveSettings()
        updateFanout()
        if connectedCount > 0 {
            ensureCaptureStarted(forceRestart: true)
        }
        updateCaptureHint()
    }

    func setCaptureMode(_ mode: CaptureMode) {
        guard mode != captureMode else { return }
        captureMode = mode
        settings.captureMode = mode
        settings.captureModeChosen = true
        saveSettings()
        if connectedCount > 0 { ensureCaptureStarted(forceRestart: true) }
    }

    func setCaptureProfile(_ profile: CaptureProfile) {
        guard profile != captureProfile else { return }
        captureProfile = profile
        settings.captureProfile = profile
        saveSettings()
        audioEngine.updateProcessing(gainPercent: gain, autoGain: autoGain, profile: profile)
    }

    func setVolume(_ value: Int) {
        let clamped = max(0, min(100, value))
        guard clamped != volume else { return }
        volume = clamped
        settings.volume = clamped
        saveSettings()
        for speaker in speakers where speaker.connected {
            speaker.setVolume(clamped)
        }
    }

    func setGain(_ value: Int) {
        let clamped = max(25, min(400, value))
        guard clamped != gain else { return }
        gain = clamped
        settings.gain = clamped
        saveSettings()
        audioEngine.updateProcessing(gainPercent: clamped, autoGain: autoGain, profile: captureProfile)
    }

    func setAutoGain(_ value: Bool) {
        guard value != autoGain else { return }
        autoGain = value
        settings.autoGain = value
        saveSettings()
        audioEngine.updateProcessing(gainPercent: gain, autoGain: value, profile: captureProfile)
    }

    func setFollowSystemVolume(_ value: Bool) {
        followSystemVolume = value
        settings.volumeFollowSystem = value
        saveSettings()
        if value { applySystemVolume() }
    }

    func setAutoConnect(_ value: Bool) {
        autoConnect = value
        settings.autoConnect = value
        saveSettings()
    }

    func setStartup(_ value: Bool) {
        let result = LoginItemManager.setEnabled(value)
        if let error = result {
            alert = AppAlert(title: L10n.t("startup"), message: error)
            startupEnabled = LoginItemManager.isEnabled
        } else {
            startupEnabled = value
        }
    }

    var audioControlsDisabled: Bool { !audioControlsEnabled }

    private func applySystemVolume() {
        guard let device = selectedAudioDevice,
              let deviceID = AudioDeviceCatalog.deviceID(forUID: device.id),
              let value = AudioDeviceCatalog.volumePercent(deviceID: deviceID) else { return }
        if abs(value - volume) >= 1 {
            setVolume(value)
        }
    }

    // MARK: - Speakers

    var isIP: Bool { !isUSB }

    var addIPVisible: Bool { !isUSB }

    var connected: Bool { connectedCount > 0 }

    var unconnected: Bool { connectedCount == 0 }

    func availableChannels(sourceChannels: Int) -> [AudioChannel] {
        channelMode.availableSpeakerChannels(sourceChannels: sourceChannels)
    }

    private func updateChannelAvailability() {
        let available = availableChannels(sourceChannels: sourceChannels)
        for speaker in speakers where !available.contains(speaker.channel) {
            speaker.setChannel(.stereo)
        }
    }

    private func updateCaptureHint() {
        let needed = channelMode.captureChannels
        if needed > sourceChannels {
            captureHint = L10n.f("multiChannelUnavailable", sourceChannels, L10n.modeName(channelMode))
        } else {
            captureHint = L10n.modeHint(channelMode)
        }
    }

    func setUSB(_ value: Bool) {
        guard value != isUSB else { return }
        if value && !adb.hasAdb() {
            alert = AppAlert(title: "USB", message: L10n.t("adbMissing"))
            return
        }
        disconnectAll()
        isUSB = value
        settings.isUSB = value
        saveSettings()
        refreshSpeakers()
    }

    func refreshSpeakers() {
        if isUSB {
            refreshUSBSpeakers()
        } else {
            rebuildIPSiteSpeakers()
        }
    }

    private func rebuildIPSiteSpeakers() {
        let connected = Dictionary(uniqueKeysWithValues: speakers.map { ($0.endpointID, $0) })
        var result: [Speaker] = []
        for device in settings.ipDevices {
            if let existing = connected[device.id], existing.connected || existing.connecting {
                existing.setChannel(device.channel)
                result.append(existing)
            } else if let existing = connected[device.id] {
                existing.setChannel(device.channel)
                result.append(existing)
            } else {
                result.append(makeSpeaker(endpointID: device.id, channel: device.channel,
                                          isUSB: false, serial: nil, name: ""))
            }
        }
        for speaker in speakers where !result.contains(where: { $0.id == speaker.id }) {
            if speaker.connected || speaker.connecting { result.append(speaker) }
            else { speaker.dispose() }
        }
        speakers = result.sorted { lhs, rhs in
            lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
        Log.info("ip speakers: settings=\(settings.ipDevices.count) shown=\(speakers.count)")
        updateCounts()
        updateFanout()
    }

    private func refreshUSBSpeakers() {
        guard adb.hasAdb() else {
            isUSB = false
            settings.isUSB = false
            saveSettings()
            refreshSpeakers()
            return
        }
        adbLoading = true
        adb.perform({ [adb] in
            try adb.startServer()
            return try adb.devices()
        }) { [weak self] result in
            guard let self else { return }
            self.adbLoading = false
            switch result {
            case .failure(let error):
                Log.error("adb devices failed: \(error.localizedDescription)")
                self.alert = AppAlert(title: "USB", message: error.localizedDescription)
            case .success(let devices):
                let online = devices.filter { $0.state == "device" }
                self.rebuildUSBSpeakers(devices: online)
            }
        }
    }

    private func rebuildUSBSpeakers(devices: [AdbDevice]) {
        let existing = Dictionary(uniqueKeysWithValues: speakers.map { ($0.endpointID, $0) })
        var result: [Speaker] = []
        for device in devices {
            let saved = settings.adbDevices.first { $0.id == device.serial }
            if let current = existing[device.serial], current.connected || current.connecting {
                result.append(current)
            } else {
                result.append(makeSpeaker(endpointID: device.serial,
                                          channel: saved?.channel ?? .none,
                                          isUSB: true, serial: device.serial, name: device.name))
            }
        }
        for speaker in speakers where speaker.connected || speaker.connecting {
            if !result.contains(where: { $0.id == speaker.id }) { result.append(speaker) }
        }
        for speaker in speakers where !result.contains(where: { $0.id == speaker.id }) {
            speaker.dispose()
        }
        speakers = result.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
        resetSpeakerSettings()
        updateCounts()
        updateFanout()
    }

    private func makeSpeaker(endpointID: String, channel: AudioChannel, isUSB: Bool,
                             serial: String?, name: String) -> Speaker {
        let speaker = Speaker(endpointID: endpointID, channel: channel, isUSB: isUSB,
                              serial: serial, name: name)
        speaker.setSampleRate(sampleRate)
        speaker.onStatusChanged = { [weak self] speaker in
            self?.speakerStatusChanged(speaker)
        }
        speaker.onUnexpectedDisconnect = { [weak self] speaker in
            self?.speakerUnexpectedlyDisconnected(speaker)
        }
        return speaker
    }

    func connectSpeaker(_ speaker: Speaker) {
        guard speaker.channel != .none else { return }
        if speaker.isUSB {
            guard let serial = speaker.serial, !usbPreparing.contains(serial) else { return }
            usbPreparing.insert(serial)
            adbLoading = true
            let apkPath = resolvedAPKPath()
            adb.perform({ [adb] in
                try adb.prepareUSB(serial: serial, apkPath: apkPath)
            }) { [weak self] result in
                guard let self else { return }
                self.adbLoading = false
                self.usbPreparing.remove(serial)
                switch result {
                case .success(let port):
                    speaker.setUSBPort(port)
                    speaker.setSampleRate(self.sampleRate)
                    speaker.connect()
                case .failure(let error):
                    Log.error("prepare USB failed: \(error.localizedDescription)")
                    let missingAPK = (error as? AdbError).map {
                        if case .installFailed = $0 { return true }
                        return false
                    } ?? false
                    self.alert = AppAlert(
                        title: "USB",
                        message: missingAPK ? L10n.t("apkMissing") : error.localizedDescription
                    )
                }
            }
        } else {
            speaker.setSampleRate(sampleRate)
            speaker.connect()
        }
    }

    func disconnectSpeaker(_ speaker: Speaker) {
        speaker.disconnect()
    }

    func removeSpeaker(_ speaker: Speaker) {
        guard speaker.status == .disconnected else { return }
        speaker.dispose()
        speakers.removeAll { $0.id == speaker.id }
        if speaker.isUSB {
            settings.adbDevices.removeAll { $0.id == speaker.endpointID }
        } else {
            settings.ipDevices.removeAll { $0.id == speaker.endpointID }
        }
        saveSettings()
        updateCounts()
        updateFanout()
    }

    func renameSpeaker(_ speaker: Speaker, newValue: String) {
        guard !speaker.isUSB, speaker.status == .disconnected else { return }
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let endpoint = DeviceEndpoint(string: trimmed) else {
            alert = AppAlert(title: L10n.t("addIPTitle"), message: L10n.t("ipParseError"))
            return
        }
        let normalized = endpoint.normalizedID
        guard normalized != speaker.endpointID else { return }
        guard !settings.ipDevices.contains(where: { $0.id == normalized && $0.id != speaker.endpointID }) else {
            return
        }
        if let index = settings.ipDevices.firstIndex(where: { $0.id == speaker.endpointID }) {
            settings.ipDevices[index].id = normalized
        } else {
            settings.ipDevices.append(DeviceSetting(id: normalized, channel: speaker.channel))
        }
        speaker.display = normalized
        saveSettings()
        updateFanout()
    }

    func setSpeakerChannel(_ speaker: Speaker, channel: AudioChannel) {
        guard let index = speakers.firstIndex(where: { $0.id == speaker.id }) else { return }
        guard speakers[index].status == .disconnected else { return }
        speakers[index].setChannel(channel)
        resetSpeakerSettings()
        saveSettings()
        updateFanout()
    }

    func connectAll() {
        for speaker in speakers where speaker.channel != .none && speaker.status == .disconnected {
            connectSpeaker(speaker)
        }
    }

    func disconnectAll() {
        for speaker in speakers where speaker.status != .disconnected {
            speaker.disconnect()
        }
    }

    func syncDevices(applyNow: Bool = true) {
        let connected = speakers.filter { $0.connected }
        guard connected.count >= 2 else { return }
        var raw: [UUID: Int] = [:]
        let lock = NSLock()
        let group = DispatchGroup()
        for speaker in connected {
            group.enter()
            speaker.measureLatency { latency in
                lock.lock()
                raw[speaker.id] = latency
                lock.unlock()
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            let valid = self.speakers.filter { raw[$0.id, default: -1] > 0 }
            guard valid.count >= 2 else { return }
            let maxRTT = valid.map { $0.lastRTT }.max() ?? 0
            for speaker in valid {
                let delay = max(0, maxRTT - speaker.lastRTT)
                if applyNow || abs(delay - speaker.lastSentDelay) >= 15 {
                    speaker.setDelay(milliseconds: delay, applyNow: applyNow)
                }
            }
            Log.info("device sync: maxRTT=\(maxRTT) devices=\(valid.count) applyNow=\(applyNow)")
        }
    }

    // MARK: - Discovery

    func searchSpeakers() {
        discoveryConnectUntil = Date().addingTimeInterval(15)
        discovery.search()
    }

    private func discovered(host: String, port: Int) {
        guard !isUSB else { return }
        let id = "\(host):\(port)"
        if let speaker = speakers.first(where: { $0.endpointID == id }) {
            if let until = discoveryConnectUntil, Date() < until,
               speaker.status == .disconnected, speaker.channel != .none {
                connectSpeaker(speaker)
            }
            return
        }
        guard !settings.ipDevices.contains(where: { $0.id == id }) else { return }
        settings.ipDevices.append(DeviceSetting(id: id, channel: .none))
        let speaker = makeSpeaker(endpointID: id, channel: .none, isUSB: false, serial: nil, name: "")
        speakers.append(speaker)
        saveSettings()
        updateFanout()
        if let until = discoveryConnectUntil, Date() < until {
            speaker.setChannel(.stereo)
            resetSpeakerSettings()
            saveSettings()
            connectSpeaker(speaker)
        }
    }

    func addIP() {
        guard let endpoint = DeviceEndpoint(string: addIPText) else {
            alert = AppAlert(title: L10n.t("addIPTitle"), message: L10n.t("ipParseError"))
            return
        }
        let id = endpoint.normalizedID
        if !settings.ipDevices.contains(where: { $0.id == id }) {
            settings.ipDevices.append(DeviceSetting(id: id, channel: .stereo))
            let speaker = makeSpeaker(endpointID: id, channel: .stereo, isUSB: false, serial: nil, name: "")
            speakers.append(speaker)
            saveSettings()
            updateFanout()
        }
        addIPText = ""
        isAddIPPresented = false
    }

    // MARK: - Capture

    private func ensureCaptureStarted(forceRestart: Bool = false) {
        guard connectedCount > 0 else { return }
        guard let device = selectedAudioDevice else {
            alert = AppAlert(title: L10n.t("title"), message: L10n.t("noAudioDevice"))
            return
        }
        let configuration = CaptureConfiguration(
            deviceUID: device.id,
            sampleRate: sampleRate,
            channelMode: channelMode,
            captureMode: captureMode,
            profile: captureProfile,
            gainPercent: gain,
            autoGain: autoGain
        )
        if !forceRestart, audioEngine.isRunning, activeConfiguration != nil,
           sameConfiguration(activeConfiguration!, configuration) {
            return
        }
        activeConfiguration = configuration
        audioEngine.updateProcessing(gainPercent: gain, autoGain: autoGain, profile: captureProfile)
        audioEngine.start(configuration: configuration) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let info):
                if info.sourceChannels != self.sourceChannels {
                    self.sourceChannels = info.sourceChannels
                    self.updateChannelAvailability()
                    self.updateCaptureHint()
                }
                self.updateFanout()
                Log.info("capture ready: \(info.sourceChannels) channels @ \(Int(info.sourceSampleRate))Hz")
            case .failure(let error):
                self.activeConfiguration = nil
                self.showCaptureError(error.localizedDescription)
            }
        }
    }

    private func sameConfiguration(_ lhs: CaptureConfiguration, _ rhs: CaptureConfiguration) -> Bool {
        lhs.deviceUID == rhs.deviceUID &&
        lhs.sampleRate == rhs.sampleRate &&
        lhs.channelMode == rhs.channelMode &&
        lhs.captureMode == rhs.captureMode &&
        lhs.profile == rhs.profile &&
        lhs.gainPercent == rhs.gainPercent &&
        lhs.autoGain == rhs.autoGain
    }

    private func stopCapture() {
        audioEngine.stop()
        activeConfiguration = nil
    }

    private func fanOut(_ frame: PCMFrame) {
        fanoutLock.lock()
        let snapshot = fanout
        fanoutLock.unlock()
        for speaker in snapshot.speakers {
            speaker.send(frame: frame, mode: snapshot.mode)
        }
    }

    private func updateFanout() {
        let connected = speakers.filter { $0.connected }
        fanoutLock.lock()
        fanout = FanoutSnapshot(speakers: connected, mode: channelMode, sourceChannels: sourceChannels)
        fanoutLock.unlock()
    }

    private func audioResumed() {
        guard connectedCount >= 2 else { return }
        syncWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.connectedCount >= 2 else { return }
            self.syncDevices(applyNow: false)
        }
        syncWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: item)
    }

    // MARK: - Status

    private func speakerStatusChanged(_ speaker: Speaker) {
        updateCounts()
        resetSpeakerSettings()
        updateFanout()
        saveSettings()
        if speaker.status == .connected {
            speaker.setVolume(volume)
            speaker.syncTime()
            ensureCaptureStarted()
            if connectedCount >= 2 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    guard let self, self.connectedCount >= 2 else { return }
                    self.syncDevices(applyNow: false)
                }
            }
        } else if connectedCount == 0 {
            stopCapture()
        }
    }

    private func speakerUnexpectedlyDisconnected(_ speaker: Speaker) {
        NotificationService.shared.postDisconnected(display: speaker.display, endpoint: speaker.endpointID)
    }

    private func updateCounts() {
        connectedCount = speakers.filter { $0.connected }.count
        connectingCount = speakers.filter { $0.connecting }.count
        audioControlsEnabled = connectedCount == 0 && connectingCount == 0
        updateFanout()
    }

    private func reconnect(endpoint: String) {
        guard let speaker = speakers.first(where: { $0.endpointID == endpoint }) else { return }
        connectSpeaker(speaker)
    }

    private func performInitialAutoConnect() {
        guard !didInitialAutoConnect else { return }
        didInitialAutoConnect = true
        guard autoConnect else { return }
        for speaker in speakers where speaker.channel != .none && speaker.status == .disconnected {
            connectSpeaker(speaker)
        }
    }

    // MARK: - Settings / APK / errors

    private func resetSpeakerSettings() {
        if isUSB {
            settings.adbDevices = speakers.map { DeviceSetting(id: $0.endpointID, channel: $0.channel) }
        } else {
            settings.ipDevices = speakers.map { DeviceSetting(id: $0.endpointID, channel: $0.channel) }
        }
        saveSettings()
    }

    private func saveSettings() {
        do {
            try SettingsStore.save(settings, to: settingsURL)
        } catch {
            Log.error("save settings failed: \(error.localizedDescription)")
        }
    }

    func resolvedAPKPath() -> String? {
        if let path = settings.apkPath, FileManager.default.fileExists(atPath: path) {
            return path
        }
        if let resource = Bundle.main.resourceURL?.appendingPathComponent("AudioShare.apk").path,
           FileManager.default.fileExists(atPath: resource) {
            return resource
        }
        if let executable = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("AudioShare.apk").path,
           FileManager.default.fileExists(atPath: executable) {
            return executable
        }
        return nil
    }

    func openPermissionSettings() {
        showPermissionGuide = false
        PermissionRequester.openSettings()
    }

    func dismissPermissionGuide() {
        showPermissionGuide = false
    }

    func chooseAPK() {
        let panel = NSOpenPanel()
        panel.title = L10n.t("chooseAPK")
        panel.allowedContentTypes = [UTType(filenameExtension: "apk") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.nameFieldStringValue = "AudioShare.apk"
        if panel.runModal() == .OK, let url = panel.url {
            settings.apkPath = url.path
            saveSettings()
            alert = AppAlert(title: L10n.t("title"), message: L10n.t("apkChosen") + url.lastPathComponent)
        }
    }

    private func showCaptureError(_ message: String) {
        let text = message.contains("权限") || message.contains("permission") ||
            message.contains("Tap") ? L10n.t("capturePermission") : message
        alert = AppAlert(title: L10n.t("captureError"), message: text)
        NotificationService.shared.post(title: L10n.t("title"), body: text)
    }

    // MARK: - Timers

    private func startTimers() {
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                for speaker in self.speakers where speaker.connected {
                    speaker.sendHeartbeat()
                }
            }
        }
        volumeTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.followSystemVolume else { return }
                self.applySystemVolume()
            }
        }
        if let heartbeatTimer {
            RunLoop.main.add(heartbeatTimer, forMode: .common)
        }
        if let volumeTimer {
            RunLoop.main.add(volumeTimer, forMode: .common)
        }
    }

    // MARK: - UI helpers

    var startupText: String { L10n.t("startup") }
    var title: String { "\(L10n.t("title")) 2.0.12" }
    var connectedLabel: String {
        connected ? L10n.f("connCount", connectedCount) : L10n.t("unconnected")
    }
    var statusColor: Int { connected ? 0 : 1 }
    var channelOptions: [AudioChannel] {
        availableChannels(sourceChannels: sourceChannels)
    }
    var allChannels: [AudioChannel] {
        channelMode.availableSpeakerChannels(sourceChannels: max(2, sourceChannels))
    }
}

extension AppModel {
    func shutdown() {
        heartbeatTimer?.invalidate()
        volumeTimer?.invalidate()
        autoConnectTimer?.invalidate()
        syncWorkItem?.cancel()
        disconnectAll()
        discovery.stop()
        audioEngine.stop()
    }
}
