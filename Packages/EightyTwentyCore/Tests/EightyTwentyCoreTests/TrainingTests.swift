import XCTest
@testable import EightyTwentyCore

private func day(_ month: Int, _ day: Int) -> DayKey { DayKey(year: 2026, month: month, day: day)! }

/// Plan starting Monday Oct 19 at 11 miles, the week after a 10.7-mile week.
private let plan = RunningPlan(start: day(10, 19), startMiles: 11)

/// The week before the plan: Mon-Wed, longest 4.5.
private let lastWeek = [RunEntry(day: day(10, 12), miles: 3), RunEntry(day: day(10, 13), miles: 3.5), RunEntry(day: day(10, 14), miles: 4.5)]

final class RunningPlanTests: XCTestCase {
    func testWeeksAndWeekdays() {
        XCTAssertEqual(TrainingCalendar.monday(of: day(10, 16)), day(10, 12), "Friday")
        XCTAssertEqual(TrainingCalendar.monday(of: day(10, 18)), day(10, 12), "Sunday belongs to the week before")
        XCTAssertEqual(TrainingCalendar.monday(of: day(10, 19)), day(10, 19))
        XCTAssertEqual(TrainingCalendar.shortName(day(10, 24)), "Sat")
        XCTAssertEqual(TrainingCalendar.label(day(10, 19)), "Mon Oct 19")
        XCTAssertTrue(TrainingCalendar.isWeekend(day(10, 25)))
        XCTAssertEqual(RunningPlan(start: day(10, 21), startMiles: 11).start, day(10, 19), "Snaps to Monday")
    }

    func testGreenWeeksFollowTheTable() {
        let weeks = plan.weeks(runs: [], checkIns: [:], today: day(10, 19), weeksAhead: 7)
        XCTAssertEqual(weeks.map(\.target), [11, 12, 13, 10, 14, 15, 16, 12])
        XCTAssertEqual(weeks.map(\.kind), [.first, .build, .build, .cutback, .build, .build, .build, .cutback])
    }

    func testYellowRepeatsTheWeek() {
        let runs = [RunEntry(day: day(10, 19), miles: 11), RunEntry(day: day(10, 26), miles: 12)]
        let weeks = plan.weeks(runs: runs, checkIns: [day(10, 27): .yellow], today: day(11, 2), weeksAhead: 2)
        XCTAssertEqual(weeks.map(\.target), [11, 12, 12, 13, 10])
        XCTAssertEqual(weeks[2].kind, .repeated)
        XCTAssertEqual(weeks[1].signal, .yellow)
    }

    func testRedDropsBackToTheLastGreenWeek() {
        let runs = [RunEntry(day: day(10, 19), miles: 11), RunEntry(day: day(10, 26), miles: 12), RunEntry(day: day(11, 2), miles: 13)]
        let weeks = plan.weeks(runs: runs, checkIns: [day(11, 3): .red, day(11, 2): .green], today: day(11, 9), weeksAhead: 1)
        XCTAssertEqual(weeks.map(\.target), [11, 12, 13, 12, 13])
        XCTAssertEqual(weeks[3].kind, .droppedBack)
        XCTAssertEqual(weeks[2].signal, .red, "The worst check-in of the week counts")
    }

    func testAMissedWeekRepeats() {
        let runs = [RunEntry(day: day(10, 19), miles: 11), RunEntry(day: day(10, 26), miles: 5)]
        let weeks = plan.weeks(runs: runs, checkIns: [:], today: day(11, 2), weeksAhead: 0)
        XCTAssertEqual(weeks.map(\.target), [11, 12, 12])
        XCTAssertEqual(weeks[2].kind, .repeated)
    }

    func testNoRunningBeforeThePlanStarts() {
        // Miles left this week don't matter: starting Monday means resting until then.
        let runs = [RunEntry(day: day(10, 12), miles: 3)]
        let guidance = plan.guidance(runs: runs, checkIns: [:], today: day(10, 16))
        XCTAssertEqual(guidance.week.kind, .beforePlan)
        XCTAssertEqual(guidance.week.actual, 3)
        XCTAssertTrue(guidance.planned.isEmpty)
        XCTAssertEqual(guidance.headline, "No running until your plan starts Mon Oct 19. Swim, bike, hike, or Orangetheory with power-walking on the tread.")
        XCTAssertEqual(guidance.nextWeek?.start, day(10, 19))
        XCTAssertEqual(guidance.nextWeek?.target, 11)
    }

    func testSpreadsTheWeekWithTheLongRunLast() {
        let guidance = plan.guidance(runs: lastWeek, checkIns: [:], today: day(10, 19))
        XCTAssertEqual(guidance.planned, [
            .init(day: day(10, 19), miles: 3.5, isLong: false),
            .init(day: day(10, 22), miles: 3.5, isLong: false),
            .init(day: day(10, 25), miles: 4, isLong: true),
        ])
        XCTAssertEqual(guidance.headline, "0 of 11 mi done. Easy pace, every run.")
    }

    func testNeverThreeDaysInARow() {
        let runs = lastWeek + [RunEntry(day: day(10, 19), miles: 3.5), RunEntry(day: day(10, 20), miles: 3.5)]
        let guidance = plan.guidance(runs: runs, checkIns: [:], today: day(10, 21))
        XCTAssertEqual(guidance.planned, [.init(day: day(10, 24), miles: 4, isLong: true)], "Not Wednesday, and Saturday over Sunday")
    }

    func testRedWeekStopsRunning() {
        let runs = lastWeek + [RunEntry(day: day(10, 19), miles: 3.5)]
        let guidance = plan.guidance(runs: runs, checkIns: [day(10, 20): .red], today: day(10, 21))
        XCTAssertTrue(guidance.planned.isEmpty)
        XCTAssertTrue(guidance.headline.hasPrefix("Red this week"))
        XCTAssertEqual(guidance.nextWeek?.target, 8, "No green week yet: 75% of 11, rounded")
    }

    func testDistances() {
        XCTAssertEqual(RunningPlan.distances(remaining: 11, count: 3, longCap: 4), [3.5, 3.5, 4])
        XCTAssertEqual(RunningPlan.distances(remaining: 12, count: 3, longCap: 4.5), [3.5, 4, 4.5])
        XCTAssertEqual(RunningPlan.distances(remaining: 5, count: 2, longCap: 4), [2, 3], "No 1-mile runs")
        XCTAssertEqual(RunningPlan.distances(remaining: 10, count: 2, longCap: 4.5), [4.5, 4.5], "Never crams the week")
        XCTAssertEqual(RunningPlan.longRunCap(target: 14, recentLongest: 5), 5.5)
        XCTAssertEqual(RunningPlan.longRunCap(target: 10, recentLongest: 5), 4, "Under 40% of the week")
        XCTAssertEqual(RunningPlan.longRunCap(target: 11, recentLongest: nil), 4)
    }

    func testFormat() {
        XCTAssertEqual(RunningPlan.format(11), "11")
        XCTAssertEqual(RunningPlan.format(10.66), "10.7")
        XCTAssertEqual(RunningPlan.format(0), "0")
    }

    func testSignalsOrderBySeverity() {
        XCTAssertEqual([RunSignal.red, .green, .yellow].max(), .red)
        XCTAssertEqual([RunSignal.green, .yellow].max(), .yellow)
    }
}

final class TrainingAdvisorTests: XCTestCase {
    private func context(today: DayKey, runs: [RunEntry] = lastWeek, checkIns: [DayKey: RunSignal] = [:],
                         strength: [DayKey] = [], readiness: Double? = nil) -> TrainingContext {
        TrainingContext(today: today, runs: runs, checkIns: checkIns, plan: plan, strengthDays: strength, readiness: readiness)
    }

    func testCardioOnAPlannedDay() {
        let advice = TrainingAdvisor.advise(.cardio, context(today: day(10, 19)))
        XCTAssertEqual(advice.title, "Easy run, 3.5 mi")
    }

    func testNoRunBeforeThePlanStarts() {
        let advice = TrainingAdvisor.advise(.cardio, context(today: day(10, 16), runs: [RunEntry(day: day(10, 12), miles: 3)]))
        XCTAssertEqual(advice.title, "No running until Mon Oct 19")
        let both = TrainingAdvisor.advise(.both, context(today: day(10, 16), strength: [day(10, 13)]))
        XCTAssertTrue(both.detail.hasSuffix("instead of a run (plan starts Mon Oct 19)."))
    }

    func testCardioAfterARedCheckIn() {
        let runs = lastWeek + [RunEntry(day: day(10, 19), miles: 3.5)]
        let advice = TrainingAdvisor.advise(.cardio, context(today: day(10, 21), runs: runs, checkIns: [day(10, 19): .red]))
        XCTAssertEqual(advice.title, "Cross-train, no running")
    }

    func testCardioNeverMakesThreeInARow() {
        let runs = lastWeek + [RunEntry(day: day(10, 19), miles: 3.5), RunEntry(day: day(10, 20), miles: 3.5)]
        XCTAssertEqual(TrainingAdvisor.advise(.cardio, context(today: day(10, 21), runs: runs)).title, "No run today")
    }

    func testLowReadinessShortensTheRun() {
        let runs = lastWeek + [RunEntry(day: day(10, 19), miles: 3.5)]
        let advice = TrainingAdvisor.advise(.cardio, context(today: day(10, 22), runs: runs, readiness: 58))
        XCTAssertEqual(advice.title, "Easy run, 3.5 mi")
        XCTAssertTrue(advice.detail.contains("Readiness is 58"))
    }

    func testCardioWithoutAPlan() {
        let c = TrainingContext(today: day(10, 19), runs: [], checkIns: [:], plan: nil, strengthDays: [], readiness: nil)
        XCTAssertEqual(TrainingAdvisor.advise(.cardio, c).title, "Easy run, conversational pace")
    }

    func testStrengthAfterThreeSessionsIsRecovery() {
        let advice = TrainingAdvisor.advise(.strength, context(today: day(10, 19), strength: [day(10, 13), day(10, 15), day(10, 17)]))
        XCTAssertEqual(advice.title, "Recovery day")
    }

    func testStrengthAfterABreakEasesIn() {
        XCTAssertEqual(TrainingAdvisor.advise(.strength, context(today: day(10, 19))).title, "Gym: ease back in, full body, 30 to 40 min")
    }

    func testStrengthTheDayBeforeALongRun() {
        let runs = lastWeek + [RunEntry(day: day(10, 19), miles: 3.5), RunEntry(day: day(10, 22), miles: 3.5)]
        let advice = TrainingAdvisor.advise(.strength, context(today: day(10, 24), runs: runs, strength: [day(10, 21)], readiness: 82))
        XCTAssertEqual(advice.title, "Gym: full body, 45 min")
        XCTAssertEqual(advice.detail, "Readiness is good: last sets 1 to 2 reps short of failure. Keep legs light: long run tomorrow.")
    }

    func testBothOnARunDay() {
        let advice = TrainingAdvisor.advise(.both, context(today: day(10, 19), strength: [day(10, 16)]))
        XCTAssertEqual(advice.title, "Run 3.5 mi, then lift")
    }

    func testBothWhenRunningIsOff() {
        let runs = lastWeek + [RunEntry(day: day(10, 19), miles: 3.5), RunEntry(day: day(10, 20), miles: 3.5)]
        let advice = TrainingAdvisor.advise(.both, context(today: day(10, 21), runs: runs, strength: [day(10, 16)]))
        XCTAssertEqual(advice.title, "Gym: full body, 45 min, plus easy bike")
        XCTAssertTrue(advice.detail.hasSuffix("instead of a run (three days in a row)."))
    }
}

final class RunScreenshotParserTests: XCTestCase {
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private let now = day(10, 16).startDate(in: RunScreenshotParserTests.utc).addingTimeInterval(9 * 3600)

    private func parse(_ lines: [String]) -> (miles: Double?, day: DayKey?) {
        let result = RunScreenshotParser.parse(lines, now: now, calendar: Self.utc)
        return (result.miles, result.date.map { DayKey(date: $0, calendar: Self.utc) })
    }

    func testStravaActivityPage() {
        let result = parse([
            "Morning Run", "October 14, 2026 at 7:02 AM · Seattle, Washington",
            "Distance", "4.52 mi", "Pace", "9:45 /mi", "Moving Time", "44:05", "Elevation Gain", "112 ft",
        ])
        XCTAssertEqual(result.miles, 4.52)
        XCTAssertEqual(result.day, day(10, 14))
    }

    func testPaceIsNeverTakenForDistance() {
        XCTAssertEqual(parse(["9:45 /mi", "4.52 mi"]).miles, 4.52)
        XCTAssertNil(parse(["Time 45 min", "9:45 /mi"]).miles)
    }

    func testKilometers() {
        XCTAssertEqual(parse(["Distance 7,3 km"]).miles!, 7.3 * 1000 / 1609.344, accuracy: 1e-9)
    }

    func testRelativeAndYearlessDates() {
        XCTAssertEqual(parse(["Yesterday at 6:30 PM", "3.1 mi"]).day, day(10, 15))
        XCTAssertEqual(parse(["Today at 7:02 AM"]).day, day(10, 16))
        XCTAssertEqual(parse(["Oct 3 at 7:00 AM"]).day, day(10, 3))
        XCTAssertEqual(parse(["Dec 30 at 7:00 AM"]).day, DayKey(year: 2025, month: 12, day: 30), "Not one still to come")
        XCTAssertEqual(parse(["Marathon 26.2 mi"]).day, nil, "Marathon isn't March")
    }

    func testNothingToFind() {
        let result = parse(["Kudos", "Comments"])
        XCTAssertNil(result.miles)
        XCTAssertNil(result.day)
    }
}
