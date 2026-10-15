import Foundation

/// An activity found in Oura (a tag you added, or a meditation/breathing Moment),
/// ready to be saved as a log entry. `externalID` makes re-imports idempotent.
public struct ImportedActivity: Equatable, Sendable {
    public let externalID: String
    public let kind: ActivityKind
    public let timestamp: Date
    public let minutes: Double?
    public let source: ActivitySource
    public let note: String?
}

public enum OuraActivityMapper {
    /// Sessions (Oura "Moments") that count as a practice.
    public static func activities(from sessions: [OuraSession]) -> [ImportedActivity] {
        sessions.compactMap { session in
            let kind: ActivityKind
            switch session.type {
            case "meditation": kind = .meditation
            case "breathing": kind = .breathwork
            default: return nil
            }
            guard let start = OuraJSON.date(session.startDatetime) else { return nil }
            let end = OuraJSON.date(session.endDatetime)
            return ImportedActivity(
                externalID: "oura-session:\(session.id)",
                kind: kind,
                timestamp: start,
                minutes: end.map { $0.timeIntervalSince(start) / 60 },
                source: .ouraSession,
                note: nil
            )
        }
    }

    public static func activities(from tags: [OuraEnhancedTag], calendar: Calendar = .current) -> [ImportedActivity] {
        tags.compactMap { tag in
            guard let kind = kind(for: tag) else { return nil }
            let start = OuraJSON.date(tag.startTime)
                ?? DayKey(tag.startDay)?.startDate(in: calendar).addingTimeInterval(12 * 3600)
            guard let start else { return nil }
            let end = OuraJSON.date(tag.endTime)
            let minutes = end.map { $0.timeIntervalSince(start) / 60 }.flatMap { $0 > 0 ? $0 : nil }
            return ImportedActivity(
                externalID: "oura-tag:\(tag.id)",
                kind: kind,
                timestamp: start,
                minutes: kind.isTimed ? minutes : nil,
                source: .ouraTag,
                note: [tag.customName, tag.comment].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ").nilIfEmpty
            )
        }
    }

    /// Best-effort mapping from Oura's tag codes (e.g. `tag_generic_alcohol`) and
    /// custom tag names to our activity kinds. Unknown tags are skipped, not guessed.
    static func kind(for tag: OuraEnhancedTag) -> ActivityKind? {
        let text = [tag.tagTypeCode, tag.customName]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
            .replacingOccurrences(of: "_", with: " ")

        func has(_ needles: String...) -> Bool {
            needles.contains { text.contains($0) }
        }

        if has("alcohol", "wine", "beer", "cocktail", "drinks") { return .alcohol }
        if has("caffeine", "coffee", "espresso") {
            // Morning coffee isn't the interesting variable; afternoon coffee is.
            guard let hour = OuraJSON.localHour(tag.startTime), hour >= 14 else { return nil }
            return .lateCaffeine
        }
        if has("late meal", "late dinner", "late snack", "heavy meal") { return .lateMeal }
        if has("meditat", "mindful") { return .meditation }
        if has("breath") { return .breathwork }
        if has("sauna") { return .sauna }
        if has("cold shower", "cold plunge", "cold exposure", "ice bath", "cold water") { return .coldExposure }
        if has("yoga") { return .yoga }
        if has("sunlight", "daylight", "sun exposure", "morning light") { return .sunlight }
        if has("nature", "hike", "hiking", "forest") { return .nature }
        if has("screen", "phone in bed", "blue light") { return .screensBeforeBed }
        if has("social", "friends", "family time", "date night") { return .social }
        return nil
    }
}

extension ActivityKind {
    /// Whether a duration is meaningful for this kind.
    var isTimed: Bool {
        if case .minutes = measure { return true }
        return false
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
