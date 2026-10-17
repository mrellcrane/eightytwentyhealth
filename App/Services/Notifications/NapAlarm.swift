import AlarmKit
import SwiftUI
import EightyTwentyCore

/// The nap's wake-up call. On iOS 26 it's a real alarm (AlarmKit): it rings with the
/// ringer on silent and through Focus, full screen on the Lock Screen. Before iOS 26,
/// or if alarms aren't allowed for the app, it's a notification, which silent mode mutes.
@MainActor
enum NapAlarm {
    /// True for a real alarm, false if it fell back to a notification.
    static func set(_ nap: Nap, notifications: NotificationService) async -> Bool {
        if #available(iOS 26.0, *), await setAlarm(id: nap.id, at: nap.alarmAt) {
            return true
        }
        await notifications.scheduleNapAlarm(in: nap.alarmAt.timeIntervalSinceNow)
        return false
    }

    /// Only for getting up early or cancelling: once the alarm is ringing, the
    /// Lock Screen's Stop button is how it ends.
    static func cancel(_ nap: Nap, notifications: NotificationService) {
        if #available(iOS 26.0, *) {
            try? AlarmManager.shared.cancel(id: nap.id)
        }
        notifications.cancelNapAlarm()
    }

    @available(iOS 26.0, *)
    private static func setAlarm(id: UUID, at date: Date) async -> Bool {
        let manager = AlarmManager.shared
        do {
            if manager.authorizationState == .notDetermined {
                _ = try await manager.requestAuthorization()
            }
            guard manager.authorizationState == .authorized else {
                Log.app.info("Alarms not allowed; the nap alarm is a notification")
                return false
            }
            // Alert only, no countdown: AlarmKit needs a widget for a countdown, and
            // the Nap screen shows one anyway.
            let configuration = AlarmManager.AlarmConfiguration<NapAlarmData>.alarm(
                schedule: .fixed(date),
                attributes: AlarmAttributes(presentation: AlarmPresentation(alert: alert), tintColor: .purple)
            )
            _ = try await manager.schedule(id: id, configuration: configuration)
            Log.app.info("Nap alarm set")
            return true
        } catch {
            Log.app.warning("Nap alarm not set: \(error.localizedDescription)")
            return false
        }
    }

    @available(iOS 26.0, *)
    private static var alert: AlarmPresentation.Alert {
        let title: LocalizedStringResource = "Time to get up"
        // iOS 26.1 made the Stop button the system's.
        if #available(iOS 26.1, *) {
            return AlarmPresentation.Alert(title: title)
        }
        return AlarmPresentation.Alert(title: title,
                                       stopButton: AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.circle"))
    }
}

/// AlarmKit's alarms carry a metadata type; a nap's carries nothing.
@available(iOS 26.0, *)
struct NapAlarmData: AlarmMetadata {}
