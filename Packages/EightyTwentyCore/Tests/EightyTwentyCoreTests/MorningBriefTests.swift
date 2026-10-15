import XCTest
@testable import EightyTwentyCore

final class MorningBriefTests: XCTestCase {
    let today = DayKey("2026-10-15")!
    let calculator = HealthBarsCalculator()

    func steadySensors() -> [DayKey: SensorDay] {
        var result: [DayKey: SensorDay] = [:]
        for offset in 0..<40 {
            let key = today.adding(days: -offset)
            var day = SensorDay(day: key)
            let wobble = Double(offset % 5) - 2
            day.readinessScore = 82
            day.sleepScore = 80
            day.averageHRV = 60 + wobble
            day.lowestHeartRate = 51 - wobble / 2
            day.ouraSteps = 9000
            day.stressHighMinutes = 90 + wobble * 10
            day.recoveryHighMinutes = 60
            result[key] = day
        }
        return result
    }

    func brief(_ sensors: [DayKey: SensorDay], reports: [DayKey: SelfReportDay] = [:]) -> MorningBrief? {
        MorningBrief.compose(
            physical: calculator.display(.physical, on: today, sensors: sensors, reports: reports),
            mental: calculator.display(.mental, on: today, sensors: sensors, reports: reports),
            bedtime: "10:15 PM"
        )
    }

    func testLowHRVMorningSaysRecoveryDay() throws {
        // Your Oct 11 pattern: late night, HRV 35, resting HR 57, readiness 65.
        var sensors = steadySensors()
        sensors[today]?.readinessScore = 65
        sensors[today]?.averageHRV = 35
        sensors[today]?.lowestHeartRate = 57
        let result = try XCTUnwrap(brief(sensors))
        XCTAssertTrue(result.title.hasPrefix("Physical "))
        XCTAssertTrue(result.title.contains("Mental"))
        XCTAssertTrue(result.body.contains("Readiness 65"))
        XCTAssertTrue(result.body.contains("HRV 35 ms vs your usual 60 ms"))
        XCTAssertTrue(result.body.contains("Recovery day"))
        XCTAssertTrue(result.body.contains("10:15 PM"))
    }

    func testGoodMorningSaysGoHarder() throws {
        let result = try XCTUnwrap(brief(steadySensors()))
        XCTAssertTrue(result.body.hasSuffix("Good day for a harder workout."))
    }

    func testNamesTheDraggingNumberWhenItIsNotReadinessOrHRV() throws {
        var sensors = steadySensors()
        sensors[today.adding(days: -1)]?.ouraSteps = 1500
        let result = try XCTUnwrap(brief(sensors))
        XCTAssertTrue(result.body.contains("Steps: 1,500 steps yesterday"), result.body)
        XCTAssertTrue(result.body.contains("20-minute walk"))
    }

    func testNoBriefWithoutEnoughData() {
        XCTAssertNil(brief([:]))
    }

    func testEveryComponentHasAnAction() {
        for id in ComponentID.allCases {
            XCTAssertFalse(MorningBrief.action(for: id, bedtime: "10 PM").isEmpty)
        }
    }
}
