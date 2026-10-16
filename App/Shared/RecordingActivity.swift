import ActivityKit
import Foundation
import EightyTwentyCore

/// A run or walk in progress, on the Lock Screen and in the Dynamic Island. The app
/// starts and updates it (`RecordingLiveActivity`); the widget extension draws it.
/// Compiled into both targets.
struct RecordingAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Moving time as of `at`. While moving, the clock runs on its own from `clockStart`.
        var movingSeconds: Double
        var at: Date
        var isPaused: Bool
        var meters: Double
        /// The latest distance update, like "2 miles in 18:40".
        var latest: String?

        var clockStart: Date { at.addingTimeInterval(-movingSeconds) }

        /// Seconds per meter so far; nil until there's enough distance to mean anything.
        var averagePace: Double? { meters >= 50 ? movingSeconds / meters : nil }
    }

    /// An `ActivityKind` raw value: run or walk.
    var kind: String
    var unitMeters: Double
    var unitLabel: String

    var activity: ActivityKind { ActivityKind(rawValue: kind) ?? .run }
}
