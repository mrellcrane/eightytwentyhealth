import Foundation

/// One mile or km of a finished run or walk, for the log's detail page.
public struct DistanceSplit: Equatable, Sendable {
    /// 1 for the first mile or km.
    public let number: Int
    /// The full mile or km, or less for the bit left over at the end.
    public let meters: Double
    /// Moving seconds (stops and pauses aren't in the samples, so they aren't here either).
    public let seconds: Double

    public init(number: Int, meters: Double, seconds: Double) {
        self.number = number
        self.meters = meters
        self.seconds = seconds
    }

    /// Seconds per meter.
    public var pace: Double { seconds / meters }
}

public enum DistanceSplits {
    /// The run's distance samples (what was saved to Apple Health: up to 10 seconds of
    /// moving each) cut into `every`-meter splits, each crossing placed partway through the
    /// sample it falls in. The leftover at the end is a split of its own if it's at least
    /// 5% of one.
    public static func from(_ samples: [DistanceSample], every unit: Double) -> [DistanceSplit] {
        guard unit > 0 else { return [] }
        var splits: [DistanceSplit] = []
        var meters = 0.0
        var seconds = 0.0
        for sample in samples.sorted(by: { $0.start < $1.start }) {
            var left = max(0, sample.meters)
            var time = max(0, sample.end.timeIntervalSince(sample.start))
            while left > 0, meters + left >= unit {
                let needed = unit - meters
                let share = time * needed / left
                splits.append(DistanceSplit(number: splits.count + 1, meters: unit, seconds: seconds + share))
                left -= needed
                time -= share
                meters = 0
                seconds = 0
            }
            meters += left
            seconds += time
        }
        if meters >= unit * 0.05, seconds > 0 {
            splits.append(DistanceSplit(number: splits.count + 1, meters: meters, seconds: seconds))
        }
        return splits
    }
}
