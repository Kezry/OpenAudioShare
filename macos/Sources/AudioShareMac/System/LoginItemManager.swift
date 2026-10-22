import Foundation

enum LoginItemManager {
    private static let label = "com.picapico.audioshare.mac"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// Returns nil on success, or a localized error message.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String? {
        if enabled {
            guard let executable = Bundle.main.executableURL?.path else {
                return "Cannot determine the application path."
            }
            let directory = plistURL.deletingLastPathComponent()
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let plist: [String: Any] = [
                    "Label": label,
                    "ProgramArguments": [executable],
                    "RunAtLoad": true,
                    "KeepAlive": false,
                    "ProcessType": "Interactive",
                ]
                let data = try PropertyListSerialization.data(fromPropertyList: plist,
                                                              format: .xml, options: 0)
                try data.write(to: plistURL, options: .atomic)
                return nil
            } catch {
                return error.localizedDescription
            }
        } else {
            do {
                if FileManager.default.fileExists(atPath: plistURL.path) {
                    try FileManager.default.removeItem(at: plistURL)
                }
                return nil
            } catch {
                return error.localizedDescription
            }
        }
    }
}
