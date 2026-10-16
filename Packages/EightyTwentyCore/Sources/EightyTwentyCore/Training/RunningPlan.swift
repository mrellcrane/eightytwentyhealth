import Foundation

/// One run, from Apple Health (Apple Fitness, this app's recorder) or added by hand
/// (a Strava screenshot, treadmill miles).
public struct RunEntry: Equatable, Sendable {
    public var day: DayKey
    public var miles: Double

    public init(day: DayKey, miles: Double) {
        self.day = day
        self.miles = miles
    }
}

/// How a run sat with you by the next morning. It decides next week's miles.
public enum RunSignal: String, CaseIterable, Codable, Comparable, Sendable {
    case green
    case yellow
    case red

    public var title: String { rawValue.capitalized }

    public var meaning: String {
        switch self {
        case .green: return "Nothing during, or mild tightness gone by evening. Normal next morning."
        case .yellow: return "Tightness into the next morning, longer morning stiffness, or a new ache in shins, knees or feet."
        case .red: return "Next-day pain that changes your plans, pain that wakes you, heel or Achilles pain, or a swollen joint."
        }
    }

    public var action: String {
        switch self {
        case .green: return "Follow the plan."
        case .yellow: return "Next week repeats this week's miles instead of adding."
        case .red: return "No more running this week; next week drops back to your last green week. Heel, Achilles or joint pain: check in with your doctor."
        }
    }

    private var severity: Int {
        switch self {
        case .green: return 0
        case .yellow: return 1
        case .red: return 2
        }
    }

    public static func < (lhs: RunSignal, rhs: RunSignal) -> Bool { lhs.severity < rhs.severity }
}

/// Monday-to-Sunday weeks over `DayKey`s.
public enum TrainingCalendar {
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    public static func monday(of day: DayKey) -> DayKey {
        // .weekday is 1 for Sunday through 7 for Saturday.
        let weekday = utc.component(.weekday, from: day.startDate(in: utc))
        return day.adding(days: -((weekday + 5) % 7))
    }

    /// 1 for Monday through 7 for Sunday.
    public static func weekdayNumber(_ day: DayKey) -> Int {
        monday(of: day).days(until: day) + 1
    }

    public static func isWeekend(_ day: DayKey) -> Bool { weekdayNumber(day) >= 6 }

    public static func shortName(_ day: DayKey) -> String {
        ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"][weekdayNumber(day) - 1]
    }

    /// "Mon Oct 19".
    public static func label(_ day: DayKey) -> String {
        "\(shortName(day)) \(monthDay(day))"
    }

    /// "Oct 19".
    public static func monthDay(_ day: DayKey) -> String {
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return "\(months[day.month - 1]) \(day.day)"
    }
}

/// A weekly mileage plan that grows slowly and listens to how runs felt.
///
/// Rules: three easy runs a week, never three days in a row. About +1 mile a week,
/// every 4th week cut back about 25%. A yellow week (or one well short of its
/// target) repeats; a red week drops back to the last green week's miles. The long
/// run grows half a mile at a time and stays under 40% of the week.
public struct RunningPlan: Equatable, Sendable {
    public static let metersPerMile = 1609.344
    public static let runsPerWeek = 3
    public static let maxDaysInARow = 2
    public static let weeklyStep = 1.0
    public static let cutbackEvery = 4
    public static let cutbackFactor = 0.75
    public static let longRunShare = 0.4
    public static let longRunStep = 0.5
    public static let shortestRun = 2.0
    /// A finished week under this share of its target counts as missed, and repeats.
    public static let missedShare = 0.75

    /// Monday of the plan's first week, and that week's miles.
    public let start: DayKey
    public let startMiles: Double

    public init(start: DayKey, startMiles: Double) {
        self.start = TrainingCalendar.monday(of: start)
        self.startMiles = startMiles
    }

    public struct Week: Identifiable, Sendable {
        public enum Kind: String, Sendable {
            case beforePlan, first, build, cutback, repeated, droppedBack

            public var note: String {
                switch self {
                case .beforePlan: return "Before your plan starts"
                case .first: return "First week: hold steady"
                case .build: return "Build week: about +1 mi"
                case .cutback: return "Cutback week: about 25% less"
                case .repeated: return "Repeat week, after a yellow or short week"
                case .droppedBack: return "Dropped back to your last green week"
                }
            }
        }

        public let start: DayKey
        public let target: Double
        public let kind: Kind
        public let actual: Double
        public let runs: Int
        /// The worst check-in that week.
        public let signal: RunSignal?

        public var id: String { start.rawValue }
    }

    public struct PlannedRun: Equatable, Sendable {
        public let day: DayKey
        public let miles: Double
        public let isLong: Bool
    }

    public struct WeekOutlook: Identifiable, Sendable {
        public let week: Week
        /// A sample split: the shorter runs first, the long run last.
        public let split: [Double]
        public var id: String { week.id }
    }

    public struct Guidance: Sendable {
        public let week: Week
        public let nextWeek: Week?
        public let planned: [PlannedRun]
        public let headline: String
    }

    /// The plan from its first week through `weeksAhead` weeks past today's. Finished
    /// weeks carry what you ran; weeks still to come assume they go green.
    public func weeks(runs: [RunEntry], checkIns: [DayKey: RunSignal], today: DayKey, weeksAhead: Int = 3) -> [Week] {
        let current = TrainingCalendar.monday(of: today)
        let end = current.adding(days: 7 * weeksAhead)
        var weeks: [Week] = []
        var target = startMiles
        var build = startMiles
        var position = 1
        var lastGreen: Double?
        var kind = Week.Kind.first
        var weekStart = start

        while weekStart <= end {
            let summary = Self.summary(runs: runs, checkIns: checkIns, week: weekStart)
            weeks.append(Week(start: weekStart, target: target, kind: kind, actual: summary.miles, runs: summary.count, signal: summary.signal))

            let signal = weekStart <= current ? (summary.signal ?? .green) : .green
            let missed = weekStart < current && summary.miles < target * Self.missedShare
            if signal == .red {
                target = lastGreen ?? (target * Self.cutbackFactor).rounded()
                build = target
                position = 1
                kind = .droppedBack
            } else if signal == .yellow || missed {
                kind = .repeated
            } else {
                lastGreen = target
                position = position % Self.cutbackEvery + 1
                if position == Self.cutbackEvery {
                    target = (build * Self.cutbackFactor).rounded()
                    kind = .cutback
                } else {
                    build += Self.weeklyStep
                    target = build
                    kind = .build
                }
            }
            weekStart = weekStart.adding(days: 7)
        }
        return weeks
    }

    /// The weeks after this one, assuming each goes green, with a sample split for each.
    /// The long run grows from your actual recent long runs.
    public func outlook(runs: [RunEntry], checkIns: [DayKey: RunSignal], today: DayKey, weeks count: Int = 8) -> [WeekOutlook] {
        let current = TrainingCalendar.monday(of: today)
        let future = weeks(runs: runs, checkIns: checkIns, today: today, weeksAhead: count).filter { $0.start > current }
        var longs: [Double] = [2, 1, 0].map { offset in
            let weekStart = current.adding(days: -7 * offset)
            let weekEnd = weekStart.adding(days: 6)
            return runs.filter { $0.day >= weekStart && $0.day <= weekEnd }.map(\.miles).max() ?? 0
        }
        return future.map { week in
            let recent = longs.suffix(3).max() ?? 0
            let cap = Self.longRunCap(target: week.target, recentLongest: recent > 0 ? recent : nil)
            let split = Self.distances(remaining: week.target, count: Self.runsPerWeek, longCap: cap)
            longs.append(split.last ?? 0)
            return WeekOutlook(week: week, split: split)
        }
    }

    /// This week's target, what's left, and when to run it.
    public func guidance(runs: [RunEntry], checkIns: [DayKey: RunSignal], today: DayKey) -> Guidance {
        let monday = TrainingCalendar.monday(of: today)
        let all = weeks(runs: runs, checkIns: checkIns, today: today, weeksAhead: 1)
        if monday < start {
            // Starting next week means resting until then, whatever is left of this week's miles.
            let summary = Self.summary(runs: runs, checkIns: checkIns, week: monday)
            let resting = Week(start: monday, target: startMiles, kind: .beforePlan, actual: summary.miles, runs: summary.count, signal: summary.signal)
            return Guidance(week: resting, nextWeek: all.first, planned: [],
                            headline: "No running until your plan starts \(TrainingCalendar.label(start)). Swim, bike, hike, or Orangetheory with power-walking on the tread.")
        }
        let index = all.firstIndex { $0.start == monday } ?? 0
        let week = all[index]
        let nextWeek = index + 1 < all.count ? all[index + 1] : nil

        let remaining = max(0, week.target - week.actual)
        if week.signal == .red {
            return Guidance(week: week, nextWeek: nextWeek, planned: [],
                            headline: "Red this week: no more running. Swim, bike or walk instead.")
        }
        if week.runs >= Self.runsPerWeek || remaining < 1 {
            return Guidance(week: week, nextWeek: nextWeek, planned: [],
                            headline: "This week's running is done. Swim, bike, hike, lift, or Orangetheory with power-walking on the tread.")
        }

        let runDays = Set(runs.map(\.day))
        let wanted = min(Self.runsPerWeek - week.runs, max(1, Int(remaining / Self.shortestRun)))
        let days = Self.pickDays(count: wanted, today: today, runDays: runDays)
        if days.isEmpty {
            return Guidance(week: week, nextWeek: nextWeek, planned: [],
                            headline: "No room for another run this week without three days in a row.")
        }
        let recent = runs.filter { $0.day >= monday.adding(days: -21) && $0.day <= today }.map(\.miles).max()
        let longCap = Self.longRunCap(target: week.target, recentLongest: recent)
        let miles = Self.distances(remaining: remaining, count: days.count, longCap: longCap)
        // The last run is the long one if nothing this week has been longer.
        let longestSoFar = runs.filter { $0.day >= monday && $0.day <= today }.map(\.miles).max() ?? 0
        var planned: [PlannedRun] = []
        for (i, day) in days.enumerated() {
            let isLast = i == days.count - 1
            planned.append(PlannedRun(day: day, miles: miles[i], isLong: isLast && miles[i] >= longestSoFar))
        }
        return Guidance(week: week, nextWeek: nextWeek, planned: planned,
                        headline: "\(Self.format(week.actual)) of \(Self.format(week.target)) mi done. Easy pace, every run.")
    }

    /// "11" or "10.7".
    public static func format(_ miles: Double) -> String {
        let tenths = (miles * 10).rounded() / 10
        return tenths == tenths.rounded() ? String(Int(tenths)) : String(format: "%.1f", tenths)
    }

    // MARK: Internals

    static func summary(runs: [RunEntry], checkIns: [DayKey: RunSignal], week: DayKey) -> (miles: Double, count: Int, signal: RunSignal?) {
        let end = week.adding(days: 6)
        let inWeek = runs.filter { $0.day >= week && $0.day <= end }
        let signal = DayKey.range(from: week, through: end).compactMap { checkIns[$0] }.max()
        let miles = inWeek.reduce(0.0) { $0 + $1.miles }
        return (miles, inWeek.count, signal)
    }

    /// The long run may grow half a mile past your recent longest, and stays under 40% of the week.
    static func longRunCap(target: Double, recentLongest: Double?) -> Double {
        let share = floorHalf(target * longRunShare)
        guard let recentLongest, recentLongest > 0 else { return share }
        return min(share, floorHalf(recentLongest) + longRunStep)
    }

    /// Splits what's left of the week: the long run last, the others no longer than it.
    static func distances(remaining: Double, count: Int, longCap: Double) -> [Double] {
        guard count > 0 else { return [] }
        if count == 1 { return [min(floorHalf(remaining), longCap)] }
        let others = count - 1
        let long = max(shortestRun, min(longCap, floorHalf(remaining - Double(others) * shortestRun)))
        let rest = max(0, remaining - long)
        var result: [Double] = []
        for i in 0..<others {
            let share = i == others - 1 ? roundHalf(rest - result.reduce(0, +)) : floorHalf(rest / Double(others))
            result.append(min(long, max(0, share)))
        }
        return result + [long]
    }

    /// Spreads `count` runs over the rest of the week: as far apart as possible, never
    /// three days in a row, the last (long) one on a weekend if it fits.
    static func pickDays(count: Int, today: DayKey, runDays: Set<DayKey>) -> [DayKey] {
        let monday = TrainingCalendar.monday(of: today)
        let candidates = DayKey.range(from: today, through: monday.adding(days: 6)).filter { !runDays.contains($0) }
        let nearby = runDays.filter { $0 >= monday.adding(days: -3) && $0 <= monday.adding(days: 6) }
        var size = min(count, candidates.count)
        while size > 0 {
            var best: (score: Double, days: [DayKey])?
            for combo in combinations(candidates, size) {
                let all = nearby.union(combo)
                guard !hasStreak(all) else { continue }
                let score = spreadScore(all.sorted(), last: combo.last!, today: today, combo: combo)
                if best == nil || score > best!.score { best = (score, combo) }
            }
            if let best { return best.days }
            size -= 1
        }
        return []
    }

    private static func spreadScore(_ days: [DayKey], last: DayKey, today: DayKey, combo: [DayKey]) -> Double {
        var minGap = 7
        for (a, b) in zip(days, days.dropFirst()) { minGap = min(minGap, a.days(until: b)) }
        let weekendBonus: Double = TrainingCalendar.isWeekend(last) ? 5 : 0
        let lateness = Double(combo.reduce(0) { $0 + today.days(until: $1) })
        return Double(minGap) * 10 + weekendBonus - lateness * 0.01
    }

    private static func hasStreak(_ days: Set<DayKey>) -> Bool {
        days.contains { days.contains($0.adding(days: 1)) && days.contains($0.adding(days: 2)) }
    }

    private static func combinations(_ items: [DayKey], _ size: Int) -> [[DayKey]] {
        guard size > 0 else { return [[]] }
        guard items.count >= size else { return [] }
        var result: [[DayKey]] = []
        for (i, item) in items.enumerated() {
            for rest in combinations(Array(items[(i + 1)...]), size - 1) {
                result.append([item] + rest)
            }
        }
        return result
    }

    static func floorHalf(_ miles: Double) -> Double { (miles * 2).rounded(.down) / 2 }
    static func roundHalf(_ miles: Double) -> Double { (miles * 2).rounded() / 2 }
}
