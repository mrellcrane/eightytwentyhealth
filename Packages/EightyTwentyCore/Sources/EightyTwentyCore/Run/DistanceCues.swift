import Foundation

/// Updates while you record, every so many miles or km: "2 miles in 18:40. Average
/// 9:20 /mi. Last mile 9:45." Shown as a notification and, if you like, read out loud.
public struct DistanceCues: Sendable {
    public struct Cue: Equatable, Sendable {
        /// 1 for the first mark, 2 for the second...
        public let number: Int
        /// Where the mark is, in meters.
        public let meters: Double
        /// Moving seconds when you reached it.
        public let seconds: Double
        /// Moving seconds for the last interval (the average, if a GPS gap skipped marks).
        public let lastSeconds: Double
    }

    public struct Message: Equatable, Sendable {
        public let title: String
        public let body: String
        public let spoken: String
    }

    /// Choices for "every", in miles or km.
    public static let choices: [Double] = [0.25, 0.5, 1, 2]

    /// Every this many miles or km.
    public let units: Double
    public let usesMiles: Bool

    private var count: Int
    private var previous: (meters: Double, seconds: Double)
    private var lastCueSeconds: Double

    /// `meters` and `seconds` so far, when updates are switched on or changed mid-recording.
    public init(every units: Double, usesMiles: Bool, meters: Double = 0, seconds: Double = 0) {
        self.units = units
        self.usesMiles = usesMiles
        let every = units * (usesMiles ? RunningPlan.metersPerMile : 1000)
        count = every > 0 ? Int(meters / every) : 0
        previous = (meters, seconds)
        // The next "last interval" assumes your pace so far for the marks already passed.
        lastCueSeconds = meters > 0 ? seconds * Double(count) * every / meters : 0
    }

    public var unitMeters: Double { usesMiles ? RunningPlan.metersPerMile : 1000 }
    public var every: Double { units * unitMeters }

    /// Feed after each accepted GPS fix. Returns a cue when you've passed the next mark.
    public mutating func update(meters: Double, seconds: Double) -> Cue? {
        defer { previous = (meters, seconds) }
        guard every > 0 else { return nil }
        let reached = Int(meters / every)
        guard reached > count else { return nil }
        // When you crossed the mark, between the last fix and this one.
        let mark = Double(reached) * every
        let span = meters - previous.meters
        let fraction = span > 0 ? min(max((mark - previous.meters) / span, 0), 1) : 1
        let at = previous.seconds + (seconds - previous.seconds) * fraction
        let cue = Cue(number: reached, meters: mark, seconds: at,
                      lastSeconds: (at - lastCueSeconds) / Double(reached - count))
        count = reached
        lastCueSeconds = at
        return cue
    }

    public func message(_ cue: Cue) -> Message {
        let done = cue.meters / unitMeters
        let average = cue.seconds / done
        let lastPace = cue.lastSeconds / units
        let unit = usesMiles ? "mi" : "km"
        let distance = Self.distance(done, usesMiles: usesMiles, spoken: false)

        var body = "Average \(Self.pace(average)) /\(unit)."
        var spoken = "\(Self.distance(done, usesMiles: usesMiles, spoken: true)). Time \(Self.spokenDuration(cue.seconds))."
        if average < Self.slowestPace {
            spoken += " Average pace \(Self.spokenDuration(average)) per \(usesMiles ? "mile" : "kilometer")."
        }
        // After the first mark, the last interval says whether you're speeding up or slowing down.
        if cue.number > 1 {
            if units == 1 {
                body += " Last \(usesMiles ? "mile" : "km") \(PaceFormat.duration(cue.lastSeconds))."
                spoken += " Last \(usesMiles ? "mile" : "kilometer") \(Self.spokenDuration(cue.lastSeconds))."
            } else if lastPace < Self.slowestPace {
                body += " Last \(Self.number(units)) \(unit) at \(Self.pace(lastPace)) /\(unit)."
                spoken += " Last \(Self.distance(units, usesMiles: usesMiles, spoken: true)) at \(Self.spokenDuration(lastPace)) per \(usesMiles ? "mile" : "kilometer")."
            }
        }
        return Message(title: "\(distance) in \(PaceFormat.duration(cue.seconds))", body: body, spoken: spoken)
    }

    /// Slower than this per unit isn't worth reading out (standing around, GPS drift).
    static let slowestPace = 100.0 * 60

    /// "1", "0.5", "2.25".
    public static func number(_ value: Double) -> String {
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// "1 mile", "2.5 miles", "3 km"; spoken, "3 kilometers".
    public static func distance(_ units: Double, usesMiles: Bool, spoken: Bool) -> String {
        let value = number(units)
        let one = value == "1"
        if usesMiles { return "\(value) \(one ? "mile" : "miles")" }
        return spoken ? "\(value) \(one ? "kilometer" : "kilometers")" : "\(value) km"
    }

    /// "9:20", from seconds per unit.
    static func pace(_ secondsPerUnit: Double) -> String {
        PaceFormat.duration(secondsPerUnit.rounded())
    }

    /// 565 -> "9 minutes 25 seconds"; 3725 -> "1 hour 2 minutes 5 seconds".
    public static func spokenDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        var parts: [String] = []
        if h > 0 { parts.append("\(h) \(h == 1 ? "hour" : "hours")") }
        if m > 0 { parts.append("\(m) \(m == 1 ? "minute" : "minutes")") }
        if s > 0 || parts.isEmpty { parts.append("\(s) \(s == 1 ? "second" : "seconds")") }
        return parts.joined(separator: " ")
    }
}
