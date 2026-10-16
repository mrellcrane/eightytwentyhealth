import Foundation
import SwiftData
import EightyTwentyCore

// Two stores:
//
// 1. "UserData" (synced to iCloud via CloudKit): things only you can create.
//    Irreplaceable, so: soft deletes only, and CloudKit's rules apply (every
//    property has a default or is optional, no unique constraints). Schema
//    changes must be additive: add optional properties, never rename or remove.
//
// 2. "Cache" (this device only): Oura + Apple Health data, re-downloadable any
//    time. Safe to wipe.

@Model
final class MoodEntry {
    var id: UUID = UUID()
    var timestamp: Date = Date()
    /// -1 (very unpleasant) to 1 (very pleasant), same as HealthKit State of Mind.
    var valence: Double = 0
    /// 1-5, optional.
    var energy: Int?
    var emotions: [String] = []
    var note: String?
    /// The matching Apple Health sample, if mirrored or imported.
    var healthKitUUID: UUID?
    /// "app" or "healthKit" (logged in Apple's Health app, imported here).
    var source: String = "app"
    var deletedAt: Date?

    init(timestamp: Date = .now, valence: Double, energy: Int? = nil, emotions: [String] = [], note: String? = nil,
         healthKitUUID: UUID? = nil, source: String = "app") {
        self.timestamp = timestamp
        self.valence = valence
        self.energy = energy
        self.emotions = emotions
        self.note = note
        self.healthKitUUID = healthKitUUID
        self.source = source
    }
}

@Model
final class GratitudeEntry {
    var id: UUID = UUID()
    var date: Date = Date()
    var items: [String] = []
    var note: String?
    var deletedAt: Date?

    init(date: Date = .now, items: [String], note: String? = nil) {
        self.date = date
        self.items = items
        self.note = note
    }
}

@Model
final class ActivityLog {
    var id: UUID = UUID()
    var timestamp: Date = Date()
    /// `ActivityKind.rawValue`. Stored as a string so unknown future kinds survive.
    var kind: String = ActivityKind.meditation.rawValue
    var minutes: Double?
    var amount: Double?
    var distanceMeters: Double?
    /// `ActivitySource.rawValue`.
    var source: String = ActivitySource.manual.rawValue
    /// Oura tag/session id, so re-syncing never duplicates.
    var externalID: String?
    var note: String?
    /// Run route as an encoded polyline.
    var routePolyline: String?
    var healthKitUUID: UUID?
    var deletedAt: Date?
    /// `Intervention.id` when logged from the Mental screen or a coach step that matched one.
    var interventionID: String?
    /// 0-10, how strong the problem felt before and after (lower is better). Optional.
    var intensityBefore: Int?
    var intensityAfter: Int?

    init(timestamp: Date = .now, kind: ActivityKind, minutes: Double? = nil, amount: Double? = nil,
         distanceMeters: Double? = nil, source: ActivitySource = .manual, externalID: String? = nil,
         note: String? = nil, routePolyline: String? = nil, healthKitUUID: UUID? = nil) {
        self.timestamp = timestamp
        self.kind = kind.rawValue
        self.minutes = minutes
        self.amount = amount
        self.distanceMeters = distanceMeters
        self.source = source.rawValue
        self.externalID = externalID
        self.note = note
        self.routePolyline = routePolyline
        self.healthKitUUID = healthKitUUID
    }

    var activityKind: ActivityKind? { ActivityKind(rawValue: kind) }

    /// "Run", the intervention's title, or for coach steps that fit no kind, the step (kept in the note).
    var displayTitle: String {
        if let intervention = Intervention.find(interventionID) { return intervention.title }
        if activityKind == .other, let note { return note }
        return activityKind?.title ?? kind.capitalized
    }
}

/// One coach conversation: your questions, what Claude saw, and its answers.
/// Synced and backed up like everything else you create; never sent to logs.
@Model
final class CoachLog {
    var id: UUID = UUID()
    var startedAt: Date = Date()
    var updatedAt: Date = Date()
    /// The first question, for lists.
    var title: String = ""
    /// What Claude saw with the first question: time, bars, Oura, recent logs.
    var context: String = ""
    /// JSON array of `CoachConversation.Turn`.
    var turnsData: Data = Data()
    var deletedAt: Date?

    init(id: UUID, startedAt: Date) {
        self.id = id
        self.startedAt = startedAt
    }

    var turns: [CoachConversation.Turn] { CoachRecord.decodeTurns(turnsData) }

    var record: CoachRecord {
        CoachRecord(id: id, startedAt: startedAt, context: context, turns: turns, deletedAt: deletedAt)
    }

    func update(_ conversation: CoachConversation) {
        title = conversation.turns.first?.question ?? ""
        context = conversation.context
        turnsData = CoachRecord.encodeTurns(conversation.turns)
        updatedAt = .now
    }
}

/// A study from "Look up studies". Saved so the same question cites it back
/// instead of searching again. Synced and backed up.
@Model
final class SavedStudy {
    /// `Study.id`: the DOI, or the page URL without its scheme.
    var key: String = ""
    var citation: String = ""
    var title: String = ""
    var url: String = ""
    var doi: String?
    var design: String = ""
    var finding: String = ""
    var keywords: [String] = []
    /// True only when its link showed up in that lookup's search results.
    var foundBySearch: Bool = false
    var foundAt: Date = Date()
    var topic: String = ""
    var deletedAt: Date?

    init(_ study: Study) {
        key = study.id
        citation = study.citation
        title = study.title
        url = study.url
        doi = study.doi
        design = study.design
        finding = study.finding
        keywords = study.keywords
        foundBySearch = study.foundBySearch
        foundAt = study.foundAt
        topic = study.topic
        deletedAt = study.deletedAt
    }

    var study: Study {
        Study(id: key, citation: citation, title: title, url: url, doi: doi, design: design, finding: finding,
              keywords: keywords, foundBySearch: foundBySearch, foundAt: foundAt, topic: topic, deletedAt: deletedAt)
    }
}

/// One day of sensor data (cache store). The payload is a JSON-encoded `SensorDay`,
/// so adding sensor fields never needs a SwiftData migration.
@Model
final class DailySnapshot {
    var day: String = ""
    var payload: Data = Data()
    var updatedAt: Date = Date()

    init(sensor: SensorDay) {
        self.day = sensor.day.rawValue
        self.update(sensor)
    }

    func update(_ sensor: SensorDay) {
        payload = (try? JSONEncoder.sensor.encode(sensor)) ?? Data()
        updatedAt = .now
    }

    var sensor: SensorDay? {
        try? JSONDecoder.sensor.decode(SensorDay.self, from: payload)
    }
}

extension JSONEncoder {
    static let sensor: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()
}

extension JSONDecoder {
    static let sensor: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}

enum Stores {
    static let userModels: [any PersistentModel.Type] = [MoodEntry.self, GratitudeEntry.self, ActivityLog.self, CoachLog.self, SavedStudy.self]
    static let cacheModels: [any PersistentModel.Type] = [DailySnapshot.self]

    /// Builds the container. If this throws we show an error screen and never
    /// touch the store files: a broken launch must not turn into lost data.
    static func makeContainer() throws -> ModelContainer {
        let user = ModelConfiguration(
            "UserData",
            schema: Schema(userModels),
            // .automatic syncs to the first iCloud container in the entitlements,
            // or stays local if the app was built without iCloud.
            cloudKitDatabase: .automatic
        )
        let cache = ModelConfiguration(
            "Cache",
            schema: Schema(cacheModels),
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: Schema(userModels + cacheModels), configurations: [user, cache])
    }
}
