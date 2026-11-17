import XCTest
@testable import EightyTwentyCore

final class GaitCalloutsTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_792_000_000)

    func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }

    func testSaysTheFirstGaitOnceItHolds() {
        var callouts = GaitCallouts(hold: 6)
        XCTAssertNil(callouts.update(.running, at: at(0)))
        XCTAssertNil(callouts.update(.running, at: at(3)))
        XCTAssertEqual(callouts.update(.running, at: at(6)), .running)
        XCTAssertNil(callouts.update(.running, at: at(8)), "said once, not every check")
    }

    func testABlipShorterThanTheHoldIsNotSaid() {
        var callouts = GaitCallouts(hold: 6)
        _ = callouts.update(.running, at: at(0))
        _ = callouts.update(.running, at: at(6))
        XCTAssertNil(callouts.update(.walking, at: at(10)))
        XCTAssertNil(callouts.update(.running, at: at(14)), "back to running before the walk held")
        XCTAssertNil(callouts.update(.walking, at: at(16)), "the hold starts over")
        XCTAssertNil(callouts.update(.walking, at: at(20)))
        XCTAssertEqual(callouts.update(.walking, at: at(22)), .walking)
    }

    func testRunWalkStopRun() {
        var callouts = GaitCallouts(hold: 5)
        var said: [GaitCallouts.Callout] = []
        let states: [(Double, GaitCallouts.Callout?)] = [
            (0, nil), (2, .running), (8, .running), (30, .walking), (36, .walking),
            (50, .stopped), (56, .stopped), (70, nil), (72, .running), (78, .running),
        ]
        for (t, state) in states {
            if let callout = callouts.update(state, at: at(t)) { said.append(callout) }
        }
        XCTAssertEqual(said, [.running, .walking, .stopped, .running])
    }

    func testStoppedIsNotSaidBeforeAnythingElse() {
        var callouts = GaitCallouts(hold: 5)
        XCTAssertNil(callouts.update(.stopped, at: at(0)))
        XCTAssertNil(callouts.update(.stopped, at: at(20)))
        XCTAssertNil(callouts.update(.stopped, at: at(30), sure: true))
    }

    func testIOSSayingStoppedSkipsTheHold() {
        var callouts = GaitCallouts(hold: 6)
        _ = callouts.update(.walking, at: at(0))
        _ = callouts.update(.walking, at: at(6))
        XCTAssertEqual(callouts.update(.stopped, at: at(40), sure: true), .stopped)
    }

    func testAfterAPauseTheSameGaitIsSaidAgain() {
        var callouts = GaitCallouts(hold: 5)
        _ = callouts.update(.running, at: at(0))
        XCTAssertEqual(callouts.update(.running, at: at(5)), .running)
        callouts.reset()
        XCTAssertNil(callouts.update(.running, at: at(100)))
        XCTAssertEqual(callouts.update(.running, at: at(105)), .running)
    }

    func testSpoken() {
        XCTAssertEqual(GaitCallouts.Callout.running.spoken, "Running")
        XCTAssertEqual(GaitCallouts.Callout(.walk).spoken, "Walking")
        XCTAssertEqual(GaitCallouts.Callout.stopped.spoken, "Stopped")
    }

    // MARK: What you're doing right now

    /// `every`-second samples at `speed` from `from` to `to` seconds.
    func samples(_ from: Int, _ to: Int, speed: Double, every: Int = 1) -> [DistanceSample] {
        stride(from: from, to: to, by: every).map {
            DistanceSample(start: at(Double($0)), end: at(Double($0 + every)), meters: speed * Double(every))
        }
    }

    func testRecentFollowsTheLastFewSecondsNotTheWholeStretch() {
        // Five minutes running, then 12 seconds walking: `split` still folds the walk into the
        // run (under 20 s), but right now you're walking.
        let all = samples(0, 300, speed: 2.8) + samples(300, 312, speed: 1.3)
        let profile = PaceProfile.starting
        XCTAssertEqual(GaitDetector.split(all, profile: profile, steps: StepTrack()).last?.gait, .run)
        XCTAssertEqual(GaitDetector.recent(all, profile: profile, steps: StepTrack(), at: at(312)), .walk)
        XCTAssertEqual(GaitDetector.recent(Array(all.prefix(305)), profile: profile, steps: StepTrack(), at: at(305)), .run,
                       "five seconds of walking against ten of running")
    }

    func testRecentIsNilWithoutEnoughToGoOn() {
        let all = samples(0, 3, speed: 2.8)
        XCTAssertNil(GaitDetector.recent(all, profile: .starting, steps: StepTrack(), at: at(3)))
        let earlier = samples(0, 60, speed: 2.8)
        XCTAssertNil(GaitDetector.recent(earlier, profile: .starting, steps: StepTrack(), at: at(120)),
                     "nothing in the last 15 seconds")
    }

    func testRecentGoesBySteps() {
        // A slow uphill jog: walking speed, running cadence.
        var steps = StepTrack(start: at(0))
        for t in stride(from: 3, through: 30, by: 3) { steps.add(at: at(Double(t)), steps: t * 165 / 60) }
        let all = samples(0, 30, speed: 1.6, every: 5)
        XCTAssertEqual(GaitDetector.recent(all, profile: .starting, steps: steps, at: at(30)), .run)
        XCTAssertEqual(GaitDetector.recent(all, profile: .starting, steps: StepTrack(), at: at(30)), .walk, "by speed alone")
    }
}
