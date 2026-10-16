import XCTest
@testable import EightyTwentyCore

final class SourceSyncStatusTests: XCTestCase {
    let earlier = Date(timeIntervalSince1970: 1_792_000_000)

    func testNotConnectedWinsOverEverything() {
        let status = SourceSyncStatus(connected: false, syncing: true, lastSynced: earlier, lastTryFailed: true)
        XCTAssertEqual(status, .notConnected)
    }

    func testSyncingWhileConnected() {
        let status = SourceSyncStatus(connected: true, syncing: true, lastSynced: earlier, lastTryFailed: true)
        XCTAssertEqual(status, .syncing)
    }

    func testFailedKeepsLastGoodSync() {
        XCTAssertEqual(
            SourceSyncStatus(connected: true, syncing: false, lastSynced: earlier, lastTryFailed: true),
            .failed(lastSynced: earlier)
        )
        XCTAssertEqual(
            SourceSyncStatus(connected: true, syncing: false, lastSynced: nil, lastTryFailed: true),
            .failed(lastSynced: nil)
        )
    }

    func testSyncedAndNeverSynced() {
        XCTAssertEqual(
            SourceSyncStatus(connected: true, syncing: false, lastSynced: earlier, lastTryFailed: false),
            .synced(at: earlier)
        )
        XCTAssertEqual(
            SourceSyncStatus(connected: true, syncing: false, lastSynced: nil, lastTryFailed: false),
            .neverSynced
        )
    }
}
