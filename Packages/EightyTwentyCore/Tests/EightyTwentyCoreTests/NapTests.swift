import XCTest
@testable import EightyTwentyCore

final class NapTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_792_000_000)

    func testAlarmEndsIt() {
        let nap = Nap(start: t0, minutes: 15)
        XCTAssertEqual(nap.alarmAt, t0.addingTimeInterval(900))
        XCTAssertFalse(nap.isOver(at: t0.addingTimeInterval(899)))
        XCTAssertEqual(nap.remaining(at: t0.addingTimeInterval(300)), 600)
        XCTAssertEqual(nap.progress(at: t0.addingTimeInterval(450)), 0.5, accuracy: 0.0001)
        XCTAssertNil(nap.loggableMinutes(at: t0.addingTimeInterval(899)), "Still asleep")
        XCTAssertTrue(nap.isOver(at: t0.addingTimeInterval(900)))
        XCTAssertEqual(nap.loggableMinutes(at: t0.addingTimeInterval(900)), 15)
        XCTAssertEqual(nap.progress(at: t0.addingTimeInterval(900)), 1)
    }

    func testOpeningTheAppHoursLaterLogsTheAlarmLength() {
        let nap = Nap(start: t0, minutes: 20)
        XCTAssertEqual(nap.loggableMinutes(at: t0.addingTimeInterval(4 * 3600)), 20)
        XCTAssertEqual(nap.remaining(at: t0.addingTimeInterval(4 * 3600)), 0)
    }

    func testUpEarlyLogsTheTimeSoFar() {
        var nap = Nap(start: t0, minutes: 30)
        nap.wakeUp(at: t0.addingTimeInterval(12 * 60))
        XCTAssertTrue(nap.isOver(at: t0.addingTimeInterval(12 * 60)))
        XCTAssertEqual(nap.remaining(at: t0.addingTimeInterval(13 * 60)), 0)
        XCTAssertEqual(nap.loggableMinutes(at: t0.addingTimeInterval(2 * 3600)), 12)
    }

    func testWakingUpAfterTheAlarmChangesNothing() {
        var nap = Nap(start: t0, minutes: 15)
        nap.wakeUp(at: t0.addingTimeInterval(40 * 60))
        XCTAssertNil(nap.endedEarlyAt)
        XCTAssertEqual(nap.loggableMinutes(at: t0.addingTimeInterval(40 * 60)), 15)
    }

    func testAccidentalStartIsNotLogged() {
        var nap = Nap(start: t0, minutes: 15)
        nap.wakeUp(at: t0.addingTimeInterval(20))
        XCTAssertTrue(nap.isOver(at: t0.addingTimeInterval(20)))
        XCTAssertNil(nap.loggableMinutes(at: t0.addingTimeInterval(20)))
    }

    func testSurvivesBeingSaved() throws {
        var nap = Nap(start: t0, minutes: 45)
        nap.wakeUp(at: t0.addingTimeInterval(600))
        let decoded = try JSONDecoder().decode(Nap.self, from: JSONEncoder().encode(nap))
        XCTAssertEqual(decoded, nap)
        XCTAssertEqual(decoded.loggableMinutes(at: t0.addingTimeInterval(3600)), 10)
    }

    func testGuide() {
        XCTAssertNotNil(NapGuide.intervention, "The catalog's nap backs the screen")
        XCTAssertEqual(NapGuide.defaultMinutes, 15)
        XCTAssertTrue(NapGuide.lengths.contains(NapGuide.defaultMinutes))
        XCTAssertEqual(NapGuide.intervention?.logsAs, .nap)

        XCTAssertEqual(NapGuide.notes(minutes: 15, hour: 13), [], "The catalog's nap after lunch needs no warning")
        XCTAssertEqual(NapGuide.notes(minutes: 20, hour: 16), [])
        XCTAssertEqual(NapGuide.notes(minutes: 10, hour: 13).count, 1, "Short of 10 minutes asleep")
        XCTAssertTrue(NapGuide.notes(minutes: 30, hour: 13).first?.contains("grogginess") == true)
        XCTAssertTrue(NapGuide.notes(minutes: 15, hour: 17).first?.contains("tonight") == true)
        XCTAssertEqual(NapGuide.notes(minutes: 90, hour: 19).count, 2, "Long and late")
        XCTAssertEqual(NapGuide.notes(minutes: 15, hour: 9), [], "A morning nap doesn't threaten tonight")
    }
}
