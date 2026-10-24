import AudioShareCore
import Foundation

enum L10n {
    private static let zh: [String: String] = [
        "title": "音频同享",
        "startup": "开机启动",
        "autoConnect": "自动连接",
        "acrylic": "窗口透明",
        "connected": "已连接",
        "unconnected": "未连接",
        "connCount": "已连接 [%d]",
        "audioDeviceSelection": "请选择音频设备：",
        "refresh": "刷新",
        "captureMode": "采集模式：",
        "captureProfile": "适配：",
        "channelMode": "声道模式：",
        "audioPlaybackDevice": "音频播放设备：",
        "searchSpeaker": "搜索设备",
        "add": "添加",
        "volume": "音量：",
        "followSystem": "跟随系统",
        "gain": "增益：",
        "autoGain": "自动音量",
        "autoGainTip": "自动把不同电脑的采集响度归一到相同电平（换歌或静音后需数秒重新适应）",
        "connectAll": "一键连接",
        "disconnectAll": "一键断开",
        "syncDevices": "音频同步",
        "exit": "退出",
        "connecte": "连接",
        "disconnecte": "断开",
        "reconnecte": "重新连接",
        "remove": "移除",
        "disconnected": "已断开",
        "modeStereo": "立体声",
        "mode21": "2.1声道",
        "mode51": "5.1声道",
        "mode71": "7.1声道",
        "hintStereo": "左、右",
        "hint21": "左、右、重低音",
        "hint51": "左/右、中置、重低音、后置左/右",
        "hint71": "左/右、中置、重低音、环绕左/右、后置左/右",
        "chLeft": "前置左",
        "chRight": "前置右",
        "chCenter": "中置",
        "chLfe": "重低音",
        "chSideLeft": "环绕左",
        "chSideRight": "环绕右",
        "chBackLeft": "后置左",
        "chBackRight": "后置右",
        "chBackCenter": "后置中",
        "chStereo": "立体声",
        "chNone": "禁用",
        "captureDefault": "默认（轮询 100ms）",
        "captureEvent": "事件驱动（100ms）",
        "captureLowLatency": "低延迟（事件 20ms）",
        "captureCompatible": "兼容（轮询 200ms）",
        "profileAuto": "自动检测",
        "profileGeneric": "通用",
        "profileRealtek": "Realtek 公版",
        "profileDolby": "杜比",
        "profileSmartAudio": "智音/MaxxAudio",
        "adbMissing": "未找到 adb，已切换到 Wi-Fi 模式。可将 adb 放入应用 Resources 目录。",
        "apkMissing": "未找到 AudioShare.apk，无法自动安装 Android 应用。",
        "apkMismatch": "Android 应用未安装或版本不匹配，无法自动安装。",
        "ipParseError": "IP 地址或端口格式错误。",
        "captureError": "音频采集异常：",
        "capturePermission": "没有系统音频录制权限。请到“系统设置 → 隐私与安全性 → 系统音频录制”中允许 AudioShare，然后重启应用。",
        "multiChannelUnavailable": "当前输出设备只有 %d 声道，%s 将降级为可用的声道。",
        "addIPTitle": "添加播放设备",
        "addIPPrompt": "输入 Android 设备的 IP 地址和端口（例如 192.168.1.20:8088）：",
        "cancel": "取消",
        "ok": "确定",
        "chooseAPK": "选择 Android APK…",
        "apkChosen": "已选择 APK：",
        "noAudioDevice": "没有找到可用的音频输出设备。",
        "usbUnauthorized": "Android 设备未授权 USB 调试，请在设备上允许调试。",
        "usbNoDevice": "未发现 USB 设备，请连接数据线并开启 USB 调试。",
        "captureStarted": "音频采集已启动",
        "about": "关于 AudioShare",
        "showWindow": "显示主窗口",
        "quit": "退出 AudioShare",
        "menuConnectAll": "连接全部",
        "menuDisconnectAll": "断开全部",
        "menuSync": "音频同步",
        "permissionMenu": "系统录音权限…",
        "permissionTitle": "系统录音权限",
        "permissionMessage": "首次使用需要在“系统设置 → 隐私与安全性 → 仅系统录音”中允许 AudioShare，然后重新连接播放设备。",
        "openSettings": "打开系统设置",
        "later": "稍后",
        "waitingUSB": "等待 USB 设备…",
        "emptyIP": "搜索设备或手动添加 IP",
    ]

    private static let en: [String: String] = [
        "title": "Audio Share",
        "startup": "Startup",
        "autoConnect": "Auto connect",
        "acrylic": "Transparent",
        "connected": "Connected",
        "unconnected": "Not connected",
        "connCount": "Connected [%d]",
        "audioDeviceSelection": "Select an audio device:",
        "refresh": "Refresh",
        "captureMode": "Capture mode:",
        "captureProfile": "Profile:",
        "channelMode": "Channel mode:",
        "audioPlaybackDevice": "Audio playback devices:",
        "searchSpeaker": "Search devices",
        "add": "Add",
        "volume": "Volume:",
        "followSystem": "Follow system",
        "gain": "Gain:",
        "autoGain": "Auto volume",
        "autoGainTip": "Normalizes capture loudness across PCs; needs a few seconds to adapt after track changes or silence",
        "connectAll": "Connect all",
        "disconnectAll": "Disconnect all",
        "syncDevices": "Audio sync",
        "exit": "Exit",
        "connecte": "Connect",
        "disconnecte": "Disconnect",
        "reconnecte": "Reconnect",
        "remove": "Remove",
        "disconnected": "disconnected",
        "modeStereo": "Stereo",
        "mode21": "2.1",
        "mode51": "5.1",
        "mode71": "7.1",
        "hintStereo": "Left, right",
        "hint21": "Left, right, LFE",
        "hint51": "Front L/R, centre, LFE, rear L/R",
        "hint71": "Front L/R, centre, LFE, side L/R, rear L/R",
        "chLeft": "Front left",
        "chRight": "Front right",
        "chCenter": "Centre",
        "chLfe": "LFE",
        "chSideLeft": "Side left",
        "chSideRight": "Side right",
        "chBackLeft": "Rear left",
        "chBackRight": "Rear right",
        "chBackCenter": "Rear centre",
        "chStereo": "Stereo",
        "chNone": "Disabled",
        "captureDefault": "Default (poll 100ms)",
        "captureEvent": "Event-driven (100ms)",
        "captureLowLatency": "Low latency (event 20ms)",
        "captureCompatible": "Compatible (poll 200ms)",
        "profileAuto": "Auto detect",
        "profileGeneric": "Generic",
        "profileRealtek": "Realtek stock",
        "profileDolby": "Dolby",
        "profileSmartAudio": "SmartAudio/MaxxAudio",
        "adbMissing": "adb was not found; switched to Wi-Fi. Put the adb binary in the app's Resources folder.",
        "apkMissing": "AudioShare.apk was not found, so the Android app cannot be installed automatically.",
        "apkMismatch": "The Android app is not installed or the version does not match; install it manually.",
        "ipParseError": "Invalid IP address or port.",
        "captureError": "Audio capture error: ",
        "capturePermission": "System audio recording permission is missing. Allow AudioShare in System Settings → Privacy & Security → System Audio Recording, then restart the app.",
        "multiChannelUnavailable": "The output device has only %d channels; %s will fall back to the available channels.",
        "addIPTitle": "Add playback device",
        "addIPPrompt": "Enter the Android device IP and port (for example 192.168.1.20:8088):",
        "cancel": "Cancel",
        "ok": "OK",
        "chooseAPK": "Choose Android APK…",
        "apkChosen": "APK selected: ",
        "noAudioDevice": "No audio output device was found.",
        "usbUnauthorized": "USB debugging is not authorised. Allow debugging on the Android device.",
        "usbNoDevice": "No USB device found. Connect a cable and enable USB debugging.",
        "captureStarted": "Audio capture started",
        "about": "About AudioShare",
        "showWindow": "Show Window",
        "quit": "Quit AudioShare",
        "menuConnectAll": "Connect All",
        "menuDisconnectAll": "Disconnect All",
        "menuSync": "Audio Sync",
        "permissionMenu": "System Audio Permission…",
        "permissionTitle": "System Audio Recording",
        "permissionMessage": "Allow AudioShare in System Settings → Privacy & Security → System Audio Recording Only, then reconnect the playback device.",
        "openSettings": "Open System Settings",
        "later": "Later",
        "waitingUSB": "Waiting for USB devices…",
        "emptyIP": "Search for devices or add an IP",
    ]

    private static var language: String = {
        let code = Locale.preferredLanguages.first?.lowercased() ?? "en"
        return code.hasPrefix("zh") ? "zh" : "en"
    }()

    static var isChinese: Bool { language == "zh" }

    static func setLanguage(_ code: String) {
        language = code.lowercased().hasPrefix("zh") ? "zh" : "en"
    }

    static func t(_ key: String) -> String {
        let table = isChinese ? zh : en
        return table[key] ?? key
    }

    static func f(_ key: String, _ values: CVarArg...) -> String {
        String(format: t(key), arguments: values)
    }

    static func modeName(_ mode: ChannelMode) -> String {
        switch mode {
        case .stereo: return t("modeStereo")
        case .ch21: return t("mode21")
        case .ch51: return t("mode51")
        case .ch71: return t("mode71")
        }
    }

    static func modeHint(_ mode: ChannelMode) -> String {
        switch mode {
        case .stereo: return t("hintStereo")
        case .ch21: return t("hint21")
        case .ch51: return t("hint51")
        case .ch71: return t("hint71")
        }
    }

    static func channelName(_ channel: AudioChannel) -> String {
        switch channel {
        case .none: return t("chNone")
        case .left: return t("chLeft")
        case .right: return t("chRight")
        case .stereo: return t("chStereo")
        case .center: return t("chCenter")
        case .lfe: return t("chLfe")
        case .sideLeft: return t("chSideLeft")
        case .sideRight: return t("chSideRight")
        case .backLeft: return t("chBackLeft")
        case .backRight: return t("chBackRight")
        case .backCenter: return t("chBackCenter")
        }
    }

    static func captureModeName(_ mode: CaptureMode) -> String {
        switch mode {
        case .default: return t("captureDefault")
        case .eventSync: return t("captureEvent")
        case .lowLatency: return t("captureLowLatency")
        case .compatible: return t("captureCompatible")
        }
    }

    static func profileName(_ profile: CaptureProfile) -> String {
        switch profile {
        case .auto: return t("profileAuto")
        case .generic: return t("profileGeneric")
        case .realtek: return t("profileRealtek")
        case .dolby: return t("profileDolby")
        case .smartAudio: return t("profileSmartAudio")
        }
    }
}
