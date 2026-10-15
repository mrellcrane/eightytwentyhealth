import XCTest
@testable import EightyTwentyCore

final class BaselineTests: XCTestCase {
    func testMedian() {
        XCTAssertEqual(Baseline.median([3, 1, 2]), 2)
        XCTAssertEqual(Baseline.median([4, 1, 3, 2]), 2.5)
    }

    func testNeedsEnoughHistory() {
        XCTAssertNil(Baseline.robustZ(50, history: [50, 51, 49, 52, 48, 50]))
        XCTAssertNotNil(Baseline.robustZ(50, history: [50, 51, 49, 52, 48, 50, 50]))
    }

    func testYourNormalScoresSeventyFive() {
        let history: [Double] = [48, 50, 52, 49, 51, 50, 47, 53, 50, 50]
        let z = Baseline.robustZ(50, history: history)!
        XCTAssertEqual(z, 0, accuracy: 1e-9)
        XCTAssertEqual(Baseline.score(z: z), 75)
    }

    func testOneFreakDayDoesNotWarpTheBaseline() {
        // Your real step counts include a 39k-step day; it shouldn't make 10k look average.
        let typical: [Double] = [6555, 9552, 5878, 4778, 8444, 5127, 9140, 5967, 10940, 9688]
        let withHugeDay = typical + [39020]
        let withBigDay = typical + [11000]

        // The 39k day counts exactly as much as an 11k day would: one more "high" day.
        let zHuge = Baseline.robustZ(10000, history: withHugeDay)!
        XCTAssertEqual(zHuge, Baseline.robustZ(10000, history: withBigDay)!, accuracy: 1e-9)
        XCTAssertGreaterThan(zHuge, 0.3, "10k is still an above-normal day for you")

        // Mean/SD would have let that one day convince you 10k steps is *below* normal.
        let mean = withHugeDay.reduce(0, +) / Double(withHugeDay.count)
        let classicZ = (10000 - mean) / Baseline.standardDeviation(withHugeDay)
        XCTAssertLessThan(classicZ, 0)
    }

    func testScoreDirectionAndClamping() {
        XCTAssertEqual(Baseline.score(z: 2), 100)
        XCTAssertEqual(Baseline.score(z: -2), 50)
        XCTAssertEqual(Baseline.score(z: 10), 100)
        XCTAssertEqual(Baseline.score(z: -10), 0)
        // Resting HR: higher than usual is worse.
        XCTAssertEqual(Baseline.score(z: 2, higherIsBetter: false), 50)
    }

    func testFlatHistoryDoesNotDivideByZero() {
        let flat = Array(repeating: 52.0, count: 10)
        XCTAssertEqual(Baseline.robustZ(52, history: flat), 0)
        // Spread falls back to the 5% noise floor: 2.6 bpm around 52.
        XCTAssertEqual(Baseline.robustZ(55, history: flat)!, 3 / 2.6, accuracy: 1e-9)
        XCTAssertEqual(Baseline.robustZ(50, history: flat)!, -2 / 2.6, accuracy: 1e-9)

        let zeros = Array(repeating: 0.0, count: 10)
        XCTAssertEqual(Baseline.robustZ(0, history: zeros), 0)
        XCTAssertEqual(Baseline.robustZ(5, history: zeros), 1, "No scale at all: just the direction")
    }

    func testTinyWobbleOnASteadyWeekIsNoise() {
        // HRV that barely moves: a 2 ms dip shouldn't read as a bad day.
        let steady: [Double] = [59, 60, 61, 60, 59, 61, 60, 60, 62, 58]
        let score = Baseline.score(z: Baseline.robustZ(58, history: steady)!)
        XCTAssertGreaterThan(score, 65)
    }
}
