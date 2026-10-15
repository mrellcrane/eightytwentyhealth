import XCTest
@testable import EightyTwentyCore

final class HealthBarsTests: XCTestCase {
    let today = DayKey("2026-10-15")!
    let calculator = HealthBarsCalculator()

    /// 40 steady days: HRV around 50, resting HR around 52, readiness/sleep 80, 8k steps.
    func steadySensors(days: Int = 40) -> [DayKey: SensorDay] {
        var result: [DayKey: SensorDay] = [:]
        for offset in 0..<days {
            let key = today.adding(days: -offset)
            var day = SensorDay(day: key)
            let wobble = Double(offset % 5) - 2 // -2...2
            day.readinessScore = 80
            day.sleepScore = 80
            day.averageHRV = 50 + wobble
            day.lowestHeartRate = 52 - wobble / 2
            day.ouraSteps = 8000
            day.stressHighMinutes = 120 + wobble * 10
            day.recoveryHighMinutes = 30
            result[key] = day
        }
        return result
    }

    func testPhysicalBarOnANormalDay() {
        var sensors = steadySensors()
        sensors[today]?.averageHRV = 50
        sensors[today]?.lowestHeartRate = 52
        let reading = calculator.reading(.physical, on: today, sensors: sensors, reports: [:])

        let byID = Dictionary(uniqueKeysWithValues: reading.components.map { ($0.id, $0) })
        XCTAssertEqual(byID[.readiness]?.score, 80)
        XCTAssertEqual(byID[.sleep]?.score, 80)
        XCTAssertEqual(byID[.hrv]!.score, 75, accuracy: 0.01, "HRV at your median is 'your normal'")
        XCTAssertEqual(byID[.restingHeartRate]!.score, 75, accuracy: 0.01)
        XCTAssertEqual(byID[.activity]?.score, 100, "8k steps yesterday hits the goal")
        XCTAssertEqual(reading.missing, [.vo2Max], "No VO2 data, so it's reported missing, not zero")

        // Missing VO2 (5%) is re-weighted away rather than counted as 0.
        let ouraPart: Double = 80.0 * 0.30 + 80.0 * 0.25
        let baselinePart: Double = 75.0 * 0.15 + 75.0 * 0.10
        let stepsPart: Double = 100.0 * 0.15
        let expected = (ouraPart + baselinePart + stepsPart) / 0.95
        XCTAssertEqual(reading.value!, expected, accuracy: 0.01)
        XCTAssertEqual(reading.coverage, 0.95, accuracy: 1e-9)
    }

    func testLateNightPatternDragsPhysicalDown() {
        // Mirrors your Oct 11: readiness 65, HRV 35, lowest HR 57.
        var sensors = steadySensors()
        sensors[today]?.readinessScore = 65
        sensors[today]?.sleepScore = 71
        sensors[today]?.averageHRV = 35
        sensors[today]?.lowestHeartRate = 57
        let bad = calculator.reading(.physical, on: today, sensors: sensors, reports: [:]).value!
        let normal = calculator.reading(.physical, on: today, sensors: steadySensors(), reports: [:]).value!
        XCTAssertLessThan(bad, normal - 15)
    }

    func testStepsUseYesterdaySoMorningsDoNotSag() {
        var sensors = steadySensors()
        sensors[today]?.ouraSteps = 95 // it's 7am
        let reading = calculator.reading(.physical, on: today, sensors: sensors, reports: [:])
        XCTAssertEqual(reading.components.first { $0.id == .activity }?.score, 100)
    }

    func testStepsTakeTheHigherOfRingAndPhone() {
        var day = SensorDay(day: today)
        day.ouraSteps = 4000
        day.healthKitSteps = 9000
        XCTAssertEqual(day.steps, 9000)
    }

    func testMentalBarUsesMoodAndFallsBackToYesterday() {
        let sensors = steadySensors()
        let reports = [
            today.adding(days: -1): SelfReportDay(day: today.adding(days: -1), moodValences: [2.0 / 3], practiced: true),
        ]
        let reading = calculator.reading(.mental, on: today, sensors: sensors, reports: reports)
        let mood = reading.components.first { $0.id == .mood }
        XCTAssertEqual(mood!.score, 83.33, accuracy: 0.01)
        XCTAssertTrue(mood!.detail.contains("yesterday"))

        let practice = reading.components.first { $0.id == .practice }
        XCTAssertEqual(practice!.score, 20, accuracy: 0.01, "1 of 7 days vs target 5")
    }

    func testBrandNewUserMentalBarIsNotPunishedForNoLogs() {
        let reading = calculator.reading(.mental, on: today, sensors: steadySensors(), reports: [:])
        XCTAssertTrue(reading.missing.contains(.mood))
        XCTAssertTrue(reading.missing.contains(.practice))
        // Stress balance (25%) + sleep (15%) = 40% coverage: just enough to show a bar.
        XCTAssertEqual(reading.coverage, 0.40, accuracy: 1e-9)
        XCTAssertNotNil(reading.value)
    }

    func testTooLittleDataGivesNilNotAFakeNumber() {
        var sensors: [DayKey: SensorDay] = [:]
        var day = SensorDay(day: today)
        day.sleepScore = 80
        sensors[today] = day
        let reading = calculator.reading(.physical, on: today, sensors: sensors, reports: [:])
        XCTAssertEqual(reading.coverage, 0.25, accuracy: 1e-9)
        XCTAssertNil(reading.value)
    }

    func testHRVNeedsAWeekOfHistory() {
        var sensors: [DayKey: SensorDay] = [:]
        for offset in 0..<5 {
            var day = SensorDay(day: today.adding(days: -offset))
            day.averageHRV = 50
            sensors[day.day] = day
        }
        XCTAssertNil(calculator.componentScore(.hrv, on: today, sensors: sensors, reports: [:]))
    }

    func testSmoothingAndDeltas() {
        var sensors = steadySensors()
        // Yesterday was rough.
        sensors[today.adding(days: -1)]?.readinessScore = 50
        sensors[today.adding(days: -1)]?.sleepScore = 50
        let display = calculator.display(.physical, on: today, sensors: sensors, reports: [:])
        let rawToday = calculator.reading(.physical, on: today, sensors: sensors, reports: [:]).value!
        XCTAssertLessThan(display.value!, rawToday, "Smoothing carries some of yesterday into today")
        XCTAssertGreaterThan(display.changeFromYesterday!, 0, "Bouncing back from yesterday")
        XCTAssertNotNil(display.changeFromWeekAverage)
    }

    func testSeriesCoversRequestedDays() {
        let days = DayKey.range(from: today.adding(days: -6), through: today)
        let series = calculator.series(.physical, days: days, sensors: steadySensors(), reports: [:])
        XCTAssertEqual(series.map(\.day), days)
        XCTAssertTrue(series.allSatisfy { $0.value != nil })
    }

    func testSelfReportBuilderGroupsByLocalDay() {
        var la = Calendar(identifier: .gregorian)
        la.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let evening = Date(timeIntervalSince1970: 1_792_042_200) // Oct 14, 10:30pm in LA
        let reports = SelfReportBuilder.build(
            moods: [.init(timestamp: evening, valence: 0.5), .init(timestamp: evening, valence: -0.5)],
            practiceTimestamps: [evening],
            calendar: la
        )
        let oct14 = reports[DayKey("2026-10-14")!]
        XCTAssertEqual(oct14?.averageValence, 0)
        XCTAssertEqual(oct14?.practiced, true)
        XCTAssertNil(reports[DayKey("2026-10-15")!])
    }

    func testMoodScaleRoundTrips() {
        for step in 0...6 {
            XCTAssertEqual(MoodScale.step(forValence: MoodScale.valence(forStep: step)), step)
        }
        XCTAssertEqual(MoodScale.label(forValence: 0), "Neutral")
        XCTAssertEqual(MoodScale.label(forValence: 0.9), "Very pleasant")
        XCTAssertEqual(MoodScale.valence(forStep: 99), 1)
    }
}
