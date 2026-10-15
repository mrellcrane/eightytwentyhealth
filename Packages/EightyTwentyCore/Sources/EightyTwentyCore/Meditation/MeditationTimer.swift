import Foundation

/// Meditation timer math, based on wall-clock dates so it stays right when the
/// phone locks mid-session and the app gets suspended.
public struct MeditationTimer: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case ready
        case running
        case paused
        case completed
    }

    public var duration: Double
    /// Seconds between interval bells; nil for none.
    public var intervalBell: Double?

    public private(set) var state: State = .ready
    public private(set) var startedAt: Date?
    private var pausedAt: Date?
    private var pausedDuration: Double = 0

    public init(duration: Double, intervalBell: Double? = nil) {
        self.duration = duration
        self.intervalBell = intervalBell
    }

    public mutating func start(at date: Date) {
        guard state == .ready else { return }
        state = .running
        startedAt = date
    }

    public mutating func pause(at date: Date) {
        guard state == .running else { return }
        state = .paused
        pausedAt = date
    }

    public mutating func resume(at date: Date) {
        guard state == .paused, let pausedAt else { return }
        pausedDuration += max(0, date.timeIntervalSince(pausedAt))
        self.pausedAt = nil
        state = .running
    }

    /// Call on every tick; flips to `.completed` once time is up.
    public mutating func update(at date: Date) {
        if state == .running, elapsed(at: date) >= duration {
            state = .completed
        }
    }

    /// Ends early (e.g. "I'm done"). The session still counts for what was sat.
    public mutating func end(at date: Date) {
        guard state == .running || state == .paused else { return }
        if state == .paused, let pausedAt {
            pausedDuration += max(0, date.timeIntervalSince(pausedAt))
            self.pausedAt = nil
        }
        duration = min(duration, elapsed(at: date))
        state = .completed
    }

    public func elapsed(at date: Date) -> Double {
        guard let startedAt else { return 0 }
        let reference = state == .paused ? (pausedAt ?? date) : date
        return min(duration, max(0, reference.timeIntervalSince(startedAt) - pausedDuration))
    }

    public func remaining(at date: Date) -> Double {
        max(0, duration - elapsed(at: date))
    }

    public func progress(at date: Date) -> Double {
        duration > 0 ? elapsed(at: date) / duration : 0
    }

    /// How many interval bells should have rung by `date` (excluding the final bell).
    public func bellsDue(at date: Date) -> Int {
        guard let intervalBell, intervalBell > 0 else { return 0 }
        let elapsed = elapsed(at: date)
        let all = Int(elapsed / intervalBell)
        // A bell landing exactly on the end is the end bell, not an interval bell.
        let maxIntervalBells = Int((duration - 0.001) / intervalBell)
        return min(all, max(0, maxIntervalBells))
    }

    /// Seconds from start (in active time) at which interval bells ring.
    public var bellOffsets: [Double] {
        guard let intervalBell, intervalBell > 0 else { return [] }
        return stride(from: intervalBell, to: duration, by: intervalBell).map { $0 }
    }

    /// Whole minutes worth logging (we don't log a 20-second accidental start).
    public func loggableMinutes(at date: Date) -> Double? {
        let minutes = elapsed(at: date) / 60
        return minutes >= 1 ? minutes : nil
    }
}
