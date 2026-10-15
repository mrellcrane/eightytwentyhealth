import Foundation
import UserNotifications

/// Local notifications: check-in reminders, the wind-down nudge, the morning
/// brief, and meditation bells.
///
/// Bells are notifications (not in-app audio) so they still ring with the
/// screen locked and the app suspended.
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()

    enum Reminder: String, CaseIterable {
        case mood = "reminder.mood"
        case gratitude = "reminder.gratitude"
        case windDown = "reminder.winddown"
    }

    static let morningBriefID = "morning.brief"
    private static let bellPrefix = "meditation.bell."
    private static let endID = "meditation.end"

    private var center: UNUserNotificationCenter { .current() }

    func configure() {
        center.delegate = self
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    // Show banners and play the bell sound even while the app is open.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    // MARK: Daily reminders

    /// Replaces any pending reminder of this kind with one at `hour:minute` every day.
    func setReminder(_ reminder: Reminder, enabled: Bool, hour: Int, minute: Int, title: String, body: String) async {
        center.removePendingNotificationRequests(withIdentifiers: [reminder.rawValue])
        guard enabled, await requestAuthorization() else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        try? await center.add(UNNotificationRequest(identifier: reminder.rawValue, content: content, trigger: trigger))
    }

    /// Delivers right away (used by the morning brief after a background sync).
    func post(id: String, title: String, body: String) async {
        guard await requestAuthorization() else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    // MARK: Meditation bells

    /// Schedules interval bells and the end bell, relative to now.
    func scheduleMeditationBells(intervalBellsIn: [TimeInterval], endIn: TimeInterval) async {
        cancelMeditationBells()
        guard await requestAuthorization() else { return }

        for (index, seconds) in intervalBellsIn.enumerated() where seconds > 0.5 {
            let content = UNMutableNotificationContent()
            content.title = "Bell"
            content.body = "Keep going."
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: Self.bellPrefix + "\(index)", content: content, trigger: trigger))
        }

        let content = UNMutableNotificationContent()
        content.title = "Session complete"
        content.body = "Nice. Open 80/20 to log it."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(endIn, 1), repeats: false)
        try? await center.add(UNNotificationRequest(identifier: Self.endID, content: content, trigger: trigger))
    }

    func cancelMeditationBells() {
        // Bell ids are deterministic, so remove them without listing what's pending.
        let ids = (0..<240).map { Self.bellPrefix + "\($0)" } + [Self.endID]
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }
}
