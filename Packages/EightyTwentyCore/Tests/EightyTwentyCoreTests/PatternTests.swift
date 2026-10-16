import XCTest
@testable import EightyTwentyCore

final class StatsTests: XCTestCase {
    func testTiesShareTheirAverageRank() {
        XCTAssertEqual(Stats.ranks([10, 20, 20, 30, 5]), [2, 3.5, 3.5, 5, 1])
    }

    func testSpearmanMatchesReference() {
        // Reference values from scipy.stats.spearmanr.
        let x: [Double] = [3, 1, 4, 1, 5, 9, 2, 6, 5, 3, 5, 8, 9, 7, 9]
        let y: [Double] = [2, 7, 1, 8, 2, 8, 1, 8, 2, 8, 4, 5, 9, 0, 4]
        let r = Stats.spearman(x, y)!
        XCTAssertEqual(r, 0.17916174391114706, accuracy: 1e-12)
        XCTAssertEqual(Stats.correlationPValue(r: r, n: Double(x.count)), 0.5228912570529161, accuracy: 1e-10)
    }

    func testPValuesMatchTheTDistribution() {
        // 2 * scipy.stats.t.sf(|t|, n - 2) with t = r * sqrt((n - 2) / (1 - r^2)).
        let cases: [(r: Double, n: Double, p: Double)] = [
            (0.5, 20, 0.024769558804109703),
            (0.3, 30, 0.10724594805795436),
            (-0.62, 24, 0.0012308328706616464),
            (0.05, 100, 0.6212899778453028),
            (0.9, 10, 0.00038715624999999926),
            (0.2, 3.5, 0.8325096840032082),
        ]
        for c in cases {
            XCTAssertEqual(Stats.correlationPValue(r: c.r, n: c.n), c.p, accuracy: 1e-12, "r \(c.r), n \(c.n)")
        }
        XCTAssertEqual(Stats.correlationPValue(r: 0, n: 50), 1, accuracy: 1e-12)
        XCTAssertEqual(Stats.correlationPValue(r: 1, n: 50), 0)
        XCTAssertEqual(Stats.correlationPValue(r: 0.5, n: 2), 1, "Too few days to say anything")
    }

    func testBenjaminiHochbergMatchesReference() {
        // scipy.stats.false_discovery_control
        let adjusted = Stats.benjaminiHochberg([0.01, 0.04, 0.03, 0.005, 0.5])
        for (a, b) in zip(adjusted, [0.025, 0.05, 0.05, 0.025, 0.5]) {
            XCTAssertEqual(a, b, accuracy: 1e-12)
        }
        XCTAssertEqual(Stats.benjaminiHochberg([]), [])
    }

    func testCarryoverShrinksTheSample() {
        XCTAssertEqual(Stats.lag1Autocorrelation([1, 2, 3, 4, 5, 6, 7, 8]), 0.625, accuracy: 1e-12)
        XCTAssertEqual(Stats.effectiveSampleSize(n: 100, autocorrelationX: 0, autocorrelationY: 0.9), 100)
        XCTAssertEqual(Stats.effectiveSampleSize(n: 100, autocorrelationX: 0.5, autocorrelationY: 0.5), 60, accuracy: 1e-9)
        XCTAssertEqual(Stats.effectiveSampleSize(n: 100, autocorrelationX: -0.5, autocorrelationY: 0.5), 100, "Never more than n")
        XCTAssertEqual(Stats.effectiveSampleSize(n: 10, autocorrelationX: 0.99, autocorrelationY: 0.99), 3, "Floor keeps df >= 1")
    }
}

final class PatternFinderTests: XCTestCase {
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static let start = DayKey(year: 2026, month: 1, day: 1)!

    private func days(_ count: Int) -> [DayKey] {
        DayKey.range(from: Self.start, through: Self.start.adding(days: count - 1))
    }

    /// 100 days of noise: HRV, sleep, readiness and steps drift (each day leans on the
    /// last, like the real thing), everything else is independent day to day. With
    /// `plant`, a later bedtime lowers that night's HRV and alcohol lowers the next.
    /// Mirrored in Python to check the expected results before writing these tests.
    private func makeData(seed: UInt64, count: Int = 100, plant: Bool = false) -> PatternData {
        var rng = SplitMix64(state: seed)
        var sensors: [DayKey: SensorDay] = [:]
        var reports: [DayKey: SelfReportDay] = [:]
        var activities: [DayKey: Set<ActivityKind>] = [:]
        var hrvDrift = 0.0, sleepDrift = 0.0, readinessDrift = 0.0, stepsDrift = 0.0
        var alcoholYesterday = false

        for day in days(count) {
            // The night that ended this morning.
            let bedMinutes = Int((rng.uniform() * 240).rounded()) - 150
            let bed = Double(bedMinutes) / 60
            hrvDrift = 0.7 * hrvDrift + rng.normal() * 6
            sleepDrift = 0.7 * sleepDrift + rng.normal() * 5
            readinessDrift = 0.7 * readinessDrift + rng.normal() * 5
            stepsDrift = 0.7 * stepsDrift + rng.normal() * 2500

            var sensor = SensorDay(day: day)
            sensor.bedtimeStart = day.startDate(in: Self.utc).addingTimeInterval(TimeInterval(bedMinutes * 60))
            sensor.sleepSeconds = (7 + rng.normal() * 0.8) * 3600
            sensor.averageHRV = 50 + hrvDrift + (plant ? -5 * bed - (alcoholYesterday ? 12 : 0) : 0)
            sensor.sleepScore = 80 + sleepDrift
            sensor.readinessScore = 75 + readinessDrift
            sensor.ouraSteps = 8000 + stepsDrift
            sensor.stressHighMinutes = max(0, 60 + rng.normal() * 30)
            sensors[day] = sensor

            // The day itself.
            var report = SelfReportDay(day: day)
            if rng.uniform() < 0.8 { report.moodValences = [min(1, max(-1, rng.normal() * 0.4))] }
            report.practiced = rng.uniform() < 0.4
            reports[day] = report

            var kinds: Set<ActivityKind> = []
            for kind in [ActivityKind.meditation, .walk, .workout, .alcohol, .lateCaffeine] {
                if rng.uniform() < 0.35 { kinds.insert(kind) }
            }
            activities[day] = kinds
            alcoholYesterday = kinds.contains(.alcohol)
        }
        return PatternData(sensors: sensors, reports: reports, activities: activities, loggingStart: Self.start, calendar: Self.utc)
    }

    func testNoRealEffectFindsNothing() {
        let found = PatternFinder.find(in: makeData(seed: 42), days: days(100))
        XCTAssertEqual(found.count, 40, "Every sensible pair with enough data gets tested")
        XCTAssertEqual(found.filter(\.holdsUp).map(\.id), [])
        // The luckiest pair still looks like something before correcting for 40 tests.
        XCTAssertLessThan(found[0].p, 0.05)
        XCTAssertGreaterThan(found[0].adjustedP, 0.5)
    }

    func testFindsPlantedEffects() {
        let found = PatternFinder.find(in: makeData(seed: 42, plant: true), days: days(100))
        XCTAssertEqual(found.filter(\.holdsUp).map(\.id), ["activity.alcohol->hrv", "bedtime->hrv"])

        let alcohol = found.first { $0.id == "activity.alcohol->hrv" }!
        XCTAssertLessThan(alcohol.r, -0.5)
        let averages = alcohol.averages!
        XCTAssertLessThan(averages.with, averages.without - 8, "Planted 12 ms drop")

        let bedtime = found.first { $0.id == "bedtime->hrv" }!
        XCTAssertLessThan(bedtime.r, -0.3)
        XCTAssertNil(bedtime.averages)
        XCTAssertEqual(bedtime.summary, "Later bedtime, lower HRV")
    }

    func testDayIsPairedWithTheFollowingNight() {
        // Steps on day D set the HRV of the night after D, and nothing else.
        var sensors: [DayKey: SensorDay] = [:]
        let all = days(30)
        for (i, day) in all.enumerated() {
            sensors[day, default: SensorDay(day: day)].ouraSteps = Double((i * 7) % 30) * 1000
            sensors[day.adding(days: 1), default: SensorDay(day: day.adding(days: 1))].averageHRV = Double((i * 7) % 30) + 40
            sensors[day, default: SensorDay(day: day)].readinessScore = Double((i * 11) % 30)
        }
        let data = PatternData(sensors: sensors, reports: [:], activities: [:], loggingStart: nil, calendar: Self.utc)
        let found = PatternFinder.find(in: data, days: all)
        let stepsHRV = found.first { $0.id == "steps->hrv" }!
        XCTAssertEqual(stepsHRV.r, 1, accuracy: 1e-12)
        XCTAssertEqual(stepsHRV.days, 30)
        XCTAssertLessThan(stepsHRV.p, 1e-10)
    }

    func testGuardrails() {
        // Under 21 days: nothing is tested at all.
        XCTAssertTrue(PatternFinder.find(in: makeData(seed: 7, count: 21), days: days(21)).isEmpty)

        // A yes/no input needs 7+ days on each side.
        var data = makeData(seed: 7, count: 60)
        for (i, day) in days(60).enumerated() {
            if i >= 5 { data.activities[day]?.insert(.sauna) } else { data.activities[day]?.remove(.sauna) }
        }
        let ids = Set(PatternFinder.find(in: data, days: days(60)).map(\.id))
        XCTAssertFalse(ids.contains("activity.sauna->hrv"), "Only 5 days without sauna")
        XCTAssertTrue(ids.contains("activity.walk->hrv"))

        // Before anything was logged, a missing log isn't a "no".
        data.loggingStart = Self.start.adding(days: 50)
        XCTAssertFalse(Set(PatternFinder.find(in: data, days: days(60)).map(\.id)).contains("activity.walk->hrv"))
    }

    func testSkipsPairsThatAreTrueByConstruction() {
        XCTAssertEqual(PatternInput.sleep.outcomes, [.nextDayMood])
        XCTAssertFalse(PatternInput.mood.outcomes.contains(.nextDayMood))
    }

    func testFormatting() {
        XCTAssertEqual(PersonalPattern.formatP(0.0004), "<0.001")
        XCTAssertEqual(PersonalPattern.formatP(0.0234), "0.023")
        XCTAssertEqual(PatternOutcome.hrv.format(41.6), "42 ms")
        XCTAssertEqual(PatternOutcome.nextDayMood.format(0.3), "slightly pleasant")
    }

    func testBedtimeHoursFromMidnight() {
        let night = Self.start.startDate(in: Self.utc)
        var sensor = SensorDay(day: Self.start)
        sensor.bedtimeStart = night.addingTimeInterval(-90 * 60)
        XCTAssertEqual(sensor.bedtimeHoursFromMidnight(calendar: Self.utc), -1.5)
        sensor.bedtimeStart = night.addingTimeInterval(75 * 60)
        XCTAssertEqual(sensor.bedtimeHoursFromMidnight(calendar: Self.utc), 1.25)
    }
}

/// Deterministic on every platform, unlike `Double.random(in:using:)`.
private struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func uniform() -> Double {
        Double(next() >> 11) * 0x1.0p-53
    }

    mutating func normal() -> Double {
        let u1 = 1 - uniform()
        let u2 = uniform()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}
