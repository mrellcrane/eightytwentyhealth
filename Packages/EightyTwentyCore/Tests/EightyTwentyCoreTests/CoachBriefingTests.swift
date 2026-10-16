import XCTest
@testable import EightyTwentyCore

final class CoachBriefingTests: XCTestCase {
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private let today = DayKey(year: 2026, month: 10, day: 16)!

    private func snapshot(plan: RunningPlan?, notes: String = "", withData: Bool = true) -> CoachBriefing.Snapshot {
        var sensors: [DayKey: SensorDay] = [:]
        var runs: [RunEntry] = []
        if withData {
            var sensor = SensorDay(day: today)
            sensor.readinessScore = 78
            sensor.averageHRV = 47.6
            sensor.bedtimeStart = today.startDate(in: Self.utc).addingTimeInterval(-90 * 60)
            sensors[today] = sensor
            runs = [RunEntry(day: today.adding(days: -2), miles: 4.5)]
        }
        return CoachBriefing.Snapshot(
            now: today.startDate(in: Self.utc).addingTimeInterval(9 * 3600), calendar: Self.utc, bars: [],
            sensors: sensors, reports: [:], activities: [today: [.meditation, .workout]], runs: runs,
            checkIns: [today.adding(days: -2): .green], plan: plan, strengthDays: [today.adding(days: -1)],
            patterns: [], notes: notes
        )
    }

    func testLinksRoundTrip() {
        for link in CoachLink.allCases {
            XCTAssertEqual(CoachLink(url: link.url), link)
        }
        XCTAssertNil(CoachLink(url: URL(string: "https://pubmed.ncbi.nlm.nih.gov/123")!), "Research links open in Safari")
        XCTAssertNil(CoachLink(url: URL(string: "eightytwenty://oauth/oura")!), "The Oura callback isn't a coach link")
        XCTAssertEqual(CoachLink.addRun.url.absoluteString, "eightytwenty://app/add-run")
    }

    func testPromptCarriesTheData() {
        let plan = RunningPlan(start: DayKey(year: 2026, month: 10, day: 19)!, startMiles: 11)
        let prompt = CoachBriefing.systemPrompt(snapshot(plan: plan, notes: "Goal: a half marathon next spring."))
        XCTAssertTrue(prompt.contains("[Running](eightytwenty://app/running)"))
        XCTAssertTrue(prompt.contains("## Now\nFriday, October 16, 2026, 9:00 AM."))
        XCTAssertTrue(prompt.contains("2026-10-16: readiness 78, bedtime 22:30, HRV 48 ms, logged meditation, strength"))
        XCTAssertTrue(prompt.contains("2026-10-14: ran 4.5 mi"))
        XCTAssertTrue(prompt.contains("Plan started the week of 2026-10-19 at 11 mi."))
        XCTAssertTrue(prompt.contains("Runs, last 28 days: 2026-10-14: 4.5 mi, felt green."))
        XCTAssertTrue(prompt.contains("## Gym (strength sessions, last 28 days)\n2026-10-15"))
        XCTAssertTrue(prompt.contains("Strength: "), "One suggestion per goal")
        XCTAssertTrue(prompt.hasSuffix("## In their own words (history, goals, anything they want you to know)\nGoal: a half marathon next spring."))
    }

    func testEmptyAppStillBuilds() {
        let prompt = CoachBriefing.systemPrompt(snapshot(plan: nil, withData: false))
        XCTAssertTrue(prompt.contains("2026-10-15: no data"))
        XCTAssertTrue(prompt.contains("No running plan set up yet."))
        XCTAssertTrue(prompt.contains("No runs in the last 28 days."))
        XCTAssertTrue(prompt.contains("Not enough data yet: a pair needs 21 days."))
        XCTAssertFalse(prompt.contains("In their own words"), "No notes, no section")
    }
}
