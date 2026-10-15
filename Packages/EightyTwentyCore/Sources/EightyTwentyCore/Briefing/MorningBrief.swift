import Foundation

/// The morning notification: both bars, the number that matters most today,
/// and one action. Rule-based for now; Phase 2's recommender replaces `action`.
public struct MorningBrief: Equatable, Sendable {
    public let title: String
    public let body: String

    /// A component counts as "dragging" below this (75 is your normal).
    public static let draggingBelow = 65.0

    /// Nil when there isn't enough data for an honest Physical bar yet.
    public static func compose(physical: BarDisplay, mental: BarDisplay, bedtime: String) -> MorningBrief? {
        guard let physicalValue = physical.value else { return nil }

        var title = "Physical \(Int(physicalValue.rounded()))"
        if let mentalValue = mental.value {
            title += " · Mental \(Int(mentalValue.rounded()))"
        }

        let components = physical.today.components + mental.today.components
        let weakest = components
            .filter { $0.score < draggingBelow }
            .min { $0.score < $1.score }

        var facts: [String] = []
        if let readiness = physical.today.components.first(where: { $0.id == .readiness }) {
            facts.append("Readiness \(Int(readiness.score.rounded()))")
        }
        if let hrv = physical.today.components.first(where: { $0.id == .hrv }) {
            facts.append("HRV \(hrv.detail)")
        }
        // Make sure the dragging number is named even if it isn't readiness or HRV.
        if let weakest, weakest.id != .readiness, weakest.id != .hrv {
            facts.append("\(weakest.id.title): \(weakest.detail)")
        }

        let body = [facts.joined(separator: " · ").nilIfEmpty, action(for: weakest?.id, bedtime: bedtime)]
            .compactMap { $0 }
            .map { $0.hasSuffix(".") ? $0 : $0 + "." }
            .joined(separator: " ")
        return MorningBrief(title: title, body: body)
    }

    static func action(for weakest: ComponentID?, bedtime: String) -> String {
        switch weakest {
        case .readiness?, .hrv?, .restingHeartRate?:
            return "Recovery day: keep effort easy and be in bed by \(bedtime)."
        case .sleep?, .mentalSleep?:
            return "Rough night: protect a \(bedtime) bedtime and skip caffeine after 2pm."
        case .activity?:
            return "Low movement yesterday: a 20-minute walk outside covers it."
        case .stressBalance?:
            return "Yesterday ran stressful: try 5 minutes of slow breathing before noon."
        case .mood?:
            return "Mood's been low: a short walk outside or a call with a friend is the cheapest lift."
        case .practice?:
            return "No practice lately: 10 minutes of meditation today counts."
        case .vo2Max?:
            return "Cardio fitness is slipping: fit one harder run into this week."
        case nil:
            return "At or above your normal. Good day for a harder workout."
        }
    }
}
