import Foundation

/// "Running", "Walking", "Stopped", said out loud as the recorder changes its mind, so you
/// can hear the run/walk detection working without looking at the phone.
///
/// A change has to hold for `hold` seconds before it's said, so a wobble in GPS or a few
/// shuffling steps at a crossing aren't. "Stopped" isn't said before anything else has
/// been (standing at the start while GPS settles).
public struct GaitCallouts: Sendable {
    public enum Callout: String, Sendable {
        case running, walking, stopped

        public init(_ gait: Gait) {
            self = gait == .run ? .running : .walking
        }

        public var spoken: String { rawValue.capitalized }
    }

    /// Seconds a new state has to last before it's said.
    public var hold: TimeInterval
    /// The last thing said. Nil at the start and after a pause.
    public private(set) var said: Callout?
    private var pending: (callout: Callout, since: Date)?

    public init(hold: TimeInterval = 6) {
        self.hold = hold
    }

    /// What the recorder thinks you're doing at `now`, nil when it can't tell yet. Returns
    /// what to say, if anything. `sure` skips the hold (iOS itself says you've stopped).
    public mutating func update(_ current: Callout?, at now: Date, sure: Bool = false) -> Callout? {
        guard let current, current != said, !(current == .stopped && said == nil) else {
            pending = nil
            return nil
        }
        if pending?.callout != current { pending = (current, now) }
        guard sure || now.timeIntervalSince(pending?.since ?? now) >= hold else { return nil }
        said = current
        pending = nil
        return current
    }

    /// Starts over, so the next gait is said even if it's the same as before (after a pause).
    public mutating func reset() {
        said = nil
        pending = nil
    }
}
