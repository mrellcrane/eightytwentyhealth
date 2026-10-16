import Foundation
import SwiftData
import EightyTwentyCore

/// Read/write helpers over the SwiftData stores, so views and services
/// don't each hand-roll fetches and dedupe logic.
@MainActor
struct Repository {
    let context: ModelContext

    // MARK: Sensors (cache)

    // One row per day, so a few hundred rows at most: fetching all and filtering
    // in memory is simpler and safer than string-range predicates.

    func sensorDays(since start: DayKey) -> [DayKey: SensorDay] {
        let snapshots = (try? context.fetch(FetchDescriptor<DailySnapshot>())) ?? []
        var result: [DayKey: SensorDay] = [:]
        for snapshot in snapshots {
            if let sensor = snapshot.sensor, sensor.day >= start { result[sensor.day] = sensor }
        }
        return result
    }

    func upsert(_ sensors: [DayKey: SensorDay]) throws {
        guard !sensors.isEmpty else { return }
        let existing = try context.fetch(FetchDescriptor<DailySnapshot>())
        let byDay = Dictionary(existing.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        for (day, sensor) in sensors {
            if let snapshot = byDay[day.rawValue] {
                snapshot.update(sensor)
            } else {
                context.insert(DailySnapshot(sensor: sensor))
            }
        }
        try context.save()
    }

    var hasAnySensorData: Bool {
        ((try? context.fetchCount(FetchDescriptor<DailySnapshot>())) ?? 0) > 0
    }

    // MARK: Self reports

    func moods(since date: Date) -> [MoodEntry] {
        let descriptor = FetchDescriptor<MoodEntry>(
            predicate: #Predicate { $0.deletedAt == nil && $0.timestamp >= date },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func gratitude(since date: Date) -> [GratitudeEntry] {
        let descriptor = FetchDescriptor<GratitudeEntry>(
            predicate: #Predicate { $0.deletedAt == nil && $0.date >= date },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func activities(since date: Date) -> [ActivityLog] {
        let descriptor = FetchDescriptor<ActivityLog>(
            predicate: #Predicate { $0.deletedAt == nil && $0.timestamp >= date },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func selfReports(since start: DayKey) -> [DayKey: SelfReportDay] {
        let date = start.startDate()
        let moods = moods(since: date).map { SelfReportBuilder.Mood(timestamp: $0.timestamp, valence: $0.valence) }
        let practices = gratitude(since: date).map(\.date)
            + activities(since: date).filter { $0.activityKind?.isMentalPractice == true }.map(\.timestamp)
        return SelfReportBuilder.build(moods: moods, practiceTimestamps: practices)
    }

    // MARK: Dedupe-aware inserts

    /// Ids (including soft-deleted rows, so a deleted import doesn't come back).
    func existingExternalIDs() -> Set<String> {
        let all = (try? context.fetch(FetchDescriptor<ActivityLog>())) ?? []
        return Set(all.compactMap(\.externalID))
    }

    func existingMoodHealthKitUUIDs() -> Set<UUID> {
        let all = (try? context.fetch(FetchDescriptor<MoodEntry>())) ?? []
        return Set(all.compactMap(\.healthKitUUID))
    }

    @discardableResult
    func insertImported(_ activities: [ImportedActivity]) throws -> Int {
        var seen = existingExternalIDs()
        var inserted = 0
        for item in activities where seen.insert(item.externalID).inserted {
            context.insert(ActivityLog(
                timestamp: item.timestamp,
                kind: item.kind,
                minutes: item.minutes,
                source: item.source,
                externalID: item.externalID,
                note: item.note
            ))
            inserted += 1
        }
        if inserted > 0 { try context.save() }
        return inserted
    }

    @discardableResult
    func insertImported(_ moods: [HealthKitMood]) throws -> Int {
        var seen = existingMoodHealthKitUUIDs()
        var inserted = 0
        for mood in moods where seen.insert(mood.uuid).inserted {
            context.insert(MoodEntry(
                timestamp: mood.date,
                valence: mood.valence,
                emotions: mood.labels,
                healthKitUUID: mood.uuid,
                source: "healthKit"
            ))
            inserted += 1
        }
        if inserted > 0 { try context.save() }
        return inserted
    }

    // MARK: Backup

    func backupDocument(appVersion: String?) throws -> BackupDocument {
        let moods = try context.fetch(FetchDescriptor<MoodEntry>(sortBy: [SortDescriptor(\.timestamp)]))
        let gratitude = try context.fetch(FetchDescriptor<GratitudeEntry>(sortBy: [SortDescriptor(\.date)]))
        let activities = try context.fetch(FetchDescriptor<ActivityLog>(sortBy: [SortDescriptor(\.timestamp)]))
        let coach = try context.fetch(FetchDescriptor<CoachLog>(sortBy: [SortDescriptor(\.startedAt)]))
        return BackupDocument(
            exportedAt: .now,
            appVersion: appVersion,
            moods: moods.map {
                MoodRecord(id: $0.id, timestamp: $0.timestamp, valence: $0.valence, energy: $0.energy,
                           emotions: $0.emotions, note: $0.note, healthKitUUID: $0.healthKitUUID,
                           source: $0.source, deletedAt: $0.deletedAt)
            },
            gratitude: gratitude.map {
                GratitudeRecord(id: $0.id, date: $0.date, items: $0.items, note: $0.note, deletedAt: $0.deletedAt)
            },
            activities: activities.map {
                ActivityRecord(id: $0.id, timestamp: $0.timestamp, kind: $0.kind, minutes: $0.minutes,
                               amount: $0.amount, distanceMeters: $0.distanceMeters, source: $0.source,
                               externalID: $0.externalID, note: $0.note, routePolyline: $0.routePolyline,
                               deletedAt: $0.deletedAt, interventionID: $0.interventionID,
                               intensityBefore: $0.intensityBefore, intensityAfter: $0.intensityAfter)
            },
            coach: coach.map(\.record)
        )
    }

    /// Adds whatever in the backup isn't already here. Never overwrites or deletes.
    func restore(_ backup: BackupDocument) throws -> RestoreCounts {
        let moods = try context.fetch(FetchDescriptor<MoodEntry>())
        let gratitude = try context.fetch(FetchDescriptor<GratitudeEntry>())
        let activities = try context.fetch(FetchDescriptor<ActivityLog>())
        let coach = try context.fetch(FetchDescriptor<CoachLog>())
        let existingIDs: Set<UUID> = Set(moods.map(\.id)).union(gratitude.map(\.id)).union(activities.map(\.id)).union(coach.map(\.id))

        let toInsert = BackupMerge.recordsToInsert(
            from: backup,
            existingIDs: existingIDs,
            existingExternalIDs: Set(activities.compactMap(\.externalID)),
            existingHealthKitUUIDs: Set(moods.compactMap(\.healthKitUUID))
        )

        for record in toInsert.moods {
            let entry = MoodEntry(timestamp: record.timestamp, valence: record.valence, energy: record.energy,
                                  emotions: record.emotions, note: record.note,
                                  healthKitUUID: record.healthKitUUID, source: record.source)
            entry.id = record.id
            entry.deletedAt = record.deletedAt
            context.insert(entry)
        }
        for record in toInsert.gratitude {
            let entry = GratitudeEntry(date: record.date, items: record.items, note: record.note)
            entry.id = record.id
            entry.deletedAt = record.deletedAt
            context.insert(entry)
        }
        for record in toInsert.activities {
            let entry = ActivityLog(
                timestamp: record.timestamp,
                kind: ActivityKind(rawValue: record.kind) ?? .meditation,
                minutes: record.minutes,
                amount: record.amount,
                distanceMeters: record.distanceMeters,
                source: ActivitySource(rawValue: record.source) ?? .manual,
                externalID: record.externalID,
                note: record.note,
                routePolyline: record.routePolyline
            )
            // Keep the original strings even if this build doesn't know the kind/source.
            entry.kind = record.kind
            entry.source = record.source
            entry.id = record.id
            entry.deletedAt = record.deletedAt
            entry.interventionID = record.interventionID
            entry.intensityBefore = record.intensityBefore
            entry.intensityAfter = record.intensityAfter
            context.insert(entry)
        }
        for record in toInsert.coach {
            let entry = CoachLog(id: record.id, startedAt: record.startedAt)
            entry.title = record.turns.first?.question ?? ""
            entry.context = record.context
            entry.turnsData = CoachRecord.encodeTurns(record.turns)
            entry.deletedAt = record.deletedAt
            context.insert(entry)
        }
        try context.save()
        return RestoreCounts(moods: toInsert.moods.count, gratitude: toInsert.gratitude.count,
                             activities: toInsert.activities.count, coach: toInsert.coach.count)
    }
}

struct RestoreCounts {
    var moods: Int
    var gratitude: Int
    var activities: Int
    var coach: Int

    var total: Int { moods + gratitude + activities + coach }
}
