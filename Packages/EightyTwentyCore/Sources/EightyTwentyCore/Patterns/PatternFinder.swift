import Foundation

/// Something you did (or that happened) on a day.
public enum PatternInput: Hashable, Sendable {
    case bedtime
    case sleep
    case steps
    case stress
    case mood
    case practice
    case activity(ActivityKind)

    public static var all: [PatternInput] {
        [.bedtime, .sleep, .steps, .stress, .mood, .practice] + ActivityKind.allCases.map { .activity($0) }
    }

    public var title: String {
        switch self {
        case .bedtime: return "Bedtime"
        case .sleep: return "Sleep"
        case .steps: return "Steps"
        case .stress: return "Stressed minutes"
        case .mood: return "Mood"
        case .practice: return "Any mental practice"
        case .activity(let kind): return kind.title
        }
    }

    /// Yes/no inputs get "with vs without" averages next to their correlation.
    public var isYesNo: Bool {
        switch self {
        case .practice, .activity: return true
        default: return false
        }
    }

    /// Outcomes worth testing. Skips pairs that are true by construction (Oura's sleep
    /// score is partly sleep length) or just persistence (today's mood vs tomorrow's).
    public var outcomes: [PatternOutcome] {
        switch self {
        case .sleep: return [.nextDayMood]
        case .mood: return [.hrv, .sleepScore, .readiness]
        default: return PatternOutcome.allCases
        }
    }

    /// Plain-language "more of this" for continuous inputs.
    var moreLabel: String {
        switch self {
        case .bedtime: return "Later bedtime"
        case .sleep: return "More sleep"
        case .steps: return "More steps"
        case .stress: return "More stressed minutes"
        case .mood: return "Better mood"
        case .practice, .activity: return title
        }
    }

    var id: String {
        if case .activity(let kind) = self { return "activity.\(kind.rawValue)" }
        return "\(self)"
    }
}

/// What it might have changed, measured after the input so the order of events is right.
public enum PatternOutcome: String, CaseIterable, Sendable {
    case hrv
    case sleepScore
    case readiness
    case nextDayMood

    public var title: String {
        switch self {
        case .hrv: return "that night's HRV"
        case .sleepScore: return "that night's sleep score"
        case .readiness: return "next morning's readiness"
        case .nextDayMood: return "next day's mood"
        }
    }

    var shortTitle: String {
        switch self {
        case .hrv: return "HRV"
        case .sleepScore: return "sleep score"
        case .readiness: return "readiness"
        case .nextDayMood: return "mood"
        }
    }

    public func format(_ value: Double) -> String {
        switch self {
        case .hrv: return String(format: "%.0f ms", value)
        case .sleepScore, .readiness: return String(format: "%.0f", value)
        case .nextDayMood: return MoodScale.label(forValence: value).lowercased()
        }
    }
}

/// Everything the finder reads, keyed by local day.
public struct PatternData: Sendable {
    public var sensors: [DayKey: SensorDay]
    public var reports: [DayKey: SelfReportDay]
    /// Kinds logged per day, from any source (you, the timer, Oura tags and sessions).
    public var activities: [DayKey: Set<ActivityKind>]
    /// First day anything was logged. Before it, "didn't log a walk" doesn't mean no walk.
    public var loggingStart: DayKey?
    public var calendar: Calendar

    public init(
        sensors: [DayKey: SensorDay],
        reports: [DayKey: SelfReportDay],
        activities: [DayKey: Set<ActivityKind>],
        loggingStart: DayKey?,
        calendar: Calendar = .current
    ) {
        self.sensors = sensors
        self.reports = reports
        self.activities = activities
        self.loggingStart = loggingStart
        self.calendar = calendar
    }

    /// The input on day `day`. Sleep inputs are the night that starts that evening.
    public func value(of input: PatternInput, on day: DayKey) -> Double? {
        let tonight = sensors[day.adding(days: 1)]
        switch input {
        case .bedtime: return tonight?.bedtimeHoursFromMidnight(calendar: calendar)
        case .sleep: return tonight?.sleepHours
        case .steps: return sensors[day]?.steps
        case .stress: return sensors[day]?.stressHighMinutes
        case .mood: return reports[day]?.averageValence
        case .practice:
            guard let loggingStart, day >= loggingStart else { return nil }
            return reports[day]?.practiced == true ? 1 : 0
        case .activity(let kind):
            guard let loggingStart, day >= loggingStart else { return nil }
            return activities[day]?.contains(kind) == true ? 1 : 0
        }
    }

    /// The outcome that follows day `day`: that night's sleep, or the next day.
    public func value(of outcome: PatternOutcome, after day: DayKey) -> Double? {
        let next = day.adding(days: 1)
        switch outcome {
        case .hrv: return sensors[next]?.averageHRV
        case .sleepScore: return sensors[next]?.sleepScore
        case .readiness: return sensors[next]?.readinessScore
        case .nextDayMood: return reports[next]?.averageValence
        }
    }
}

/// One tested pair.
public struct PersonalPattern: Identifiable, Sendable {
    public struct YesNoAverages: Sendable {
        public let with: Double
        public let without: Double
        public let daysWith: Int
    }

    public let input: PatternInput
    public let outcome: PatternOutcome
    /// Days with both values.
    public let days: Int
    /// What those days are worth once day-to-day carryover is allowed for.
    public let effectiveDays: Double
    /// Spearman's rank correlation, -1...1.
    public let r: Double
    /// Two-sided, using `effectiveDays`.
    public let p: Double
    /// Benjamini-Hochberg adjusted across every pair tested together.
    public internal(set) var adjustedP: Double
    public let averages: YesNoAverages?

    public var id: String { "\(input.id)->\(outcome.rawValue)" }

    public var holdsUp: Bool { adjustedP < PatternFinder.falseDiscoveryRate }

    /// "Later bedtime, lower HRV" or "HRV with: 41 ms, without: 48 ms (12 days with)".
    public var summary: String {
        if let averages {
            return "With: \(outcome.format(averages.with)). Without: \(outcome.format(averages.without)). \(averages.daysWith) days with."
        }
        return "\(input.moreLabel), \(r > 0 ? "higher" : "lower") \(outcome.shortTitle)"
    }

    public static func formatP(_ p: Double) -> String {
        p < 0.001 ? "<0.001" : String(format: "%.3f", p)
    }
}

/// Tests every sensible input/outcome pair and corrects for having tested them all.
public enum PatternFinder {
    public static let minimumDays = 21
    public static let minimumDaysPerGroup = 7
    public static let falseDiscoveryRate = 0.05

    /// Every pair with enough data, strongest evidence first.
    public static func find(in data: PatternData, days: [DayKey]) -> [PersonalPattern] {
        var found: [PersonalPattern] = []
        for input in PatternInput.all {
            for outcome in input.outcomes {
                var xs: [Double] = [], ys: [Double] = []
                for day in days {
                    guard let x = data.value(of: input, on: day), let y = data.value(of: outcome, after: day) else { continue }
                    xs.append(x)
                    ys.append(y)
                }
                guard xs.count >= minimumDays else { continue }

                var averages: PersonalPattern.YesNoAverages?
                if input.isYesNo {
                    let with = zip(xs, ys).filter { $0.0 == 1 }.map { $0.1 }
                    let without = zip(xs, ys).filter { $0.0 == 0 }.map { $0.1 }
                    guard with.count >= minimumDaysPerGroup, without.count >= minimumDaysPerGroup else { continue }
                    averages = .init(with: Stats.mean(with), without: Stats.mean(without), daysWith: with.count)
                }

                let rankX = Stats.ranks(xs), rankY = Stats.ranks(ys)
                guard let r = Stats.pearson(rankX, rankY) else { continue }
                let effective = Stats.effectiveSampleSize(
                    n: xs.count,
                    autocorrelationX: Stats.lag1Autocorrelation(rankX),
                    autocorrelationY: Stats.lag1Autocorrelation(rankY)
                )
                found.append(PersonalPattern(
                    input: input, outcome: outcome, days: xs.count, effectiveDays: effective,
                    r: r, p: Stats.correlationPValue(r: r, n: effective), adjustedP: 1, averages: averages
                ))
            }
        }
        let adjusted = Stats.benjaminiHochberg(found.map(\.p))
        for i in found.indices { found[i].adjustedP = adjusted[i] }
        return found.sorted { ($0.p, $0.id) < ($1.p, $1.id) }
    }
}

extension SensorDay {
    /// Bedtime as hours from midnight: 22:30 is -1.5, 01:15 is 1.25.
    public func bedtimeHoursFromMidnight(calendar: Calendar = .current) -> Double? {
        guard let bedtimeStart else { return nil }
        let c = calendar.dateComponents([.hour, .minute, .second], from: bedtimeStart)
        let hours = Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60 + Double(c.second ?? 0) / 3600
        return hours > 12 ? hours - 24 : hours
    }
}
