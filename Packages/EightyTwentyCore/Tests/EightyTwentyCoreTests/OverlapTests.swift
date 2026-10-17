import XCTest
@testable import EightyTwentyCore

final class OverlapTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_792_000_000)

    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    private func imported(_ kind: ActivityKind, at minutes: Double, for length: Double?, id: String) -> ImportedActivity {
        ImportedActivity(externalID: id, kind: kind, timestamp: at(minutes), minutes: length, source: .ouraSession, note: nil)
    }

    func testAnOuraMomentForASitTimedHereIsSkipped() {
        let timed = [Overlap.Entry(kind: .meditation, span: .init(start: at(0), minutes: 10))]
        let moment = imported(.meditation, at: 1, for: 9, id: "oura-session:a")
        XCTAssertEqual(Overlap.newImports([moment], existing: timed), [])
    }

    func testATagAddedJustAfterIsSkippedButALaterSessionIsNot() {
        let timed = [Overlap.Entry(kind: .meditation, span: .init(start: at(0), minutes: 10))]
        let tag = imported(.meditation, at: 20, for: nil, id: "oura-tag:a")
        let evening = imported(.meditation, at: 9 * 60, for: 15, id: "oura-session:b")
        XCTAssertEqual(Overlap.newImports([tag, evening], existing: timed).map(\.externalID), ["oura-session:b"])
    }

    func testOtherKindsAtTheSameTimeStay() {
        let timed = [Overlap.Entry(kind: .meditation, span: .init(start: at(0), minutes: 10))]
        let breathing = imported(.breathwork, at: 2, for: 5, id: "oura-session:a")
        XCTAssertEqual(Overlap.newImports([breathing], existing: timed), [breathing])
    }

    func testAMomentAndATagForTheSameSitCountOnce() {
        let moment = imported(.meditation, at: 0, for: 10, id: "oura-session:a")
        let tag = imported(.meditation, at: 12, for: nil, id: "oura-tag:a")
        XCTAssertEqual(Overlap.newImports([moment, tag], existing: []), [moment])
    }

    func testTheSameRunSavedTwiceCountsOnceAtTheLongerDistance() {
        struct Run { let start: Double; let end: Double; let meters: Double }
        let runs = [
            Run(start: 0, end: 31, meters: 5000),       // this app's recorder
            Run(start: 0.5, end: 30, meters: 5080),     // a watch on the same run
            Run(start: 31, end: 50, meters: 3000),      // straight after: a second run
            Run(start: 24 * 60, end: 24 * 60 + 40, meters: 6400),
        ]
        let kept = Overlap.distinct(runs, span: { Overlap.Span(start: self.at($0.start), end: self.at($0.end)) }, size: \.meters)
        XCTAssertEqual(kept.map(\.meters), [5080, 3000, 6400])
    }

    func testARunAddedByHandMergesOnlyWithARunItFallsInside() {
        // A run added by hand has no length, just a time.
        struct Run { let span: Overlap.Span; let meters: Double }
        let runs = [
            Run(span: .init(start: at(0), end: at(30)), meters: 5000),      // in Apple Health
            Run(span: .init(start: at(10), minutes: nil), meters: 4990),    // the same run from a screenshot
            Run(span: .init(start: at(90), minutes: nil), meters: 3200),    // treadmill, later
        ]
        XCTAssertEqual(Overlap.distinct(runs, span: \.span, size: \.meters).map(\.meters), [5000, 3200])
    }
}
