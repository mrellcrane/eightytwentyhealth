import XCTest
@testable import EightyTwentyCore

final class DayKeyTests: XCTestCase {
    func testParsesAndFormats() {
        let key = DayKey("2026-10-15")
        XCTAssertEqual(key?.year, 2026)
        XCTAssertEqual(key?.month, 10)
        XCTAssertEqual(key?.day, 15)
        XCTAssertEqual(key?.rawValue, "2026-10-15")
    }

    func testRejectsInvalidDays() {
        XCTAssertNil(DayKey("2026-02-30"))
        XCTAssertNil(DayKey("2026-13-01"))
        XCTAssertNil(DayKey("2026-10-15T00:00:00"))
        XCTAssertNil(DayKey("26-10-15"))
        XCTAssertNil(DayKey(""))
    }

    func testArithmeticAcrossMonthAndYear() {
        XCTAssertEqual(DayKey("2026-12-31")!.adding(days: 1), DayKey("2027-01-01"))
        XCTAssertEqual(DayKey("2026-03-01")!.adding(days: -1), DayKey("2026-02-28"))
        XCTAssertEqual(DayKey("2026-10-01")!.days(until: DayKey("2026-10-15")!), 14)
        XCTAssertEqual(DayKey.range(from: DayKey("2026-10-30")!, through: DayKey("2026-11-02")!).map(\.rawValue),
                       ["2026-10-30", "2026-10-31", "2026-11-01", "2026-11-02"])
        XCTAssertEqual(DayKey.range(from: DayKey("2026-11-02")!, through: DayKey("2026-10-30")!), [])
    }

    func testOrdering() {
        XCTAssertLessThan(DayKey("2026-09-30")!, DayKey("2026-10-01")!)
        XCTAssertLessThan(DayKey("2025-12-31")!, DayKey("2026-01-01")!)
    }

    func testLocalDayFromDate() {
        var la = Calendar(identifier: .gregorian)
        la.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        // 2026-10-15 05:30 UTC is still the evening of Oct 14 in Los Angeles.
        let date = Date(timeIntervalSince1970: 1_792_042_200)
        XCTAssertEqual(DayKey(date: date, calendar: la).rawValue, "2026-10-14")
        // Midnight Oct 14 in LA (PDT) is 07:00 UTC.
        XCTAssertEqual(DayKey("2026-10-14")!.startDate(in: la).timeIntervalSince1970, 1_791_961_200)
    }

    func testCodableAsString() throws {
        let data = try JSONEncoder().encode(["day": DayKey("2026-10-15")!])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"day":"2026-10-15"}"#)
        let decoded = try JSONDecoder().decode([String: DayKey].self, from: data)
        XCTAssertEqual(decoded["day"], DayKey("2026-10-15"))
    }
}
