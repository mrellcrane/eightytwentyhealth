import Foundation

/// Places in the app the coach can link to. Tapping one in a reply opens it.
public enum CoachLink: String, CaseIterable, Identifiable, Sendable {
    case running
    case addRun = "add-run"
    case recordRun = "record-run"
    case meditate
    case mood
    case gratitude
    case log
    case insights

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .running: return "Running"
        case .addRun: return "Add a run"
        case .recordRun: return "Record a run"
        case .meditate: return "Meditate"
        case .mood: return "Log mood"
        case .gratitude: return "Gratitude"
        case .log: return "Log an activity"
        case .insights: return "Insights"
        }
    }

    public var url: URL { URL(string: "eightytwenty://app/\(rawValue)")! }

    public init?(url: URL) {
        guard url.scheme == "eightytwenty", url.host == "app" else { return nil }
        self.init(rawValue: url.lastPathComponent)
    }
}

/// The coach's system prompt: how to answer, then a snapshot of what the app knows.
/// Built once per conversation, so the prompt stays identical turn to turn (the
/// conversation stays append-only and the prompt cache keeps working).
public enum CoachBriefing {
    public static let model = "claude-haiku-5-5"

    public struct Snapshot: Sendable {
        public var now: Date
        public var calendar: Calendar
        public var bars: [BarDisplay]
        public var sensors: [DayKey: SensorDay]
        public var reports: [DayKey: SelfReportDay]
        /// Activity kinds logged per day, from any source.
        public var activities: [DayKey: Set<ActivityKind>]
        public var runs: [RunEntry]
        /// Walks you logged, with their distance (0 if none). Kept apart from runs.
        public var walks: [RunEntry]
        public var checkIns: [DayKey: RunSignal]
        public var plan: RunningPlan?
        public var strengthDays: [DayKey]
        public var patterns: [PersonalPattern]
        /// What you wrote in Settings for the coach (history, goals). Never logged.
        public var notes: String

        public init(now: Date, calendar: Calendar = .current, bars: [BarDisplay], sensors: [DayKey: SensorDay],
                    reports: [DayKey: SelfReportDay], activities: [DayKey: Set<ActivityKind>], runs: [RunEntry],
                    walks: [RunEntry] = [], checkIns: [DayKey: RunSignal], plan: RunningPlan?, strengthDays: [DayKey],
                    patterns: [PersonalPattern], notes: String) {
            self.now = now
            self.calendar = calendar
            self.bars = bars
            self.sensors = sensors
            self.reports = reports
            self.activities = activities
            self.runs = runs
            self.walks = walks
            self.checkIns = checkIns
            self.plan = plan
            self.strengthDays = strengthDays
            self.patterns = patterns
            self.notes = notes
        }
    }

    public static var instructions: String {
        let links = CoachLink.allCases.map { "[\($0.title)](\($0.url.absoluteString))" }.joined(separator: ", ")
        return """
        You are the coach inside 80/20 Health, a personal iPhone app with one user. Help them find the smallest \
        actions that move their health the most, using their own data below and published research.

        How to answer:
        - Lead with the recommendation, then the why in a sentence or two. Keep it short: a few sentences, or a \
        few lines starting with "- ". No headings or tables; this is a phone screen.
        - Ground advice in research. Name the study or review (first author and year) when you lean on one, and say \
        plainly when evidence is thin or mixed. Never invent a citation.
        - Use their numbers. Compare today with their own recent days, not population norms.
        - Respect the running plan and its rules. Don't suggest more running than this week's plan leaves, and \
        treat new heel, Achilles or joint pain as a reason to back off and check with a doctor.
        - You are not their doctor. For anything medical, suggest what to ask their clinician.
        - Patterns from Insights are correlations in their own data, not proof of cause; say so when you use one.
        - When the app can do the thing you suggest, link to it with one of these exact links: \(links).
        """
    }

    public static func systemPrompt(_ snapshot: Snapshot) -> String {
        "\(instructions)\n\n\(data(snapshot))"
    }

    // MARK: The data

    static func data(_ s: Snapshot) -> String {
        let today = DayKey(date: s.now, calendar: s.calendar)
        var out: [String] = []

        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.timeZone = s.calendar.timeZone
        clock.dateFormat = "EEEE, MMMM d, yyyy, h:mm a"
        out.append("## Now\n\(clock.string(from: s.now)).")

        out.append("## Health bars (0 to 100, 75 is their normal)")
        for bar in s.bars {
            guard let value = bar.value else {
                out.append("\(bar.kind.title): not enough data.")
                continue
            }
            var line = "\(bar.kind.title): \(Int(value.rounded()))"
            if let change = bar.changeFromYesterday { line += ", \(signed(change)) vs yesterday" }
            if let change = bar.changeFromWeekAverage { line += ", \(signed(change)) vs the week's average" }
            out.append("\(line).")
        }

        out.append("## Last 14 days, newest first\nSleep numbers are for the night that ended that morning.")
        for day in DayKey.range(from: today.adding(days: -13), through: today).reversed() {
            out.append("\(day.rawValue): \(dayLine(day, s))")
        }

        out.append(contentsOf: running(s, today: today))

        let gym = s.strengthDays.filter { $0 > today.adding(days: -28) && $0 <= today }.sorted(by: >)
        let gymLine = gym.isEmpty ? "None logged." : gym.map(\.rawValue).joined(separator: ", ")
        out.append("## Gym (strength sessions, last 28 days)\n\(gymLine)")

        let context = TrainingContext(today: today, runs: s.runs, checkIns: s.checkIns, plan: s.plan,
                                      strengthDays: s.strengthDays, readiness: s.sensors[today]?.readinessScore)
        out.append("## The app's training suggestion for today, by goal")
        for goal in TrainingGoal.allCases {
            let advice = TrainingAdvisor.advise(goal, context)
            out.append("\(goal.title): \(advice.title). \(advice.detail)")
        }

        out.append("## Personal patterns (Spearman r over the last 120 days; adjusted p corrects for testing every pair)")
        if s.patterns.isEmpty {
            out.append("Not enough data yet: a pair needs 21 days.")
        } else {
            let holding = s.patterns.filter(\.holdsUp)
            out.append(holding.isEmpty ? "None hold up after correction yet." : "Hold up after correction:")
            out.append(contentsOf: holding.map(patternLine))
            out.append("Strongest of the rest (could be luck):")
            out.append(contentsOf: s.patterns.filter { !$0.holdsUp }.prefix(5).map(patternLine))
        }

        let notes = s.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            out.append("## In their own words (history, goals, anything they want you to know)\n\(notes)")
        }
        return out.joined(separator: "\n")
    }

    private static func dayLine(_ day: DayKey, _ s: Snapshot) -> String {
        var parts: [String] = []
        if let sensor = s.sensors[day] {
            if let v = sensor.readinessScore { parts.append("readiness \(Int(v))") }
            if let v = sensor.sleepScore { parts.append("sleep score \(Int(v))") }
            if let v = sensor.sleepHours { parts.append(String(format: "slept %.1f h", v)) }
            if let v = sensor.bedtimeHoursFromMidnight(calendar: s.calendar) { parts.append("bedtime \(clockTime(v))") }
            if let v = sensor.averageHRV { parts.append("HRV \(Int(v.rounded())) ms") }
            if let v = sensor.lowestHeartRate { parts.append("lowest HR \(Int(v.rounded()))") }
            if let v = sensor.steps { parts.append("steps \(Int(v.rounded()))") }
            if let v = sensor.stressHighMinutes { parts.append("stressed \(Int(v.rounded())) min") }
        }
        if let report = s.reports[day], let mood = report.averageValence {
            parts.append("mood \(MoodScale.label(forValence: mood).lowercased()) (\(report.moodValences.count) check-ins)")
        }
        let miles = s.runs.filter { $0.day == day }.reduce(0.0) { $0 + $1.miles }
        if miles > 0 { parts.append("ran \(RunningPlan.format(miles)) mi") }
        let logged = (s.activities[day] ?? []).filter { $0 != .run }.map(\.title).sorted()
        if !logged.isEmpty { parts.append("logged \(logged.joined(separator: ", ").lowercased())") }
        return parts.isEmpty ? "no data" : parts.joined(separator: ", ")
    }

    private static func running(_ s: Snapshot, today: DayKey) -> [String] {
        var out = ["## Running (miles)"]
        if let plan = s.plan {
            let guidance = plan.guidance(runs: s.runs, checkIns: s.checkIns, today: today)
            let week = guidance.week
            out.append(Self.runningRules)
            let verb = today < plan.start ? "starts" : "started"
            out.append("Plan \(verb) the week of \(plan.start.rawValue) at \(RunningPlan.format(plan.startMiles)) mi.")
            let done = RunningPlan.format(week.actual)
            let target = RunningPlan.format(week.target)
            out.append("This week (from \(week.start.rawValue)): \(done) of \(target) mi in \(week.runs) of 3 runs. \(week.kind.note). \(guidance.headline)")
            if let signal = week.signal { out.append("Worst check-in this week: \(signal.rawValue).") }
            if !guidance.planned.isEmpty {
                let planned = guidance.planned.map {
                    "\($0.day.rawValue) (\(TrainingCalendar.shortName($0.day))) \(RunningPlan.format($0.miles)) mi\($0.isLong ? " long" : "")"
                }
                out.append("Still planned this week: \(planned.joined(separator: ", ")).")
            }
            let coming = plan.outlook(runs: s.runs, checkIns: s.checkIns, today: today).map { item in
                let split = item.split.map(RunningPlan.format).joined(separator: "/")
                return "week of \(item.week.start.rawValue): \(RunningPlan.format(item.week.target)) mi (\(split))"
            }
            out.append("Coming weeks if each goes green: \(coming.joined(separator: "; ")).")
        } else {
            out.append("No running plan set up yet.")
        }

        let monday = TrainingCalendar.monday(of: today)
        let weeks = (0..<8).reversed().map { offset -> String in
            let start = monday.adding(days: -7 * offset)
            let end = start.adding(days: 6)
            let miles = s.runs.filter { $0.day >= start && $0.day <= end }.reduce(0.0) { $0 + $1.miles }
            return "week of \(start.rawValue): \(RunningPlan.format(miles))"
        }
        out.append("Weekly miles, last 8 weeks: \(weeks.joined(separator: "; ")).")

        let recent = s.runs.filter { $0.day > today.adding(days: -28) && $0.day <= today }.sorted { $0.day > $1.day }
        if recent.isEmpty {
            out.append("No runs in the last 28 days.")
        } else {
            let lines = recent.map { run -> String in
                let signal = s.checkIns[run.day].map { ", felt \($0.rawValue)" } ?? ""
                return "\(run.day.rawValue): \(RunningPlan.format(run.miles)) mi\(signal)"
            }
            out.append("Runs, last 28 days: \(lines.joined(separator: "; ")).")
        }

        let walks = s.walks.filter { $0.day > today.adding(days: -28) && $0.day <= today }.sorted { $0.day > $1.day }
        let walkLines = walks.map { walk in
            walk.miles > 0 ? "\(walk.day.rawValue): \(RunningPlan.format(walk.miles)) mi" : "\(walk.day.rawValue): walk"
        }
        out.append("Walks are kept apart from runs and never count toward the plan or its weekly limits, so walking is fine any day, including once this week's runs are done. Walks, last 28 days: \(walkLines.isEmpty ? "none logged" : walkLines.joined(separator: "; ")).")
        return out
    }

    private static func patternLine(_ p: PersonalPattern) -> String {
        let r = String(format: "%+.2f", p.r)
        let pValue = PersonalPattern.formatP(p.p)
        let adjusted = PersonalPattern.formatP(p.adjustedP)
        var line = "\(p.input.title) -> \(p.outcome.title): r \(r), p \(pValue), adjusted p \(adjusted), \(p.days) days"
        if let averages = p.averages {
            line += " (with: \(p.outcome.format(averages.with)); without: \(p.outcome.format(averages.without)))"
        }
        return "- \(line)"
    }

    private static let runningRules = "Rules: easy conversational pace; 3 runs a week, never 3 days in a row; about +1 mi a week; every 4th week cut back about 25%; a yellow or short week repeats; red drops back to the last green week; the long run grows half a mile at a time and stays under 40% of the week."

    private static func signed(_ value: Double) -> String {
        let rounded = Int(value.rounded())
        return rounded > 0 ? "+\(rounded)" : "\(rounded)"
    }

    /// -1.5 -> "22:30", 0.25 -> "00:15".
    private static func clockTime(_ hoursFromMidnight: Double) -> String {
        let minutes = (Int((hoursFromMidnight * 60).rounded()) + 24 * 60) % (24 * 60)
        return String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}
