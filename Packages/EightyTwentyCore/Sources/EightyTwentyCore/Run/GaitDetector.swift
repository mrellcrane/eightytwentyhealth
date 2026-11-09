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

/// The phone's step count through a recording (Core Motion's pedometer), as running totals
/// from the start, for steps per minute over any stretch of it.
public struct StepTrack: Equatable, Sendable {
    public struct Count: Codable, Equatable, Sendable {
        public var at: Date
        /// Steps since the recording started.
        public var steps: Int
    }

    public private(set) var counts: [Count] = []

    /// How far past the last count the latest pace of stepping is assumed to carry on. The
    /// pedometer reports every few seconds, so the newest GPS fixes are usually past it.
    public static let carryOn: TimeInterval = 15

    public init() {}

    /// Starts the count at zero.
    public init(start: Date) {
        counts = [Count(at: start, steps: 0)]
    }

    /// A new running total. Ignored if it isn't later and at least as many steps.
    public mutating func add(at date: Date, steps: Int) {
        if let last = counts.last, date <= last.at || steps < last.steps { return }
        counts.append(Count(at: date, steps: steps))
    }

    /// Steps per minute between two times, or nil if the counts don't cover them.
    public func stepsPerMinute(from start: Date, to end: Date) -> Double? {
        guard end.timeIntervalSince(start) >= 3, let a = steps(at: start), let b = steps(at: end) else { return nil }
        return (b - a) / end.timeIntervalSince(start) * 60
    }

    /// Steps since the start at `date`, in between counts by straight line.
    private func steps(at date: Date) -> Double? {
        guard let first = counts.first, let last = counts.last, counts.count > 1, date >= first.at else { return nil }
        if date > last.at {
            guard date.timeIntervalSince(last.at) <= Self.carryOn else { return nil }
            let before = counts[counts.count - 2]
            let rate = Double(last.steps - before.steps) / last.at.timeIntervalSince(before.at)
            return Double(last.steps) + rate * date.timeIntervalSince(last.at)
        }
        // The first count at or after `date`.
        var low = 0, high = counts.count - 1
        while low < high {
            let mid = (low + high) / 2
            if counts[mid].at < date { low = mid + 1 } else { high = mid }
        }
        let after = counts[low]
        guard low > 0 else { return Double(after.steps) }
        let before = counts[low - 1]
        let fraction = date.timeIntervalSince(before.at) / after.at.timeIntervalSince(before.at)
        return Double(before.steps) + fraction * Double(after.steps - before.steps)
    }
}

/// Seconds spent at each value of something (speed, steps per minute), in fixed-width bins:
/// everything the learning needs from a recording, and small enough to keep dozens.
public struct Histogram: Codable, Equatable, Sendable {
    public let binWidth: Double
    /// Bin index (value / `binWidth`, rounded down) to seconds.
    public private(set) var seconds: [Int: Double] = [:]

    public init(binWidth: Double) {
        self.binWidth = binWidth
    }

    public mutating func add(_ value: Double, seconds duration: Double) {
        guard duration > 0, value.isFinite else { return }
        seconds[Int(value / binWidth), default: 0] += duration
    }

    public mutating func add(_ other: Histogram) {
        for (bin, value) in other.seconds { seconds[bin, default: 0] += value }
    }

    public var totalSeconds: Double { seconds.values.reduce(0, +) }

    /// Bin middles and their seconds.
    var bins: [(value: Double, seconds: Double)] {
        seconds.map { ((Double($0.key) + 0.5) * binWidth, $0.value) }
    }

    public static let speedBin = 0.1
    public static let cadenceBin = 2.0

    /// How fast you went, in meters per second, from the tracker's distance samples.
    public static func speeds(_ samples: [DistanceSample]) -> Histogram {
        var histogram = Histogram(binWidth: speedBin)
        for sample in samples {
            let duration = sample.end.timeIntervalSince(sample.start)
            // Longer than a minute is one average over many paces (Health has runs saved
            // as one sample from start to finish), not a pace.
            guard duration >= 1, duration <= 60 else { continue }
            let speed = sample.meters / duration
            // Creeping along or a GPS jump, not a pace anyone walks or runs at.
            guard speed >= 0.3, speed <= 7.5 else { continue }
            histogram.add(speed, seconds: duration)
        }
        return histogram
    }

    /// Steps per minute over the same moving stretches.
    public static func cadences(_ samples: [DistanceSample], steps: StepTrack) -> Histogram {
        var histogram = Histogram(binWidth: cadenceBin)
        for sample in samples {
            let duration = sample.end.timeIntervalSince(sample.start)
            guard duration >= 1, duration <= 60, let cadence = steps.stepsPerMinute(from: sample.start, to: sample.end),
                  cadence >= 40, cadence <= 250 else { continue }
            histogram.add(cadence, seconds: duration)
        }
        return histogram
    }
}

/// Your recent recordings' speeds and steps per minute, one pair of histograms each, so a
/// discarded recording can be taken back out. Old ones fall off, so it follows you as you
/// get fitter.
public struct PaceHistory: Codable, Equatable, Sendable {
    public struct Recording: Codable, Equatable, Sendable {
        public var start: Date
        public var speeds: Histogram
        public var cadences: Histogram
    }

    public static let kept = 40

    public private(set) var recordings: [Recording] = []

    public init() {}

    public mutating func record(start: Date, samples: [DistanceSample], steps: StepTrack = StepTrack()) {
        let speeds = Histogram.speeds(samples)
        let cadences = Histogram.cadences(samples, steps: steps)
        recordings.removeAll { $0.start == start }
        guard speeds.totalSeconds > 0 || cadences.totalSeconds > 0 else { return }
        recordings.append(Recording(start: start, speeds: speeds, cadences: cadences))
        recordings.sort { $0.start < $1.start }
        if recordings.count > Self.kept { recordings.removeFirst(recordings.count - Self.kept) }
    }

    public mutating func remove(start: Date) {
        recordings.removeAll { $0.start == start }
    }

    public func contains(start: Date) -> Bool { recordings.contains { $0.start == start } }

    /// Every recording's speeds together, leaving out the one that started at `excluding`.
    public func speeds(excluding start: Date? = nil) -> Histogram {
        combined(\.speeds, binWidth: Histogram.speedBin, excluding: start)
    }

    public func cadences(excluding start: Date? = nil) -> Histogram {
        combined(\.cadences, binWidth: Histogram.cadenceBin, excluding: start)
    }

    private func combined(_ path: KeyPath<Recording, Histogram>, binWidth: Double, excluding start: Date?) -> Histogram {
        var all = Histogram(binWidth: binWidth)
        for recording in recordings where recording.start != start { all.add(recording[keyPath: path]) }
        return all
    }
}

/// Your walking and running, by pace and by steps per minute, and the line between them for each.
public struct PaceProfile: Equatable, Sendable {
    /// Meters per second.
    public var walkSpeed: Double
    public var runSpeed: Double
    /// At or above this many meters per second is running (when there are no steps to go by).
    public var threshold: Double
    /// Seconds of your own data behind each pace. Near 0 means it's still the starting guess.
    public var walkSeconds: Double
    public var runSeconds: Double

    /// Steps per minute.
    public var walkCadence: Double
    public var runCadence: Double
    /// At or above this many steps per minute is running.
    public var cadenceThreshold: Double
    public var walkCadenceSeconds: Double
    public var runCadenceSeconds: Double

    /// Learned from nothing: the research averages.
    public static let starting = GaitDetector.profile(speeds: Histogram(binWidth: Histogram.speedBin))

    /// At least as much of your own walking and running as the starting guess counts for
    /// (10 minutes each), so the paces are more yours than the averages.
    public var isLearned: Bool { walkSeconds >= GaitDetector.priorSeconds && runSeconds >= GaitDetector.priorSeconds }
    public var isCadenceLearned: Bool {
        walkCadenceSeconds >= GaitDetector.priorSeconds && runCadenceSeconds >= GaitDetector.priorSeconds
    }
}

/// Tells running from walking, and learns what your running and walking look like.
///
/// Two signals, both learned:
/// - **Steps per minute**, from the phone's pedometer, decide whenever there are step
///   counts. Walking is about 100-125 a minute and running 150-185, whatever the speed, so a
///   slow jog up a hill is still a run and a brisk walk is still a walk. The line starts at
///   about 140 (the cadence at the walk-run switch).
/// - **Pace** decides where there are no step counts (motion access off, or older
///   recordings imported from Apple Health). The line starts at about 2 m/s (13:05 /mi,
///   8:10 /km), where people switch from walking to running as a treadmill speeds up
///   (Hreljac 1993, preferred transition speed about 2.0 m/s).
///
/// Learning: every saved recording's speeds and cadences go into a two-group model for
/// each (a Gaussian mixture fitted by EM), one group for your walking and one for your
/// running, each pulled toward the research average until there's enough of your own
/// data. The line sits halfway between the two. A group with nothing in it (you only ever
/// run) stays near the average instead of wandering off into the other one's slow end.
///
/// Inside a recording, each of the tracker's distance samples (up to 10 seconds of moving)
/// is running or walking, and anything shorter than 20 seconds is folded into what's
/// around it, so a crossing doesn't count as a walk break.
public enum GaitDetector {
    /// Stretches shorter than this many moving seconds are folded into their neighbors.
    public static let minimumSeconds: Double = 20

    struct Prior {
        var mean: Double
        var sd: Double
    }

    // The starting guesses (research averages) and how many seconds of data they count as.
    // Walking 1.4 m/s (Bohannon 2011); an easy recreational run about 2.7 m/s (10:00 /mi).
    static let walkPrior = Prior(mean: 1.4, sd: 0.2)
    static let runPrior = Prior(mean: 2.7, sd: 0.4)
    // About 112 steps a minute walking and 165 running (Tudor-Locke 2018; Lee 2018).
    static let walkCadencePrior = Prior(mean: 112, sd: 8)
    static let runCadencePrior = Prior(mean: 165, sd: 10)
    static let priorSeconds: Double = 600
    /// However the data falls, the lines stay where walking and running can really meet.
    static let thresholdRange = 1.7...2.5
    static let cadenceThresholdRange = 125.0...155.0

    /// Your paces and cadences, learned from these.
    public static func profile(speeds: Histogram, cadences: Histogram = Histogram(binWidth: Histogram.cadenceBin)) -> PaceProfile {
        let pace = fit(speeds, walk: walkPrior, run: runPrior, floor: 0.1)
        let steps = fit(cadences, walk: walkCadencePrior, run: runCadencePrior, floor: 3)
        return PaceProfile(
            walkSpeed: pace.walk, runSpeed: pace.run, threshold: clamp((pace.walk + pace.run) / 2, thresholdRange),
            walkSeconds: pace.walkSeconds, runSeconds: pace.runSeconds,
            walkCadence: steps.walk, runCadence: steps.run,
            cadenceThreshold: clamp((steps.walk + steps.run) / 2, cadenceThresholdRange),
            walkCadenceSeconds: steps.walkSeconds, runCadenceSeconds: steps.runSeconds
        )
    }

    private static func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// Two Gaussians, walking and running, fitted to the histogram by EM with each one's
    /// mean and spread pulled toward its prior by `priorSeconds` of make-believe data.
    /// (Halfway between the means, not weighted by spread: that would let a tight walking
    /// group drag the line down into your brisk walking while running is still the wide guess.)
    private static func fit(_ histogram: Histogram, walk: Prior, run: Prior, floor: Double)
        -> (walk: Double, run: Double, walkSeconds: Double, runSeconds: Double) {
        let bins = histogram.bins
        let priors = [walk, run]
        var mean = priors.map(\.mean)
        var sd = priors.map(\.sd)
        var weight = [0.5, 0.5]
        var count = [0.0, 0.0]
        let total = bins.reduce(0) { $0 + $1.seconds }

        for _ in 0..<60 {
            var n = [0.0, 0.0], sum = [0.0, 0.0], squares = [0.0, 0.0]
            for bin in bins {
                var p = (0..<2).map { weight[$0] * density(bin.value, mean: mean[$0], sd: sd[$0]) }
                if p[0] + p[1] <= 0 {
                    // Far out in a tail where both round to zero: it belongs to the nearer side.
                    p = bin.value < (mean[0] + mean[1]) / 2 ? [1, 0] : [0, 1]
                }
                let both = p[0] + p[1]
                for k in 0..<2 {
                    let share = bin.seconds * p[k] / both
                    n[k] += share
                    sum[k] += share * bin.value
                    squares[k] += share * bin.value * bin.value
                }
            }
            var next = mean
            for k in 0..<2 {
                next[k] = (priorSeconds * priors[k].mean + sum[k]) / (priorSeconds + n[k])
                let spread = squares[k] - 2 * next[k] * sum[k] + next[k] * next[k] * n[k]
                let variance = (priorSeconds * priors[k].sd * priors[k].sd + max(0, spread)) / (priorSeconds + n[k])
                sd[k] = max(floor, variance.squareRoot())
                weight[k] = (n[k] + priorSeconds) / (total + 2 * priorSeconds)
            }
            let settled = abs(next[0] - mean[0]) < 1e-4 * priors[0].mean && abs(next[1] - mean[1]) < 1e-4 * priors[1].mean
            mean = next
            count = n
            if settled { break }
        }
        return (mean[0], mean[1], count[0], count[1])
    }

    private static func density(_ x: Double, mean: Double, sd: Double) -> Double {
        let z = (x - mean) / sd
        return exp(-z * z / 2) / sd
    }

    /// The recording's distance samples, in order, as running and walking stretches: by
    /// steps per minute where `steps` covers a sample, otherwise by speed.
    public static func split(_ samples: [DistanceSample], threshold: Double,
                             steps: StepTrack = StepTrack(), cadenceThreshold: Double = PaceProfile.starting.cadenceThreshold,
                             minimumSeconds: Double = minimumSeconds) -> [GaitSegment] {
        var segments: [GaitSegment] = []
        for sample in samples {
            let duration = max(0, sample.end.timeIntervalSince(sample.start))
            guard duration > 0 else {
                // No time to judge by: it goes with whatever came before.
                if !segments.isEmpty { segments[segments.count - 1].meters += sample.meters }
                continue
            }
            let gait: Gait
            if let cadence = steps.stepsPerMinute(from: sample.start, to: sample.end), cadence >= 40 {
                gait = cadence >= cadenceThreshold ? .run : .walk
            } else {
                gait = sample.meters / duration >= threshold ? .run : .walk
            }
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

    /// The recording split by what's been learned (`profile`) and its step counts.
    public static func split(_ samples: [DistanceSample], profile: PaceProfile, steps: StepTrack) -> [GaitSegment] {
        split(samples, threshold: profile.threshold, steps: steps, cadenceThreshold: profile.cadenceThreshold)
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
