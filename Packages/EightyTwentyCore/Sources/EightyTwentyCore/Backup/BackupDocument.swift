import Foundation

/// Plain-JSON copy of everything you created in the app. Readable without the app,
/// and importable back into it. This is the last line of defense if iCloud sync
/// ever goes sideways, so the format only ever grows (new optional fields), never breaks.
public struct BackupDocument: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var exportedAt: Date
    public var appVersion: String?
    public var moods: [MoodRecord]
    public var gratitude: [GratitudeRecord]
    public var activities: [ActivityRecord]

    public init(
        exportedAt: Date,
        appVersion: String?,
        moods: [MoodRecord],
        gratitude: [GratitudeRecord],
        activities: [ActivityRecord]
    ) {
        self.version = Self.currentVersion
        self.exportedAt = exportedAt
        self.appVersion = appVersion
        self.moods = moods
        self.gratitude = gratitude
        self.activities = activities
    }

    public var isEmpty: Bool { moods.isEmpty && gratitude.isEmpty && activities.isEmpty }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public func encoded() throws -> Data {
        try Self.encoder().encode(self)
    }

    public static func decode(_ data: Data) throws -> BackupDocument {
        try decoder().decode(BackupDocument.self, from: data)
    }
}

public struct MoodRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var valence: Double
    public var energy: Int?
    public var emotions: [String]
    public var note: String?
    public var healthKitUUID: UUID?
    public var source: String
    public var deletedAt: Date?

    public init(id: UUID, timestamp: Date, valence: Double, energy: Int?, emotions: [String], note: String?,
                healthKitUUID: UUID?, source: String, deletedAt: Date?) {
        self.id = id
        self.timestamp = timestamp
        self.valence = valence
        self.energy = energy
        self.emotions = emotions
        self.note = note
        self.healthKitUUID = healthKitUUID
        self.source = source
        self.deletedAt = deletedAt
    }
}

public struct GratitudeRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var date: Date
    public var items: [String]
    public var note: String?
    public var deletedAt: Date?

    public init(id: UUID, date: Date, items: [String], note: String?, deletedAt: Date?) {
        self.id = id
        self.date = date
        self.items = items
        self.note = note
        self.deletedAt = deletedAt
    }
}

public struct ActivityRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var kind: String
    public var minutes: Double?
    public var amount: Double?
    public var distanceMeters: Double?
    public var source: String
    public var externalID: String?
    public var note: String?
    /// Run route as a Google-encoded polyline (see `Polyline`).
    public var routePolyline: String?
    public var deletedAt: Date?
    /// `Intervention.id` when logged from the catalog or a coach step that matched it.
    public var interventionID: String?
    /// 0-10, how strong the problem felt before and after (lower is better).
    public var intensityBefore: Int?
    public var intensityAfter: Int?

    public init(id: UUID, timestamp: Date, kind: String, minutes: Double?, amount: Double?, distanceMeters: Double?,
                source: String, externalID: String?, note: String?, routePolyline: String?, deletedAt: Date?,
                interventionID: String? = nil, intensityBefore: Int? = nil, intensityAfter: Int? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.minutes = minutes
        self.amount = amount
        self.distanceMeters = distanceMeters
        self.source = source
        self.externalID = externalID
        self.note = note
        self.routePolyline = routePolyline
        self.deletedAt = deletedAt
        self.interventionID = interventionID
        self.intensityBefore = intensityBefore
        self.intensityAfter = intensityAfter
    }
}

/// Decides what an import should add. Import never overwrites or deletes:
/// anything already present (same id, or same external source id) is left alone.
public enum BackupMerge {
    public static func recordsToInsert(
        from backup: BackupDocument,
        existingIDs: Set<UUID>,
        existingExternalIDs: Set<String>,
        existingHealthKitUUIDs: Set<UUID> = []
    ) -> BackupDocument {
        var seen = existingIDs
        var seenExternal = existingExternalIDs
        var seenHealthKit = existingHealthKitUUIDs

        let moods = backup.moods.filter { mood in
            guard seen.insert(mood.id).inserted else { return false }
            if let hk = mood.healthKitUUID {
                return seenHealthKit.insert(hk).inserted
            }
            return true
        }
        let gratitude = backup.gratitude.filter { seen.insert($0.id).inserted }
        let activities = backup.activities.filter { activity in
            guard seen.insert(activity.id).inserted else { return false }
            if let external = activity.externalID {
                return seenExternal.insert(external).inserted
            }
            return true
        }

        return BackupDocument(
            exportedAt: backup.exportedAt,
            appVersion: backup.appVersion,
            moods: moods,
            gratitude: gratitude,
            activities: activities
        )
    }
}

/// Naming and pruning for automatic backup files.
public enum BackupFiles {
    public static let prefix = "8020-backup-"

    public static func fileName(for date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withTimeZone]
        let stamp = formatter.string(from: date).replacingOccurrences(of: ":", with: "")
        return "\(prefix)\(stamp).json"
    }

    /// Given existing backup file names, which to delete to keep the newest `keep`.
    /// Files that don't look like ours are never touched.
    public static func filesToPrune(_ names: [String], keep: Int) -> [String] {
        let ours = names.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".json") }.sorted(by: >)
        return Array(ours.dropFirst(max(keep, 1)))
    }
}
