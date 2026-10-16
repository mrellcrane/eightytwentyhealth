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
    /// Mental bar components this is meant to help, for ranking.
    public let targets: Set<ComponentID>
    public let logsAs: ActivityKind
    public let action: Action
    /// Local hours when it makes sense. Nil means any time.
    public let hours: ClosedRange<Int>?

    public init(id: String, title: String, minutes: Double, timing: Timing, summary: String, steps: [String],
                evidence: Evidence, targets: Set<ComponentID>, logsAs: ActivityKind, action: Action = .log,
                hours: ClosedRange<Int>? = nil) {
        self.id = id
        self.title = title
        self.minutes = minutes
        self.timing = timing
        self.summary = summary
        self.steps = steps
        self.evidence = evidence
        self.targets = targets
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

    public init(interventionID: String?, title: String, timestamp: Date, intensityBefore: Int?, intensityAfter: Int?) {
        self.interventionID = interventionID
        self.title = title
        self.timestamp = timestamp
        self.intensityBefore = intensityBefore
        self.intensityAfter = intensityAfter
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
    /// Why it's near the top today, if there's a specific reason.
    public let reason: String?
    public let score: Double
}

/// Orders the catalog by expected gain per minute, the 80/20 ratio. Things aimed
/// at the weakest part of today's Mental bar get a boost; things that don't fit
/// the time of day sink.
public enum InterventionRanker {
    public static let targetBoost = 1.5
    public static let offHoursPenalty = 0.3

    public static func rank(
        _ catalog: [Intervention] = Intervention.catalog,
        mental: BarReading?,
        personal: [String: PersonalEffect],
        hour: Int
    ) -> [RankedIntervention] {
        let weakest = mental?.components
            .filter { $0.score < MorningBrief.draggingBelow }
            .min { $0.score < $1.score }

        return catalog.map { item in
            let mine = personal[item.id]
            let estimate = EffectEstimate.blended(researchPercent: Double(item.researchPercent), personal: mine)
            var relevance = 1.0
            var reason: String?
            if let weakest, item.targets.contains(weakest.id) {
                relevance *= targetBoost
                reason = "Aimed at your \(weakest.id.title.lowercased()), the lowest part of your Mental bar today"
            }
            if let hours = item.hours, !hours.contains(hour) {
                relevance *= offHoursPenalty
                reason = nil
            }
            return RankedIntervention(
                intervention: item,
                estimatePercent: estimate,
                personal: mine,
                reason: reason,
                score: estimate * relevance / max(item.minutes, 1)
            )
        }
        .sorted { ($0.score, $1.intervention.title) > ($1.score, $0.intervention.title) }
    }
}
