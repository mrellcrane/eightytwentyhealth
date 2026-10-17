import Foundation
import EightyTwentyCore

/// Runs and gym sessions from every source, ready for `RunningPlan` and `TrainingAdvisor`.
/// Walks are kept apart: they never count toward the plan.
struct TrainingInput {
    let runs: [RunEntry]
    /// Walks you logged or recorded here, with their distance (0 if none).
    let walks: [RunEntry]
    let strengthDays: [DayKey]

    init(healthRuns: [HealthKitRun], activities: [ActivityLog]) {
        let inHealth = Set(healthRuns.map(\.uuid))
        var runs = healthRuns.map { (span: Overlap.Span(start: $0.start, end: $0.end), meters: $0.meters) }
        for log in activities where log.deletedAt == nil && log.activityKind == .run {
            // The recorder also saves to Health; count those once.
            if let uuid = log.healthKitUUID, inHealth.contains(uuid) { continue }
            guard let meters = log.distanceMeters, meters > 0 else { continue }
            runs.append((span: Overlap.Span(start: log.timestamp, minutes: log.minutes), meters: meters))
        }
        // The same run saved by two apps (this one and a watch, or Oura through Apple
        // Health) overlaps in time: it counts once, at the longer distance.
        self.runs = Overlap.distinct(runs, span: { $0.span }, size: { $0.meters })
            .map { RunEntry(day: DayKey(date: $0.span.start), miles: $0.meters / RunningPlan.metersPerMile) }
        self.walks = activities
            .filter { $0.deletedAt == nil && $0.activityKind == .walk }
            .map { RunEntry(day: DayKey(date: $0.timestamp), miles: ($0.distanceMeters ?? 0) / RunningPlan.metersPerMile) }
        self.strengthDays = activities
            .filter { $0.deletedAt == nil && $0.activityKind == .workout }
            .map { DayKey(date: $0.timestamp) }
    }
}

enum RunPlanSettings {
    static func plan(start: String, miles: Double) -> RunningPlan? {
        guard let day = DayKey(start), miles > 0 else { return nil }
        return RunningPlan(start: day, startMiles: miles)
    }
}

/// Check-ins live in UserDefaults as JSON: small, and nothing else needs them.
enum RunCheckIns {
    static func decode(_ raw: String) -> [DayKey: RunSignal] {
        guard let data = raw.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: RunSignal].self, from: data) else { return [:] }
        var result: [DayKey: RunSignal] = [:]
        for (key, signal) in map {
            if let day = DayKey(key) { result[day] = signal }
        }
        return result
    }

    static func encode(_ checkIns: [DayKey: RunSignal]) -> String {
        var map: [String: RunSignal] = [:]
        for (day, signal) in checkIns { map[day.rawValue] = signal }
        guard let data = try? JSONEncoder().encode(map) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
