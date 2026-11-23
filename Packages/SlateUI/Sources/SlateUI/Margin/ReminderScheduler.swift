import Foundation
import SlateCore
@preconcurrency import UserNotifications

/// Due-date notifications for to-dos (margin and `TODO:` comments), through UserNotifications.
/// Only used inside the app bundle (the notification centre needs one).
@MainActor
final class ReminderScheduler: NSObject, UNUserNotificationCenterDelegate {
    /// Called when a notification is clicked: project folder, scene ID, and
    /// for a comment to-do its file and position.
    var onOpen: ((URL, String?, String?, Int?) -> Void)?

    private let center = UNUserNotificationCenter.current()
    static let prefix = "todo|"

    override init() {
        super.init()
        center.delegate = self
    }

    /// Replaces this project's scheduled reminders with `reminders`. Asks for
    /// permission the first time there's something to schedule.
    func schedule(_ reminders: [DueReminder], for root: URL) async {
        let prefix = Self.prefix + root.path + "|"
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        guard !reminders.isEmpty else { return }
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        } else if settings.authorizationStatus == .denied {
            return
        }
        for reminder in reminders {
            let content = UNMutableNotificationContent()
            content.title = reminder.title
            content.body = reminder.body
            content.sound = .default
            var info: [String: Any] = ["project": reminder.projectPath, "scene": reminder.sceneID ?? ""]
            if let path = reminder.path, let location = reminder.location {
                info["path"] = path
                info["location"] = location
            }
            content.userInfo = info
            let trigger = UNCalendarNotificationTrigger(dateMatching: reminder.fireDate, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger))
        }
    }

    /// Removes every to-do reminder Slate scheduled.
    func removeAll() async {
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(Self.prefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let path = info["project"] as? String
        let scene = (info["scene"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let file = info["path"] as? String
        let location = info["location"] as? Int
        completionHandler()
        guard let path else { return }
        Task { @MainActor in
            self.onOpen?(URL(filePath: path, directoryHint: .isDirectory), scene, file, location)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
