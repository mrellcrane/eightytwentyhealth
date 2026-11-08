import Foundation

/// Running or walking, from moment to moment inside one recording.
public enum Gait: String, Codable, Sendable, CaseIterable {
    case walk
    case run

    /// What a recording that's mostly this gets saved as.
    public var activity: ActivityKind { self == .run ? .run : .walk }
}

/// A stretch of a recording spent running or walking. Stops and pauses inside it are left
/// out of `seconds`, as they are from the recording's moving time.
public struct GaitSegment: Equatable, Sendable {
    public var gait: Gait
    public var start: Date
    public var end: Date
    /// Moving seconds.
    public var seconds: Double
    public var meters: Double

    public init(gait: Gait, start: Date, end: Date, seconds: Double, meters: Double) {
        self.gait = gait
        self.start = start
        self.end = end
        self.seconds = seconds
        self.meters = meters
    }

    /// Seconds per meter.
    public var pace: Double? { meters > 0 ? seconds / meters : nil }
}

/// A piece of the route drawn in one gait's color.
public struct GaitLine: Sendable {
    public let gait: Gait
    public let points: [RoutePoint]
}

/// Seconds spent at each speed, in 0.1 m/s bins: everything the pace learning needs from a
/// recording, and small enough to keep dozens of them.
public struct SpeedHistogram: Codable, Equatable, Sendable {
    public static let binWidth = 0.1

    /// Bin index (speed / `binWidth`, rounded down) to seconds.
    public private(set) var seconds: [Int: Double] = [:]

    public init() {}

    public init(_ samples: [DistanceSample]) {
        for sample in samples { add(sample) }
    }

    public mutating func add(_ sample: DistanceSample) {
        let duration = sample.end.timeIntervalSince(sample.start)
        guard duration >= 1 else { return }
        let speed = sample.meters / duration
        // Creeping along or a GPS jump, not a pace anyone walks or runs at.
        guard speed >= 0.3, speed <= 7.5 else { return }
        seconds[Int(speed / Self.binWidth), default: 0] += duration
    }

    public mutating func add(_ other: SpeedHistogram) {
        for (bin, value) in other.seconds { seconds[bin, default: 0] += value }
    }

    public var totalSeconds: Double { seconds.values.reduce(0, +) }
}

/// The speeds of your recent recordings, one histogram each, so a discarded recording can
/// be taken back out. Old ones fall off, so it follows you as you get fitter.
public struct PaceHistory: Codable, Equatable, Sendable {
    public struct Recording: Codable, Equatable, Sendable {
        public var start: Date
        public var speeds: SpeedHistogram
    }

    public static let kept = 40

    public private(set) var recordings: [Recording] = []

    public init() {}

    public mutating func record(start: Date, samples: [DistanceSample]) {
        let speeds = SpeedHistogram(samples)
        recordings.removeAll { $0.start == start }
        guard speeds.totalSeconds > 0 else { return }
        recordings.append(Recording(start: start, speeds: speeds))
        recordings.sort { $0.start < $1.start }
        if recordings.count > Self.kept { recordings.removeFirst(recordings.count - Self.kept) }
    }

    public mutating func remove(start: Date) {
        recordings.removeAll { $0.start == start }
    }

    public func contains(start: Date) -> Bool { recordings.contains { $0.start == start } }

    /// Every recording's speeds together, leaving out the one that started at `excluding`.
    public func speeds(excluding start: Date? = nil) -> SpeedHistogram {
        var all = SpeedHistogram()
        for recording in recordings where recording.start != start { all.add(recording.speeds) }
        return all
    }
}

/// Your walking pace, your running pace, and the line between them.
public struct PaceProfile: Equatable, Sendable {
    /// Meters per second.
    public var walkSpeed: Double
    public var runSpeed: Double
    /// At or above this many meters per second is running.
    public var threshold: Double
    /// Seconds of your own data behind each pace. Near 0 means it's still the starting guess.
    public var walkSeconds: Double
    public var runSeconds: Double

    /// Learned from nothing: the research averages.
    public static let starting = GaitDetector.profile(from: SpeedHistogram())

    /// At least as much of your own walking and running as the starting guess counts for
    /// (10 minutes each), so the paces are more yours than the averages.
    public var isLearned: Bool { walkSeconds >= GaitDetector.priorSeconds && runSeconds >= GaitDetector.priorSeconds }
}

/// Tells running from walking by speed, and learns what your running and walking paces are.
///
/// The line starts at about 2 m/s (13:05 /mi, 8:10 /km), where people switch from walking
/// to running when a treadmill speeds up (Hreljac 1993, preferred transition speed about
/// 2.0 m/s). From there it learns: every recording's speeds go into a two-group model (a
/// Gaussian mixture fitted by EM), one group for your walking and one for your running,
/// each pulled toward the research average until there's enough of your own data. The
/// line sits halfway between the two. A group with nothing in it (you only ever run)
/// stays near the average instead of wandering off into the other one's slow or fast end.
///
/// Inside a recording, each of the tracker's distance samples (up to 10 seconds of moving)
/// is running or walking by its speed, and anything shorter than 20 seconds is folded
/// into what's around it, so a hill or a crossing doesn't count as a walk break.
public enum GaitDetector {
    /// Stretches shorter than this many moving seconds are folded into their neighbors.
    public static let minimumSeconds: Double = 20

    // The starting guesses (research averages) and how many seconds of data they count as.
    // Walking 1.4 m/s (Bohannon 2011); an easy recreational run about 2.7 m/s (10:00 /mi).
    static let walkPrior = (mean: 1.4, sd: 0.2)
    static let runPrior = (mean: 2.7, sd: 0.4)
    static let priorSeconds: Double = 600
    /// However the data falls, the line stays where walking and running can really meet.
    static let thresholdRange = 1.7...2.5

    /// Your paces, learned from these speeds.
    public static func profile(from speeds: SpeedHistogram) -> PaceProfile {
        let bins = speeds.seconds.map { (speed: (Double($0.key) + 0.5) * SpeedHistogram.binWidth, seconds: $0.value) }
        let priorMean = [walkPrior.mean, runPrior.mean]
        let priorSD = [walkPrior.sd, runPrior.sd]
        var mean = priorMean
        var sd = priorSD
        var weight = [0.5, 0.5]
        var count = [0.0, 0.0]
        let total = bins.reduce(0) { $0 + $1.seconds }

        for _ in 0..<60 {
            var n = [0.0, 0.0], sum = [0.0, 0.0], squares = [0.0, 0.0]
            for bin in bins {
                var p = (0..<2).map { weight[$0] * density(bin.speed, mean: mean[$0], sd: sd[$0]) }
                if p[0] + p[1] <= 0 {
                    // Far out in a tail where both round to zero: it belongs to the nearer side.
                    p = bin.speed < (mean[0] + mean[1]) / 2 ? [1, 0] : [0, 1]
                }
                let both = p[0] + p[1]
                for k in 0..<2 {
                    let share = bin.seconds * p[k] / both
                    n[k] += share
                    sum[k] += share * bin.speed
                    squares[k] += share * bin.speed * bin.speed
                }
            }
            var next = mean
            for k in 0..<2 {
                next[k] = (priorSeconds * priorMean[k] + sum[k]) / (priorSeconds + n[k])
                let spread = squares[k] - 2 * next[k] * sum[k] + next[k] * next[k] * n[k]
                let variance = (priorSeconds * priorSD[k] * priorSD[k] + max(0, spread)) / (priorSeconds + n[k])
                sd[k] = max(0.1, variance.squareRoot())
                weight[k] = (n[k] + priorSeconds) / (total + 2 * priorSeconds)
            }
            let settled = abs(next[0] - mean[0]) < 1e-4 && abs(next[1] - mean[1]) < 1e-4
            mean = next
            count = n
            if settled { break }
        }

        // Halfway in speed. (Weighting by spread lets a tight walking group drag the line
        // down into your brisk walking while the running group is still the wide guess.)
        let line = (mean[0] + mean[1]) / 2
        let threshold = min(max(line, thresholdRange.lowerBound), thresholdRange.upperBound)
        return PaceProfile(walkSpeed: mean[0], runSpeed: mean[1], threshold: threshold,
                           walkSeconds: count[0], runSeconds: count[1])
    }

    private static func density(_ x: Double, mean: Double, sd: Double) -> Double {
        let z = (x - mean) / sd
        return exp(-z * z / 2) / sd
    }

    /// The recording's distance samples, in order, as running and walking stretches.
    public static func split(_ samples: [DistanceSample], threshold: Double,
                             minimumSeconds: Double = minimumSeconds) -> [GaitSegment] {
        var segments: [GaitSegment] = []
        for sample in samples {
            let duration = max(0, sample.end.timeIntervalSince(sample.start))
            guard duration > 0 else {
                // No time to judge a speed by: it goes with whatever came before.
                if !segments.isEmpty { segments[segments.count - 1].meters += sample.meters }
                continue
            }
            let gait: Gait = sample.meters / duration >= threshold ? .run : .walk
            if let last = segments.last, last.gait == gait {
                segments[segments.count - 1].end = sample.end
                segments[segments.count - 1].seconds += duration
                segments[segments.count - 1].meters += sample.meters
            } else {
                segments.append(GaitSegment(gait: gait, start: sample.start, end: sample.end, seconds: duration, meters: sample.meters))
            }
        }

        // Fold the shortest blip into its neighbors until none is left. Gaits alternate, so
        // the two either side are the same and the three become one.
        while segments.count > 1 {
            guard let shortest = segments.indices.filter({ segments[$0].seconds < minimumSeconds })
                .min(by: { segments[$0].seconds < segments[$1].seconds }) else { break }
            let from = max(shortest - 1, 0)
            let to = min(shortest + 1, segments.count - 1)
            let gait = shortest > 0 ? segments[shortest - 1].gait : segments[shortest + 1].gait
            let merged = GaitSegment(
                gait: gait,
                start: segments[from].start,
                end: segments[to].end,
                seconds: segments[from...to].reduce(0) { $0 + $1.seconds },
                meters: segments[from...to].reduce(0) { $0 + $1.meters }
            )
            segments.replaceSubrange(from...to, with: [merged])
        }
        return segments
    }

    /// Moving seconds and meters spent in each gait.
    public static func totals(_ segments: [GaitSegment]) -> [Gait: (seconds: Double, meters: Double)] {
        var totals: [Gait: (seconds: Double, meters: Double)] = [:]
        for segment in segments {
            let sofar = totals[segment.gait] ?? (0, 0)
            totals[segment.gait] = (sofar.seconds + segment.seconds, sofar.meters + segment.meters)
        }
        return totals
    }

    /// What a recording counts as: a run if you ran at least half of the moving time, so a
    /// run with walk breaks is a run and a walk with a short jog in it is a walk. Nil
    /// before there's anything to go on.
    public static func activity(for segments: [GaitSegment]) -> ActivityKind? {
        let totals = totals(segments)
        let run = totals[.run]?.seconds ?? 0
        let walk = totals[.walk]?.seconds ?? 0
        guard run + walk > 0 else { return nil }
        return run >= walk ? .run : .walk
    }

    /// The route (the tracker's segments, split at pauses) cut into lines by gait, each new
    /// line starting where the last one ended so the route stays joined up.
    public static func lines(_ tracks: [[RoutePoint]], gaits: [GaitSegment], otherwise: Gait) -> [GaitLine] {
        var lines: [GaitLine] = []
        var index = 0
        for track in tracks {
            var current: Gait?
            var points: [RoutePoint] = []
            for point in track {
                // The stretch this point falls in, or the next one if it's in a stop between two.
                while index < gaits.count - 1, gaits[index].end < point.timestamp { index += 1 }
                let gait = gaits.isEmpty ? otherwise : gaits[index].gait
                if let current, gait != current {
                    if points.count > 1 { lines.append(GaitLine(gait: current, points: points)) }
                    points = points.last.map { [$0] } ?? []
                }
                current = gait
                points.append(point)
            }
            if let current, points.count > 1 { lines.append(GaitLine(gait: current, points: points)) }
        }
        return lines
    }
}
