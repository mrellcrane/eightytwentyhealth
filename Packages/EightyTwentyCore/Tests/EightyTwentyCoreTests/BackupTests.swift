import XCTest
@testable import EightyTwentyCore

final class BackupTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_792_000_000)

    func sampleDocument() -> BackupDocument {
        BackupDocument(
            exportedAt: t0,
            appVersion: "1.0 (1)",
            moods: [
                MoodRecord(id: UUID(), timestamp: t0, valence: 2.0 / 3, energy: 4, emotions: ["calm", "grateful"],
                           note: "good run", healthKitUUID: UUID(), source: "app", deletedAt: nil),
            ],
            gratitude: [
                GratitudeRecord(id: UUID(), date: t0, items: ["Coffee with a friend", "Sunny walk", "Slept 8h"], note: nil, deletedAt: nil),
            ],
            activities: [
                ActivityRecord(id: UUID(), timestamp: t0, kind: "run", minutes: 31.5, amount: nil, distanceMeters: 5012,
                               source: "runRecorder", externalID: nil, note: nil, routePolyline: "_p~iF~ps|U", deletedAt: nil),
                ActivityRecord(id: UUID(), timestamp: t0, kind: "alcohol", minutes: nil, amount: 2, distanceMeters: nil,
                               source: "ouraTag", externalID: "oura-tag:t1", note: nil, routePolyline: nil, deletedAt: t0),
            ]
        )
    }

    func testRoundTrip() throws {
        let doc = sampleDocument()
        let decoded = try BackupDocument.decode(try doc.encoded())
        XCTAssertEqual(decoded, doc)
        XCTAssertEqual(decoded.version, BackupDocument.currentVersion)
    }

    func testBackupIsHumanReadable() throws {
        let json = String(decoding: try sampleDocument().encoded(), as: UTF8.self)
        XCTAssertTrue(json.contains("\"Coffee with a friend\""))
        XCTAssertTrue(json.contains("\"exportedAt\" : \"2026-10-14T"))
    }

    func testOlderBackupsMissingOptionalFieldsStillImport() throws {
        let json = """
        {"version":1,"exportedAt":"2026-10-14T00:00:00Z","moods":[{"id":"\(UUID())","timestamp":"2026-10-14T08:00:00Z",
        "valence":0,"emotions":[],"source":"app"}],"gratitude":[],"activities":[]}
        """
        let doc = try BackupDocument.decode(Data(json.utf8))
        XCTAssertEqual(doc.moods.count, 1)
        XCTAssertNil(doc.moods[0].energy)
        XCTAssertNil(doc.appVersion)
    }

    func testMergeNeverDuplicates() {
        let doc = sampleDocument()
        let existingMood = doc.moods[0].id
        let merge = BackupMerge.recordsToInsert(
            from: doc,
            existingIDs: [existingMood],
            existingExternalIDs: ["oura-tag:t1"]
        )
        XCTAssertTrue(merge.moods.isEmpty, "Same id already present")
        XCTAssertEqual(merge.gratitude.count, 1)
        XCTAssertEqual(merge.activities.map(\.kind), ["run"], "Oura tag already imported on this device")
    }

    func testMergeDedupesHealthKitMoods() {
        let doc = sampleDocument()
        let merge = BackupMerge.recordsToInsert(
            from: doc,
            existingIDs: [],
            existingExternalIDs: [],
            existingHealthKitUUIDs: [doc.moods[0].healthKitUUID!]
        )
        XCTAssertTrue(merge.moods.isEmpty, "Already imported from Apple Health under another id")
    }

    func testMergeDedupesWithinTheFileItself() {
        var doc = sampleDocument()
        doc.gratitude.append(doc.gratitude[0])
        let merge = BackupMerge.recordsToInsert(from: doc, existingIDs: [], existingExternalIDs: [])
        XCTAssertEqual(merge.gratitude.count, 1)
    }

    func testFileNamesSortChronologicallyAndPruneSafely() {
        let older = BackupFiles.fileName(for: t0)
        let newer = BackupFiles.fileName(for: t0.addingTimeInterval(86_400))
        XCTAssertLessThan(older, newer)
        XCTAssertTrue(older.hasPrefix("8020-backup-"))
        XCTAssertFalse(older.contains(":"), "Colons are unfriendly in file names")

        let names = [older, newer, "notes.txt", "8020-backup-manual.txt"]
        XCTAssertEqual(BackupFiles.filesToPrune(names, keep: 1), [older])
        XCTAssertEqual(BackupFiles.filesToPrune(names, keep: 5), [])
        XCTAssertEqual(BackupFiles.filesToPrune(names, keep: 0), [older], "Always keeps at least one")
    }
}
