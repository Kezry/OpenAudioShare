import AppKit
import Foundation

/// The Core Audio tap permission lives under System Settings → Privacy &
/// Security → System Audio Recording Only ("仅系统录音"). There is no public
/// API to preflight it, so the app links users to that pane and lets the tap
/// itself trigger the system prompt.
enum PermissionRequester {
    static func openSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_SystemAudio",
            "x-apple.systempreferences:com.apple.preference.security?Privacy",
        ]
        for value in candidates {
            if let url = URL(string: value) {
                NSWorkspace.shared.open(url)
                return
            }
        }
    }
}
