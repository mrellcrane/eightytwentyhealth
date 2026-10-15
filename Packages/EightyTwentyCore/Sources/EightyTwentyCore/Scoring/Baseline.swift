import Foundation

/// Scores a raw metric against the user's own recent history.
///
/// "HRV 48" means nothing on its own; "HRV a bit below *your* normal" does.
/// We use median and MAD (median absolute deviation) instead of mean and SD
/// so one freak day (a 39k-step hike, a sick night) doesn't warp the baseline.
public enum Baseline {
    /// Fewer prior days than this and we don't pretend to know your normal.
    public static let minimumSamples = 7

    /// The score that means "exactly your normal". Chosen to sit in the same
    /// neighborhood as a typical Oura score so components blend sensibly.
    public static let normalScore = 75.0
    /// Points per robust standard deviation.
    public static let pointsPerDeviation = 12.5

    /// Deviations smaller than this share of your normal are treated as noise, so a
    /// very steady week doesn't turn a 2 ms HRV dip into a "big drop".
    public static let minimumRelativeSpread = 0.05

    /// Robust z-score of `value` relative to `history`. Nil if history is too short.
    public static func robustZ(_ value: Double, history: [Double]) -> Double? {
        guard history.count >= minimumSamples else { return nil }
        let center = median(history)
        // 1.4826 scales MAD to match SD for normally distributed data.
        var spread = 1.4826 * median(history.map { abs($0 - center) })
        if spread < 1e-9 { spread = standardDeviation(history) }
        spread = max(spread, minimumRelativeSpread * abs(center))
        if spread < 1e-9 {
            if value == center { return 0 }
            return value > center ? 1 : -1
        }
        return (value - center) / spread
    }

    /// Maps a z-score onto 0-100 where 75 is your normal and +2 SD hits 100.
    public static func score(z: Double, higherIsBetter: Bool = true) -> Double {
        let signed = higherIsBetter ? z : -z
        return clamp(normalScore + pointsPerDeviation * signed)
    }

    public static func median(_ values: [Double]) -> Double {
        precondition(!values.isEmpty, "median of empty array")
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    public static func standardDeviation(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count - 1)
        return variance.squareRoot()
    }

    static func clamp(_ value: Double, _ low: Double = 0, _ high: Double = 100) -> Double {
        min(max(value, low), high)
    }
}
