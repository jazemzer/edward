import Foundation
import UserNotifications

/// Sends macOS notifications for transcribed speech
/// Only works when running as an app bundle (not bare CLI)
public final class NotificationManager {
    public static let shared = NotificationManager()
    private var isAuthorized = false
    private var isAvailable = false

    public func requestPermission() {
        // UNUserNotificationCenter crashes if not running in an app bundle
        guard Bundle.main.bundleIdentifier != nil else {
            log.info("Notifications unavailable (not running as app bundle)")
            return
        }

        isAvailable = true

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            self.isAuthorized = granted
            if let error = error {
                log.info("Notifications not available: \(error.localizedDescription)")
            } else {
                log.info("Notification permission: \(granted ? "granted" : "denied")")
            }
        }
    }

    public func notify(entry: TranscriptEntry) {
        guard isAvailable, isAuthorized else { return }

        let content = UNMutableNotificationContent()
        content.title = "Edward heard speech"
        content.body = entry.text
        content.sound = nil // Silent — don't interrupt

        let request = UNNotificationRequest(
            identifier: "edward-\(entry.id)",
            content: content,
            trigger: nil // Deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                log.error("Notification error: \(error)")
            }
        }
    }
}
