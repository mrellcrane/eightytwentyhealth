import XCTest
@testable import EightyTwentyCore

final class DistanceSplitsTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_792_000_000)
    let mile = 1609.344

    /// 10-second samples at `secondsPerMile` from `from` to `to` meters, starting `at` seconds in.
    func samples(from: Double = 0, to: Double, secondsPerMile: Double, at offset: Double = 0) -> [DistanceSample] {
        let speed = mile / secondsPerMile
        var all: [DistanceSample] = []
        var meters = from
        var t = offset
        while meters < to - 1e-9 {
            let step = min(speed * 10, to - meters)
            let seconds = step / speed
            all.append(DistanceSample(start: start.addingTimeInterval(t), end: start.addingTimeInterval(t + seconds), meters: step))
            meters += step
            t += seconds
        }
        return all
    }

    func testMileSplitsWithTheLeftoverAtTheEnd() {
        let run = samples(to: 2 * mile, secondsPerMile: 570) + samples(from: 2 * mile, to: 2.5 * mile, secondsPerMile: 600, at: 1140)
        let splits = DistanceSplits.from(run, every: mile)
        XCTAssertEqual(splits.map(\.number), [1, 2, 3])
        XCTAssertEqual(splits[0].seconds, 570, accuracy: 0.01)
        XCTAssertEqual(splits[1].seconds, 570, accuracy: 0.01)
        XCTAssertEqual(splits[2].meters, 0.5 * mile, accuracy: 0.01)
        XCTAssertEqual(splits[2].seconds, 300, accuracy: 0.01)
        XCTAssertEqual(splits[2].pace * mile, 600, accuracy: 0.01, "the half mile's pace per mile")
    }

    func testACrossingInsideASampleIsSharedBetweenTheTwoSplits() {
        // One 100-second sample covering 1.5 km at a steady pace.
        let one = [DistanceSample(start: start, end: start.addingTimeInterval(100), meters: 1500)]
        let splits = DistanceSplits.from(one, every: 1000)
        XCTAssertEqual(splits.count, 2)
        XCTAssertEqual(splits[0].seconds, 66.667, accuracy: 0.01)
        XCTAssertEqual(splits[1].meters, 500, accuracy: 0.01)
        XCTAssertEqual(splits[1].seconds, 33.333, accuracy: 0.01)
    }

    func testStopsBetweenSamplesDontCount() {
        // Half a mile, a five-minute stop, half a mile: the split is moving time only.
        let run = samples(to: 0.5 * mile, secondsPerMile: 600) + samples(from: 0.5 * mile, to: mile, secondsPerMile: 600, at: 600)
        let splits = DistanceSplits.from(run, every: mile)
        XCTAssertEqual(splits.count, 1)
        XCTAssertEqual(splits[0].seconds, 600, accuracy: 0.01)
    }

    func testATinyLeftoverIsDropped() {
        let splits = DistanceSplits.from(samples(to: 1.02 * mile, secondsPerMile: 600), every: mile)
        XCTAssertEqual(splits.count, 1)
        XCTAssertTrue(DistanceSplits.from([], every: mile).isEmpty)
    }
}
