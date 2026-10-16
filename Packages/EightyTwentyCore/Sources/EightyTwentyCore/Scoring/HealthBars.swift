import Foundation

public enum BarKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case physical
    case mental

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .physical: return "Physical"
        case .mental: return "Mental"
        }
    }
}

public enum ComponentID: String, Codable, CaseIterable, Sendable {
    // Physical
    case readiness
    case sleep
    case hrv
    case restingHeartRate
    case activity
    case vo2Max
    // Mental
    case mood
    case stressBalance
    case mentalSleep
    case practice

    public var title: String {
        switch self {
        case .readiness: return "Readiness"
        case .sleep, .mentalSleep: return "Sleep"
        case .hrv: return "HRV"
        case .restingHeartRate: return "Resting HR"
        case .activity: return "Steps"
        case .vo2Max: return "VO2 max"
        case .mood: return "Mood"
        case .stressBalance: return "Stress vs recovery"
        case .practice: return "Practices (7 days)"
        }
    }
}

/// How much each component counts toward its bar. Weights within a bar should sum to 1.
public struct BarWeights: Codable, Equatable, Sendable {
    public var physical: [ComponentID: Double]
    public var mental: [ComponentID: Double]

    public init(physical: [ComponentID: Double], mental: [ComponentID: Double]) {
        self.physical = physical
        self.mental = mental
    }

    public static let `default` = BarWeights(
        physical: [
            .readiness: 0.30,
            .sleep: 0.25,
            .hrv: 0.15,
            .restingHeartRate: 0.10,
            .activity: 0.15,
            .vo2Max: 0.05,
        ],
        mental: [
            .mood: 0.40,
            .stressBalance: 0.25,
            .mentalSleep: 0.15,
            .practice: 0.20,
        ]
    )

    public func weights(for kind: BarKind) -> [ComponentID: Double] {
        kind == .physical ? physical : mental
    }
}

public struct ComponentScore: Equatable, Sendable {
    public let id: ComponentID
    /// 0-100.
    public let score: Double
    public let weight: Double
    /// Plain-English explanation, e.g. "48 ms vs your usual 52 ms".
    public let detail: String
}

/// One bar on one day, before smoothing.
public struct BarReading: Equatable, Sendable {
    public let kind: BarKind
    public let day: DayKey
    /// Nil when too little data was available to say anything honest.
    public let value: Double?
    public let components: [ComponentScore]
    public let missing: [ComponentID]
    /// Share of the bar's total weight that had data (0-1).
    public let coverage: Double
}

/// What the Today screen shows for a bar.
public struct BarDisplay: Equatable, Sendable {
    public let kind: BarKind
    /// Smoothed value (today weighted most), or nil if nothing recent.
    public let value: Double?
    public let changeFromYesterday: Double?
    public let changeFromWeekAverage: Double?
    /// The unsmoothed reading for today, for the component breakdown.
    public let today: BarReading
}

/// Turns sensor + self-report data into the Physical and Mental bars.
///
/// Timing rules for the bar on day D (chosen so the bar doesn't sag every
/// morning just because the day hasn't happened yet):
/// - Sleep, readiness, HRV, resting HR: the night that ended on the morning of D.
/// - Steps and daytime stress: D-1, the last *complete* day.
/// - Mood: average of D's check-ins, falling back to D-1's.
/// - Practices: days in D-6...D with a gratitude entry or a mental practice
///   (`ActivityKind.isMentalPractice`, or anything logged from the catalog or the coach).
public struct HealthBarsCalculator: Sendable {
    public var weights: BarWeights
    public var stepGoal: Double
    public var practiceTargetDays: Double
    public var baselineWindowDays: Int
    public var vo2WindowDays: Int
    /// Below this share of weight present, the bar is reported as nil.
    public var minimumCoverage: Double
    /// Weights for today, yesterday, the day before.
    public var smoothing: [Double]

    public init(
        weights: BarWeights = .default,
        stepGoal: Double = 8000,
        practiceTargetDays: Double = 5,
        baselineWindowDays: Int = 30,
        vo2WindowDays: Int = 90,
        minimumCoverage: Double = 0.4,
        smoothing: [Double] = [0.6, 0.25, 0.15]
    ) {
        self.weights = weights
        self.stepGoal = stepGoal
        self.practiceTargetDays = practiceTargetDays
        self.baselineWindowDays = baselineWindowDays
        self.vo2WindowDays = vo2WindowDays
        self.minimumCoverage = minimumCoverage
        self.smoothing = smoothing
    }

    // MARK: Raw readings

    public func reading(
        _ kind: BarKind,
        on day: DayKey,
        sensors: [DayKey: SensorDay],
        reports: [DayKey: SelfReportDay]
    ) -> BarReading {
        let nominal = weights.weights(for: kind)
        var scores: [ComponentScore] = []
        var missing: [ComponentID] = []

        // Stable order: largest weight first, then name.
        let ordered = nominal.keys.sorted {
            (nominal[$0]!, $1.rawValue) > (nominal[$1]!, $0.rawValue)
        }
        for id in ordered {
            let weight = nominal[id]!
            guard weight > 0 else { continue }
            if let result = componentScore(id, on: day, sensors: sensors, reports: reports) {
                scores.append(ComponentScore(id: id, score: result.score, weight: weight, detail: result.detail))
            } else {
                missing.append(id)
            }
        }

        let totalWeight = nominal.values.reduce(0, +)
        let presentWeight = scores.reduce(0) { $0 + $1.weight }
        let coverage = totalWeight > 0 ? presentWeight / totalWeight : 0
        let value: Double? = coverage >= minimumCoverage && presentWeight > 0
            ? scores.reduce(0) { $0 + $1.score * $1.weight } / presentWeight
            : nil

        return BarReading(kind: kind, day: day, value: value, components: scores, missing: missing, coverage: coverage)
    }

    // MARK: Display (smoothed + deltas)

    public func display(
        _ kind: BarKind,
        on day: DayKey,
        sensors: [DayKey: SensorDay],
        reports: [DayKey: SelfReportDay]
    ) -> BarDisplay {
        // Raw readings for the 7-day comparison window plus the smoothing tail.
        let lookback = 7 + smoothing.count
        var raw: [DayKey: Double] = [:]
        for offset in 0...lookback {
            let d = day.adding(days: -offset)
            if let v = reading(kind, on: d, sensors: sensors, reports: reports).value {
                raw[d] = v
            }
        }

        let today = smoothed(on: day, raw: raw)
        let yesterday = smoothed(on: day.adding(days: -1), raw: raw)
        let week = (1...7).compactMap { smoothed(on: day.adding(days: -$0), raw: raw) }
        let weekAverage = week.isEmpty ? nil : week.reduce(0, +) / Double(week.count)

        return BarDisplay(
            kind: kind,
            value: today,
            changeFromYesterday: today.flatMap { t in yesterday.map { t - $0 } },
            changeFromWeekAverage: today.flatMap { t in weekAverage.map { t - $0 } },
            today: reading(kind, on: day, sensors: sensors, reports: reports)
        )
    }

    /// Smoothed values for a run of days, oldest first, for charts.
    public func series(
        _ kind: BarKind,
        days: [DayKey],
        sensors: [DayKey: SensorDay],
        reports: [DayKey: SelfReportDay]
    ) -> [(day: DayKey, value: Double?)] {
        guard let first = days.min(), let last = days.max() else { return [] }
        var raw: [DayKey: Double] = [:]
        for d in DayKey.range(from: first.adding(days: -(smoothing.count - 1)), through: last) {
            if let v = reading(kind, on: d, sensors: sensors, reports: reports).value {
                raw[d] = v
            }
        }
        return days.map { ($0, smoothed(on: $0, raw: raw)) }
    }

    func smoothed(on day: DayKey, raw: [DayKey: Double]) -> Double? {
        var total = 0.0
        var weightSum = 0.0
        for (offset, weight) in smoothing.enumerated() {
            if let v = raw[day.adding(days: -offset)] {
                total += v * weight
                weightSum += weight
            }
        }
        return weightSum > 0 ? total / weightSum : nil
    }

    // MARK: Components

    func componentScore(
        _ id: ComponentID,
        on day: DayKey,
        sensors: [DayKey: SensorDay],
        reports: [DayKey: SelfReportDay]
    ) -> (score: Double, detail: String)? {
        let yesterday = day.adding(days: -1)

        switch id {
        case .readiness:
            guard let v = sensors[day]?.readinessScore else { return nil }
            return (Baseline.clamp(v), "Oura readiness \(Int(v.rounded()))")

        case .sleep, .mentalSleep:
            guard let v = sensors[day]?.sleepScore else { return nil }
            var detail = "Oura sleep score \(Int(v.rounded()))"
            if let hours = sensors[day]?.sleepHours {
                detail += String(format: ", %.1f h", hours)
            }
            return (Baseline.clamp(v), detail)

        case .hrv:
            return baselineScore(on: day, window: baselineWindowDays, sensors: sensors, higherIsBetter: true,
                                 unit: "ms") { $0.averageHRV }

        case .restingHeartRate:
            return baselineScore(on: day, window: baselineWindowDays, sensors: sensors, higherIsBetter: false,
                                 unit: "bpm") { $0.lowestHeartRate }

        case .activity:
            guard let steps = sensors[yesterday]?.steps else { return nil }
            let score = Baseline.clamp(100 * steps / stepGoal)
            return (score, "\(Int(steps).formatted()) steps yesterday (goal \(Int(stepGoal).formatted()))")

        case .vo2Max:
            // VO2 max is measured sporadically, so use the latest reading in the window.
            let window = DayKey.range(from: day.adding(days: -vo2WindowDays), through: day)
            guard let latestDay = window.last(where: { sensors[$0]?.vo2Max != nil }),
                  let latest = sensors[latestDay]?.vo2Max else { return nil }
            let history = window.filter { $0 < latestDay }.compactMap { sensors[$0]?.vo2Max }
            guard let z = Baseline.robustZ(latest, history: history) else { return nil }
            return (Baseline.score(z: z), String(format: "%.1f", latest) + ", \(trendWord(z)) your recent trend")

        case .mood:
            let (valence, source): (Double?, String) = {
                if let v = reports[day]?.averageValence { return (v, "today") }
                if let v = reports[yesterday]?.averageValence { return (v, "yesterday") }
                return (nil, "")
            }()
            guard let valence else { return nil }
            let score = Baseline.clamp((valence + 1) / 2 * 100)
            return (score, "\(MoodScale.label(forValence: valence)) (\(source))")

        case .stressBalance:
            guard let stress = sensors[yesterday]?.stressHighMinutes,
                  let recovery = sensors[yesterday]?.recoveryHighMinutes else { return nil }
            let balance = recovery - stress
            let history = DayKey.range(from: yesterday.adding(days: -baselineWindowDays), through: yesterday.adding(days: -1))
                .compactMap { d -> Double? in
                    guard let s = sensors[d]?.stressHighMinutes, let r = sensors[d]?.recoveryHighMinutes else { return nil }
                    return r - s
                }
            guard let z = Baseline.robustZ(balance, history: history) else { return nil }
            return (Baseline.score(z: z), "Yesterday: \(Int(stress)) min stressed, \(Int(recovery)) min recovering")

        case .practice:
            let window = DayKey.range(from: day.adding(days: -6), through: day)
            // Only score once we have *any* self-report or meditation data, so a brand
            // new install doesn't start with a zero dragging the Mental bar down.
            let anyData = window.contains { reports[$0] != nil || sensors[$0]?.externalMindfulMinutes != nil }
            guard anyData else { return nil }
            let days = window.filter {
                (reports[$0]?.practiced ?? false) || (sensors[$0]?.externalMindfulMinutes ?? 0) > 0
            }.count
            let score = Baseline.clamp(100 * Double(days) / practiceTargetDays)
            return (score, "\(days) of the last 7 days (target \(Int(practiceTargetDays)))")
        }
    }

    private func baselineScore(
        on day: DayKey,
        window: Int,
        sensors: [DayKey: SensorDay],
        higherIsBetter: Bool,
        unit: String,
        metric: (SensorDay) -> Double?
    ) -> (score: Double, detail: String)? {
        guard let today = sensors[day].flatMap(metric) else { return nil }
        let history = DayKey.range(from: day.adding(days: -window), through: day.adding(days: -1))
            .compactMap { sensors[$0].flatMap(metric) }
        guard let z = Baseline.robustZ(today, history: history) else { return nil }
        let usual = Baseline.median(history)
        return (
            Baseline.score(z: z, higherIsBetter: higherIsBetter),
            "\(Int(today.rounded())) \(unit) vs your usual \(Int(usual.rounded())) \(unit)"
        )
    }

    private func trendWord(_ z: Double) -> String {
        switch z {
        case ..<(-0.5): return "below"
        case 0.5...: return "above"
        default: return "in line with"
        }
    }
}
