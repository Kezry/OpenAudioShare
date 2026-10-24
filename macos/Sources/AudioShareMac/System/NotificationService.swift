import Foundation
import UserNotifications

final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()
    var onReconnect: ((String) -> Void)?

    private let center = UNUserNotificationCenter.current()
    private var configured = false

    func requestAuthorization() {
        configure()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                Log.error("notification authorization failed: \(error.localizedDescription)")
            } else if !granted {
                Log.info("notifications not authorised")
            }
            self.center.delegate = self
        }
    }

    private func configure() {
        guard !configured else { return }
        configured = true
        let action = UNNotificationAction(identifier: "RECONNECT",
                                          title: L10n.t("reconnecte"), options: [])
        let category = UNNotificationCategory(identifier: "DISCONNECTED",
                                              actions: [action],
                                              intentIdentifiers: [],
                                              options: [])
        center.setNotificationCategories([category])
        center.delegate = self
    }

    func post(title: String, body: String) {
        configure()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        center.add(request) { error in
            if let error {
                Log.error("notification post failed: \(error.localizedDescription)")
            }
        }
    }

    func postDisconnected(display: String, endpoint: String) {
        configure()
        let content = UNMutableNotificationContent()
        content.title = L10n.t("title")
        content.body = "\(display) \(L10n.t("disconnected"))"
        content.sound = .default
        content.categoryIdentifier = "DISCONNECTED"
        content.userInfo = ["endpoint": endpoint]
        let request = UNNotificationRequest(identifier: "disconnect-\(endpoint)",
                                            content: content, trigger: nil)
        center.add(request)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == "RECONNECT",
           let endpoint = response.notification.request.content.userInfo["endpoint"] as? String {
            DispatchQueue.main.async { [weak self] in
                self?.onReconnect?(endpoint)
            }
        }
        completionHandler()
    }
}
