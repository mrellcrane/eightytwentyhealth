import Foundation

/// What you want out of today's session.
public enum TrainingGoal: String, CaseIterable, Identifiable, Sendable {
    case cardio
    case strength
    case both

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .cardio: return "Cardio"
        case .strength: return "Strength"
        case .both: return "Both"
        }
    }
}

public struct TrainingAdvice: Equatable, Sendable {
    public let title: String
    public let detail: String

    public init(title: String, detail: String) {
        self.title = title
        self.detail = detail
    }
}

/// Everything the advisor looks at.
public struct TrainingContext: Sendable {
    public var today: DayKey
    public var runs: [RunEntry]
    public var checkIns: [DayKey: RunSignal]
    /// Nil until you set up a running plan.
    public var plan: RunningPlan?
    /// Days with a logged strength session.
    public var strengthDays: [DayKey]
    /// This morning's Oura readiness.
    public var readiness: Double?

    public init(today: DayKey, runs: [RunEntry], checkIns: [DayKey: RunSignal], plan: RunningPlan?,
                strengthDays: [DayKey], readiness: Double?) {
        self.today = today
        self.runs = runs
        self.checkIns = checkIns
        self.plan = plan
        self.strengthDays = strengthDays
        self.readiness = readiness
    }
}

/// Today's session for a goal, from what you've been doing: the running plan's
/// week, how recent runs felt, how often you've lifted lately, and readiness.
public enum TrainingAdvisor {
    public static let lowReadiness = 65.0
    public static let highReadiness = 80.0

    public static func advise(_ goal: TrainingGoal, _ context: TrainingContext) -> TrainingAdvice {
        switch goal {
        case .cardio:
            switch runToday(context) {
            case .run(let miles, let note):
                return TrainingAdvice(title: runTitle(miles), detail: join([runDetail(miles), note]))
            case .alreadyRan:
                return TrainingAdvice(title: "Run done today", detail: "An easy walk is plenty if you want more.")
            case .rest(let advice, _):
                return advice
            }
        case .strength:
            return strength(context).advice
        case .both:
            return both(context)
        }
    }

    enum RunToday {
        /// Nil miles: no plan set up yet.
        case run(miles: Double?, note: String?)
        case alreadyRan
        /// Cardio without running, and a few words on why.
        case rest(TrainingAdvice, why: String)
    }

    static func runToday(_ c: TrainingContext) -> RunToday {
        let runDays = Set(c.runs.map(\.day))
        if runDays.contains(c.today) { return .alreadyRan }
        guard let plan = c.plan else { return .run(miles: nil, note: nil) }
        let guidance = plan.guidance(runs: c.runs, checkIns: c.checkIns, today: c.today)
        if guidance.week.kind == .beforePlan {
            let starts = TrainingCalendar.label(plan.start)
            return .rest(TrainingAdvice(title: "No running until \(starts)",
                                        detail: "Your plan starts then. Swim, bike, hike, or Orangetheory with power-walking on the tread."),
                         why: "plan starts \(starts)")
        }
        if guidance.week.signal == .red {
            return .rest(TrainingAdvice(title: "Cross-train, no running",
                                        detail: "Red this week. Easy bike, swim or walk, 30 to 40 min."), why: "red week")
        }
        if runDays.contains(c.today.adding(days: -1)) && runDays.contains(c.today.adding(days: -2)) {
            return .rest(TrainingAdvice(title: "No run today",
                                        detail: "That would be three days in a row. Easy bike or swim, 30 min."), why: "three days in a row")
        }
        guard let shortest = guidance.planned.map(\.miles).min() else {
            return .rest(TrainingAdvice(title: "Cross-train today", detail: guidance.headline), why: "this week's running is done")
        }
        var miles = guidance.planned.first { $0.day == c.today }?.miles ?? shortest
        var note: String?
        if let readiness = c.readiness, readiness < lowReadiness {
            miles = shortest
            note = "Readiness is \(Int(readiness)), so keep it short, or swap it for a walk."
        }
        return .run(miles: miles, note: note)
    }

    private static func runTitle(_ miles: Double?) -> String {
        miles.map { "Easy run, \(RunningPlan.format($0)) mi" } ?? "Easy run, conversational pace"
    }

    private static func runDetail(_ miles: Double?) -> String {
        miles == nil
            ? "Set up your running plan on the Run screen and this gets a distance."
            : "Conversational pace: grow distance, not speed."
    }

    struct StrengthPlan {
        let advice: TrainingAdvice
        /// False when today should be recovery, not another session.
        let lift: Bool
    }

    static func strength(_ c: TrainingContext) -> StrengthPlan {
        let days = Set(c.strengthDays)
        if days.contains(c.today) {
            return StrengthPlan(advice: TrainingAdvice(title: "Lifted today",
                                                       detail: "That's the session. Mobility or a walk if you want more."), lift: false)
        }
        let weekAgo = c.today.adding(days: -7)
        let lastWeek = days.filter { $0 >= weekAgo && $0 < c.today }.count
        if lastWeek >= 3 {
            return StrengthPlan(advice: TrainingAdvice(title: "Recovery day",
                                                       detail: "Three gym sessions in the last week already. Mobility, core, or rest."), lift: false)
        }
        let daysSince = days.filter { $0 < c.today }.max().map { $0.days(until: c.today) }

        let title: String
        var notes: [String?] = []
        if daysSince == nil || daysSince! >= 14 {
            title = "Gym: ease back in, full body, 30 to 40 min"
            notes.append("2 sets each, stop 3 reps short of failure.")
        } else if let readiness = c.readiness, readiness < lowReadiness {
            title = "Gym: light session, 30 min"
            notes.append("Readiness is \(Int(readiness)): technique, mobility and core.")
        } else if daysSince == 1 {
            title = "Gym: upper body and core, 40 min"
            notes.append("You lifted yesterday, so switch it up.")
        } else {
            title = "Gym: full body, 45 min"
            if let readiness = c.readiness, readiness >= highReadiness {
                notes.append("Readiness is good: last sets 1 to 2 reps short of failure.")
            } else {
                notes.append("Moderate: stop 2 to 3 reps short of failure.")
            }
        }

        if let plan = c.plan {
            let planned = plan.guidance(runs: c.runs, checkIns: c.checkIns, today: c.today).planned
            if planned.contains(where: { $0.day == c.today.adding(days: 1) && $0.isLong }) {
                notes.append("Keep legs light: long run tomorrow.")
            } else if planned.contains(where: { $0.day == c.today }) {
                notes.append("Run first, then lift, and keep legs light.")
            }
        }
        return StrengthPlan(advice: TrainingAdvice(title: title, detail: join(notes)), lift: true)
    }

    static func both(_ c: TrainingContext) -> TrainingAdvice {
        let lifting = strength(c)
        switch runToday(c) {
        case .run(let miles, let note):
            guard lifting.lift else {
                return TrainingAdvice(title: runTitle(miles),
                                      detail: join([runDetail(miles), "Then mobility and core; you've lifted enough lately.", note]))
            }
            let distance = miles.map { " \(RunningPlan.format($0)) mi" } ?? ""
            return TrainingAdvice(title: "Run\(distance), then lift",
                                  detail: join(["Easy run first. Then 30 to 40 min of upper body and core, so your legs stay fresh for running.", note]))
        case .alreadyRan:
            guard lifting.lift else {
                return TrainingAdvice(title: "Run done today", detail: "Mobility or a walk if you want more.")
            }
            return TrainingAdvice(title: lifting.advice.title,
                                  detail: join([lifting.advice.detail, "Your run's done, so that's today's cardio."]))
        case .rest(let advice, let why):
            guard lifting.lift else { return advice }
            return TrainingAdvice(title: "\(lifting.advice.title), plus easy bike",
                                  detail: join([lifting.advice.detail, "Then 15 to 20 min easy on the bike instead of a run (\(why))."]))
        }
    }

    private static func join(_ parts: [String?]) -> String {
        parts.compactMap { $0 }.joined(separator: " ")
    }
}
