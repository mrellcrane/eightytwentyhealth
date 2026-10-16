import XCTest
@testable import EightyTwentyCore

final class DistanceCuesTests: XCTestCase {
    let mile = RunningPlan.metersPerMile

    /// Feeds fixes every `step` meters at `secondsPerMile` pace, from `from` to `to` meters.
    func run(_ cues: inout DistanceCues, from: Double = 0, to: Double, secondsPerMile: Double, startSeconds: Double = 0,
             step: Double = 10) -> [DistanceCues.Cue] {
        var found: [DistanceCues.Cue] = []
        var meters = from
        while meters < to {
            meters = min(meters + step, to)
            let seconds = startSeconds + (meters - from) / mile * secondsPerMile
            if let cue = cues.update(meters: meters, seconds: seconds) { found.append(cue) }
        }
        return found
    }

    func testEveryMileAtTheMarkWithTheLastMile() throws {
        var cues = DistanceCues(every: 1, usesMiles: true)
        var found = run(&cues, to: mile, secondsPerMile: 570)
        found += run(&cues, from: mile, to: 2.2 * mile, secondsPerMile: 585, startSeconds: 570)
        XCTAssertEqual(found.map(\.number), [1, 2])
        XCTAssertEqual(found[0].seconds, 570, accuracy: 0.5)
        XCTAssertEqual(found[1].meters, 2 * mile, accuracy: 0.001)
        XCTAssertEqual(found[1].seconds, 1155, accuracy: 0.5)
        XCTAssertEqual(found[1].lastSeconds, 585, accuracy: 0.5)

        let first = cues.message(found[0])
        XCTAssertEqual(first.title, "1 mile in 9:30")
        XCTAssertEqual(first.body, "Average 9:30 /mi.", "Nothing to compare yet on the first mark")
        XCTAssertEqual(first.spoken, "1 mile. Time 9 minutes 30 seconds. Average pace 9 minutes 30 seconds per mile.")

        let second = cues.message(found[1])
        XCTAssertEqual(second.title, "2 miles in 19:15")
        XCTAssertEqual(second.body, "Average 9:38 /mi. Last mile 9:45.")
        XCTAssertEqual(second.spoken, "2 miles. Time 19 minutes 15 seconds. Average pace 9 minutes 38 seconds per mile. Last mile 9 minutes 45 seconds.")
    }

    func testHalfMilesGiveTheLastStretchAsAPace() throws {
        var cues = DistanceCues(every: 0.5, usesMiles: true)
        let found = run(&cues, to: 1.1 * mile, secondsPerMile: 1080)
        XCTAssertEqual(found.map(\.number), [1, 2])
        let message = cues.message(found[1])
        XCTAssertEqual(message.title, "1 mile in 18:00")
        XCTAssertEqual(message.body, "Average 18:00 /mi. Last 0.5 mi at 18:00 /mi.")
        XCTAssertTrue(message.spoken.hasSuffix("Last 0.5 miles at 18 minutes per mile."), message.spoken)
        XCTAssertEqual(cues.message(found[0]).title, "0.5 miles in 9:00")
    }

    func testKilometers() throws {
        var cues = DistanceCues(every: 1, usesMiles: false)
        let found = run(&cues, to: 2050, secondsPerMile: 330 * mile / 1000)
        XCTAssertEqual(found.count, 2)
        let message = cues.message(found[1])
        XCTAssertEqual(message.title, "2 km in 11:00")
        XCTAssertEqual(message.body, "Average 5:30 /km. Last km 5:30.")
        XCTAssertTrue(message.spoken.hasPrefix("2 kilometers. Time 11 minutes."), message.spoken)
    }

    func testAGPSJumpPastTwoMarksGivesOneCueWithTheAverage() {
        var cues = DistanceCues(every: 1, usesMiles: true)
        XCTAssertNil(cues.update(meters: 0.9 * mile, seconds: 540))
        let cue = cues.update(meters: 2.1 * mile, seconds: 1260)
        XCTAssertEqual(cue?.number, 2)
        XCTAssertEqual(cue?.lastSeconds ?? 0, 600, accuracy: 0.5, "Two marks at once: the average of both")
        XCTAssertNil(cues.update(meters: 2.2 * mile, seconds: 1320))
    }

    func testSwitchedOnMidRunPicksUpFromHere() {
        var cues = DistanceCues(every: 1, usesMiles: true, meters: 1.5 * mile, seconds: 900)
        XCTAssertNil(cues.update(meters: 1.9 * mile, seconds: 1140), "Mile 1 already passed")
        let cue = cues.update(meters: 2.1 * mile, seconds: 1260)
        XCTAssertEqual(cue?.number, 2)
        XCTAssertEqual(cue?.lastSeconds ?? 0, 600, accuracy: 1, "Mile 1 assumed at the pace so far")
    }

    func testStandingStillSaysNothing() {
        var cues = DistanceCues(every: 1, usesMiles: true)
        for second in 0..<600 {
            XCTAssertNil(cues.update(meters: 5, seconds: Double(second)))
        }
    }

    func testWords() {
        XCTAssertEqual(DistanceCues.number(0.25), "0.25")
        XCTAssertEqual(DistanceCues.number(0.5), "0.5")
        XCTAssertEqual(DistanceCues.number(2), "2")
        XCTAssertEqual(DistanceCues.distance(1, usesMiles: false, spoken: true), "1 kilometer")
        XCTAssertEqual(DistanceCues.distance(1.5, usesMiles: false, spoken: false), "1.5 km")
        XCTAssertEqual(DistanceCues.spokenDuration(60), "1 minute")
        XCTAssertEqual(DistanceCues.spokenDuration(3725), "1 hour 2 minutes 5 seconds")
        XCTAssertEqual(DistanceCues.spokenDuration(0), "0 seconds")
    }
}
