import XCTest
@testable import EightyTwentyCore

final class MeditationGuideTests: XCTestCase {
    func testEveryFindingIsComplete() throws {
        let all = MeditationGuide.findings + MeditationGuide.dose + MeditationGuide.styles
        XCTAssertEqual(Set(all.map(\.id)).count, all.count, "Duplicate id")
        let doi = try NSRegularExpression(pattern: #"^10\.\d{4,9}/\S+$"#)
        for finding in all {
            XCTAssertEqual(doi.numberOfMatches(in: finding.doi, range: NSRange(finding.doi.startIndex..., in: finding.doi)), 1,
                           finding.id)
            XCTAssertNotNil(finding.url, finding.id)
            XCTAssertFalse(finding.headline.isEmpty || finding.detail.isEmpty || finding.citation.isEmpty, finding.id)
        }
        for style in MeditationStyle.allCases {
            XCTAssertFalse(style.steps.isEmpty, style.rawValue)
            if let id = style.interventionID { XCTAssertNotNil(Intervention.find(id), id) }
            XCTAssertTrue(style.logsAs.isMentalPractice, "\(style) counts as a practice")
        }
    }

    func testOrdinaryDayIsDailyBreathMindfulness() {
        let plan = MeditationGuide.plan(signals: RankingSignals(hour: 9))
        XCTAssertEqual(plan.style, .breath)
        XCTAssertEqual(plan.minutes, 13)
        XCTAssertNil(plan.reason)
        XCTAssertEqual(plan.evidence.id, "basso")

        let lapsed = MeditationGuide.plan(signals: RankingSignals(hour: 9, needs: [.init(.fewPractices, "Practices: 1 of the last 7 days")]))
        XCTAssertEqual(lapsed.style, .breath)
        XCTAssertEqual(lapsed.reason, "Practices: 1 of the last 7 days")
    }

    func testStressedAfternoonIsCyclicSighing() {
        let plan = MeditationGuide.plan(signals: RankingSignals(hour: 14, needs: [
            .init(.lowMood, "Your 1:50 PM check-in: Unpleasant"),
            .init(.stressed, "You checked in stressed at 1:50 PM"),
        ]))
        XCTAssertEqual(plan.style, .cyclicSighing)
        XCTAssertEqual(plan.minutes, 5)
        XCTAssertEqual(plan.reason, "You checked in stressed at 1:50 PM")
        XCTAssertEqual(plan.evidence.id, "breathwork")
    }

    func testLowMoodIsSelfCompassion() {
        let plan = MeditationGuide.plan(signals: RankingSignals(hour: 11, needs: [.init(.lowMood, "Mood: Unpleasant (yesterday)")]))
        XCTAssertEqual(plan.style, .selfCompassion)
        XCTAssertEqual(plan.minutes, 10)
        XCTAssertEqual(plan.evidence.id, "self-compassion")
    }

    func testEveningIsABodyScanForSleep() {
        let plan = MeditationGuide.plan(signals: RankingSignals(hour: 21, needs: [.init(.stressed, "stressed")]))
        XCTAssertEqual(plan.style, .bodyScan)
        XCTAssertEqual(plan.minutes, 15)
        XCTAssertEqual(plan.evidence.id, "sleep")
        XCTAssertEqual(MeditationGuide.plan(signals: RankingSignals(hour: 22, needs: [.init(.lowSleep, "Last night: 5.6 h")])).reason,
                       "Last night: 5.6 h")
    }
}
