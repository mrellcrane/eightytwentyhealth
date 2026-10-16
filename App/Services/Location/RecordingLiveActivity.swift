import ActivityKit
import Foundation
import EightyTwentyCore

/// Puts the run or walk you're recording on the Lock Screen and in the Dynamic Island,
/// and keeps it current. The clock ticks on its own; distance comes with updates.
@MainActor
final class RecordingLiveActivity {
    private var activity: Activity<RecordingAttributes>?
    private var lastUpdate = Date.distantPast

    /// GPS fixes come about once a second. A few seconds apart is plenty for the distance.
    private static let interval: TimeInterval = 5

    func start(_ kind: ActivityKind, unitMeters: Double, unitLabel: String, state: RecordingAttributes.ContentState) {
        end()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            Log.app.info("Live Activities are off for 80/20; recording without one")
            return
        }
        do {
            activity = try Activity.request(
                attributes: RecordingAttributes(kind: kind.rawValue, unitMeters: unitMeters, unitLabel: unitLabel),
                content: ActivityContent(state: state, staleDate: nil)
            )
            lastUpdate = .now
        } catch {
            Log.app.warning("Live Activity didn't start: \(error.localizedDescription)")
        }
    }

    /// `now` skips the wait: pause, resume, and distance updates show right away.
    func update(_ state: RecordingAttributes.ContentState, now: Bool = false) {
        guard let activity, now || Date().timeIntervalSince(lastUpdate) >= Self.interval else { return }
        lastUpdate = .now
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    /// Also clears one left behind if the app was closed mid-recording.
    func end() {
        activity = nil
        for activity in Activity<RecordingAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
