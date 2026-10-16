import Foundation

/// One evidence-backed thing to do, with the study behind it. The catalog is
/// in `InterventionCatalog.swift`; every number there was checked against the paper.
public struct Intervention: Identifiable, Equatable, Sendable {
    public enum Timing: String, Sendable {
        /// Measured right after one session.
        case rightAway
        /// Measured after a multi-week program.
        case overWeeks
    }

    /// A: meta-analysis of randomized trials. B: one randomized trial. C: observational.
    public enum Grade: String, Sendable {
        case a = "A", b = "B", c = "C"
    }

    /// Something today's data can show, which this helps with. The ranker
    /// moves an intervention up when your data shows one of its needs.
    public enum Need: String, CaseIterable, Sendable {
        case lowSleep
        case lowEnergy
        case sedentary
        case stressed
        case lowMood
        case fewPractices
    }

    /// What the main button on the detail screen does.
    public enum Action: Equatable, Sendable {
        case log
        case gratitude
        case meditationTimer
    }

    public struct Evidence: Equatable, Sendable {
        /// "Balban et al. 2023, Cell Reports Medicine".
        public let citation: String
        public let doi: String
        public let grade: Grade
        /// Standardized mean difference (Hedges g or Cohen d), positive = better.
        public let effectSize: Double
        /// Reads after a percent: "less anxiety", "more energy".
        public let outcome: String
        /// Plain English: who, what dose, compared with what.
        public let finding: String

        public init(citation: String, doi: String, grade: Grade, effectSize: Double, outcome: String, finding: String) {
            self.citation = citation
            self.doi = doi
            self.grade = grade
            self.effectSize = effectSize
            self.outcome = outcome
            self.finding = finding
        }

        public var url: URL? { URL(string: "https://doi.org/\(doi)") }
    }

    public let id: String
    public let title: String
    public let minutes: Double
    public let timing: Timing
    /// One line under the title.
    public let summary: String
    public let steps: [String]
    public let evidence: Evidence
    /// What it helps with, judged from the study's outcome. Drives "why now".
    public let fits: Set<Need>
    public let logsAs: ActivityKind
    public let action: Action
    /// Local hours when it makes sense. Nil means any time.
    public let hours: ClosedRange<Int>?

    public init(id: String, title: String, minutes: Double, timing: Timing, summary: String, steps: [String],
                evidence: Evidence, fits: Set<Need>, logsAs: ActivityKind, action: Action = .log,
                hours: ClosedRange<Int>? = nil) {
        self.id = id
        self.title = title
        self.minutes = minutes
        self.timing = timing
        self.summary = summary
        self.steps = steps
        self.evidence = evidence
        self.fits = fits
        self.logsAs = logsAs
        self.action = action
        self.hours = hours
    }

    public var researchPercent: Int { EffectEstimate.percent(effectSize: evidence.effectSize) }

    /// "≈12% less anxiety".
    public var headline: String { "≈\(researchPercent)% \(evidence.outcome)" }

    public static func find(_ id: String?) -> Intervention? {
        guard let id else { return nil }
        return catalog.first { $0.id == id }
    }
}

/// Turns study effect sizes into the percentages the app shows.
///
/// Studies report standardized effects: 1.0 means one standard deviation. On the
/// questionnaires these studies use (state anxiety, perceived stress, mood scales)
/// one SD is about a third of the typical score or more, so d × 33 is a
/// conservative "percent change from the average". It's a size, not a promise.
public enum EffectEstimate {
    public static let percentPerEffectSize = 33.0

    public static func percent(effectSize: Double) -> Int {
        Int((effectSize * percentPerEffectSize).rounded())
    }

    /// How many of your own tries the research average counts as.
    public static let researchWeight = 5.0

    /// Research average blended with your own before/after ratings:
    /// `(k × research + n × yours) / (k + n)`. Few tries, mostly research.
    public static func blended(researchPercent: Double, personal: PersonalEffect?) -> Double {
        guard let personal, personal.count > 0 else { return researchPercent }
        let n = Double(personal.count)
        return (researchWeight * researchPercent + n * personal.percentChange) / (researchWeight + n)
    }
}

/// A logged try with before/after ratings, as the core package sees it.
public struct InterventionLog: Equatable, Sendable {
    public var interventionID: String?
    public var title: String
    public var timestamp: Date
    /// 0-10, lower is better.
    public var intensityBefore: Int?
    public var intensityAfter: Int?
    /// What it was logged as, so a walk you logged counts as the walk being done.
    public var kind: ActivityKind?

    public init(interventionID: String?, title: String, timestamp: Date, intensityBefore: Int?, intensityAfter: Int?,
                kind: ActivityKind? = nil) {
        self.interventionID = interventionID
        self.title = title
        self.timestamp = timestamp
        self.intensityBefore = intensityBefore
        self.intensityAfter = intensityAfter
        self.kind = kind
    }

    public var isRated: Bool { intensityBefore != nil && intensityAfter != nil }
}

/// Your own before/after results for one intervention. Uncontrolled (no
/// comparison group), so it reads high next to the research; the blend tempers it.
public struct PersonalEffect: Equatable, Sendable {
    public let count: Int
    public let averageBefore: Double
    public let averageAfter: Double

    public init(count: Int, averageBefore: Double, averageAfter: Double) {
        self.count = count
        self.averageBefore = averageBefore
        self.averageAfter = averageAfter
    }

    /// Percent drop in intensity (positive = it helped).
    public var percentChange: Double {
        averageBefore > 0 ? (averageBefore - averageAfter) / averageBefore * 100 : 0
    }

    /// Per intervention id, from logs that have both ratings.
    public static func compute(_ logs: [InterventionLog]) -> [String: PersonalEffect] {
        var grouped: [String: [InterventionLog]] = [:]
        for log in logs where log.isRated {
            guard let id = log.interventionID else { continue }
            grouped[id, default: []].append(log)
        }
        return grouped.mapValues { logs in
            let n = Double(logs.count)
            return PersonalEffect(
                count: logs.count,
                averageBefore: logs.reduce(0) { $0 + Double($1.intensityBefore!) } / n,
                averageAfter: logs.reduce(0) { $0 + Double($1.intensityAfter!) } / n
            )
        }
    }
}

public struct RankedIntervention: Equatable, Sendable {
    public let intervention: Intervention
    /// Research blended with your own results, in percent.
    public let estimatePercent: Double
    public let personal: PersonalEffect?
    /// Why it's up there today, from your data ("Last night: 5.9 h asleep vs your usual 7.2 h").
    public let reason: String?
    public let doneToday: Bool
    public let score: Double
}

/// Orders the catalog by expected gain per minute (the 80/20 ratio), then lets
/// today's data reorder it: things that fit what your data shows move up, the
/// rest move down, and what you've already done today sinks.
public enum InterventionRanker {
    /// Fits a need your data shows today.
    public static let fitBoost = 3.0
    /// Each further need it fits.
    public static let extraFitBoost = 1.25
    /// Fits none of today's needs, when there are some.
    public static let noFitPenalty = 0.6
    public static let offHoursPenalty = 0.3
    public static let doneTodayPenalty = 0.25
    /// Rest-only steps (the nap) when you say your energy is 4 or 5.
    public static let energizedPenalty = 0.3

    public static func rank(
        _ catalog: [Intervention] = Intervention.catalog,
        signals: RankingSignals,
        personal: [String: PersonalEffect]
    ) -> [RankedIntervention] {
        catalog.map { item in
            let mine = personal[item.id]
            let estimate = EffectEstimate.blended(researchPercent: Double(item.researchPercent), personal: mine)
            let fitting = signals.needs.filter { item.fits.contains($0.need) }
            var relevance: Double
            var reason = fitting.first?.reason
            if fitting.isEmpty {
                relevance = signals.needs.isEmpty ? 1 : noFitPenalty
            } else {
                relevance = fitBoost * pow(extraFitBoost, Double(fitting.count - 1))
            }
            if let hours = item.hours, !hours.contains(signals.hour) {
                relevance *= offHoursPenalty
                reason = nil
            }
            if let energy = signals.energy, energy >= 4, fitting.isEmpty,
               item.fits.isSubset(of: [.lowSleep, .lowEnergy]) {
                relevance *= energizedPenalty
            }
            let done = signals.isDone(item)
            if done {
                relevance *= doneTodayPenalty
                reason = "Done today"
            }
            return RankedIntervention(
                intervention: item,
                estimatePercent: estimate,
                personal: mine,
                reason: reason,
                doneToday: done,
                score: estimate * relevance / max(item.minutes, 1)
            )
        }
        .sorted { ($0.score, $1.intervention.title) > ($1.score, $0.intervention.title) }
    }
}

/// What today's data says, in plain words, for ranking. Built from the same
/// numbers as the bars, compared with your own usual where there's a baseline.
public struct RankingSignals: Equatable, Sendable {
    public struct Signal: Equatable, Sendable {
        public let need: Intervention.Need
        /// The data behind it: "1,240 steps since you woke at 6:02 AM".
        public let reason: String

        public init(_ need: Intervention.Need, _ reason: String) {
            self.need = need
            self.reason = reason
        }
    }

    /// Your energy right now (1-5), a rating from the last 3 hours, or nil.
    public struct EnergyReport: Equatable, Sendable {
        public let level: Int
        public let at: Date

        public init(level: Int, at: Date) {
            self.level = level
            self.at = at
        }
    }

    public var hour: Int
    /// One signal per need, in a fixed order.
    public var needs: [Signal]
    public var doneIDs: Set<String>
    public var doneKinds: Set<ActivityKind>
    /// Current energy, 1-5, when you've rated it in the last 3 hours.
    public var energy: Int?

    public init(hour: Int, needs: [Signal] = [], doneIDs: Set<String> = [], doneKinds: Set<ActivityKind> = [],
                energy: Int? = nil) {
        self.hour = hour
        self.needs = needs
        self.doneIDs = doneIDs
        self.doneKinds = doneKinds
        self.energy = energy
    }

    public func isDone(_ item: Intervention) -> Bool {
        doneIDs.contains(item.id) || doneKinds.contains(item.logsAs)
    }

    // Thresholds, on your own data.
    /// Hours under your usual (median of the last 30 nights) that count as a short night.
    public static let shortNightHours = 0.75
    /// With under 5 nights of history, an absolute floor instead.
    public static let shortNightFloor = 6.5
    public static let lowSleepScore = 70.0
    public static let lowReadiness = 70.0
    /// Steps per hour awake below this, after 2 hours up, is a sedentary day so far.
    public static let sedentaryStepsPerHour = 300.0
    /// How long an energy rating counts as "right now".
    public static let currentEnergyWindow: TimeInterval = 3 * 3600
    public static let stressWords: Set<String> = ["anxious", "stressed", "overwhelmed", "worried", "frustrated", "irritated", "angry"]

    /// - Parameters:
    ///   - sensors: by day; today's entry holds last night's sleep and steps so far.
    ///   - mental: today's Mental bar reading (components scored against your baseline).
    ///   - moods: your check-ins; only today's are used.
    ///   - logs: what you logged; only today's count as done.
    ///   - energyNow: a quick energy rating made outside a check-in.
    public static func build(
        now: Date,
        calendar: Calendar = .current,
        sensors: [DayKey: SensorDay],
        mental: BarReading?,
        moods: [CoachContext.Mood],
        logs: [InterventionLog],
        energyNow: EnergyReport? = nil
    ) -> RankingSignals {
        let today = DayKey(date: now, calendar: calendar)
        let night = sensors[today]
        let todaysMoods = moods
            .filter { DayKey(date: $0.timestamp, calendar: calendar) == today && $0.timestamp <= now }
            .sorted { $0.timestamp < $1.timestamp }
        let latestMood = todaysMoods.last
        // The newest energy rating, from a check-in or the quick picker, if it's recent.
        let energy = (todaysMoods.compactMap { mood in mood.energy.map { EnergyReport(level: $0, at: mood.timestamp) } }
            + [energyNow].compactMap { $0 })
            .filter { $0.at <= now && now.timeIntervalSince($0.at) <= currentEnergyWindow }
            .max { $0.at < $1.at }
        let component = { (id: ComponentID) in mental?.components.first { $0.id == id } }
        let clock = { (date: Date) -> String in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "h:mm a"
            return formatter.string(from: date)
        }
        var needs: [Signal] = []

        // Sleep: last night against your own usual.
        if let hours = night?.sleepHours {
            let history = (1...30).compactMap { sensors[today.adding(days: -$0)]?.sleepHours }
            if history.count >= 5 {
                let usual = Baseline.median(history)
                if hours < usual - shortNightHours {
                    needs.append(Signal(.lowSleep, String(format: "Last night: %.1f h asleep vs your usual %.1f h", hours, usual)))
                }
            } else if hours < shortNightFloor {
                needs.append(Signal(.lowSleep, String(format: "Last night: %.1f h asleep", hours)))
            }
        }
        if !needs.contains(where: { $0.need == .lowSleep }), let score = night?.sleepScore, score < lowSleepScore {
            needs.append(Signal(.lowSleep, "Oura sleep score \(Int(score.rounded())) last night"))
        }

        // Energy: what you said in the last 3 hours, else Oura readiness.
        if let energy {
            if energy.level <= 2 {
                needs.append(Signal(.lowEnergy, "Energy \(energy.level) of 5 at \(clock(energy.at))"))
            }
        } else if let readiness = night?.readinessScore, readiness < lowReadiness {
            needs.append(Signal(.lowEnergy, "Oura readiness \(Int(readiness.rounded()))"))
        }

        // Movement: steps since you woke.
        if let steps = night?.steps, let woke = night?.bedtimeEnd {
            let hoursUp = now.timeIntervalSince(woke) / 3600
            if hoursUp >= 2, steps / hoursUp < sedentaryStepsPerHour {
                needs.append(Signal(.sedentary, "\(grouped(steps)) steps since you woke at \(clock(woke))"))
            }
        }

        // Stress: what you said, else Oura's stress vs your usual balance.
        if let mood = todaysMoods.last(where: { !Set($0.emotions).isDisjoint(with: stressWords) }) {
            let words = mood.emotions.filter { stressWords.contains($0) }.joined(separator: ", ")
            needs.append(Signal(.stressed, "You checked in \(words) at \(clock(mood.timestamp))"))
        } else if let stress = component(.stressBalance), stress.score < MorningBrief.draggingBelow {
            needs.append(Signal(.stressed, stress.detail + " (more stress than your usual)"))
        }

        // Mood: today's check-in, else the Mood component (today or yesterday).
        if let mood = latestMood, mood.valence <= -1.0 / 3 {
            needs.append(Signal(.lowMood, "Your \(clock(mood.timestamp)) check-in: \(MoodScale.label(forValence: mood.valence))"))
        } else if latestMood == nil, let low = component(.mood), low.score < MorningBrief.draggingBelow {
            needs.append(Signal(.lowMood, "Mood: \(low.detail)"))
        }

        if let practice = component(.practice), practice.score < MorningBrief.draggingBelow {
            needs.append(Signal(.fewPractices, "Practices: \(practice.detail)"))
        }

        let done = logs.filter { DayKey(date: $0.timestamp, calendar: calendar) == today && $0.timestamp <= now }
        return RankingSignals(
            hour: calendar.component(.hour, from: now),
            needs: needs,
            doneIDs: Set(done.compactMap(\.interventionID)),
            doneKinds: Set(done.compactMap(\.kind)),
            energy: energy?.level
        )
    }

    static func grouped(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.usesGroupingSeparator = true
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value.rounded())) ?? "\(Int(value))"
    }
}
