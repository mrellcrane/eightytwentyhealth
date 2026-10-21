import XCTest
@testable import EightyTwentyCore

final class RunTrackerTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_792_000_000)
    let origin = (latitude: 34.0522, longitude: -118.2437)

    /// A point `meters` due north of the origin, `seconds` after start.
    func point(meters: Double, seconds: Double, accuracy: Double = 5) -> RoutePoint {
        RoutePoint(
            latitude: origin.latitude + meters / 111_195,
            longitude: origin.longitude,
            timestamp: start.addingTimeInterval(seconds),
            horizontalAccuracy: accuracy
        )
    }

    /// Steady 3 m/s (5:33 per km), one fix per second.
    func steadyRun(meters: Double, tracker: inout RunTracker, from: Double = 0, timeOffset: Double = 0) {
        let seconds = Int(meters / 3)
        for s in 0...seconds {
            tracker.add(point(meters: from + Double(s) * 3, seconds: timeOffset + Double(s)))
        }
    }

    func testDistanceTimeAndSplits() {
        var tracker = RunTracker(splitDistance: 1000)
        tracker.start(at: start)
        steadyRun(meters: 2500, tracker: &tracker)
        let end = start.addingTimeInterval(833)
        tracker.finish(at: end)

        XCTAssertEqual(tracker.distance, 2499, accuracy: 10)
        XCTAssertEqual(tracker.movingTime(at: end), 833, accuracy: 0.001)
        XCTAssertEqual(tracker.splits.count, 2)
        for split in tracker.splits {
            XCTAssertEqual(split.seconds, 333.3, accuracy: 2)
        }
        XCTAssertEqual(PaceFormat.pace(tracker.averagePace(at: end), unitMeters: 1000), "5:33")
        XCTAssertEqual(tracker.state, .finished)
    }

    func testPauseExcludesTimeAndDistanceAcrossTheGap() {
        var tracker = RunTracker()
        tracker.start(at: start)
        steadyRun(meters: 300, tracker: &tracker)
        tracker.pause(at: start.addingTimeInterval(100))
        // Points while paused are ignored.
        XCTAssertFalse(tracker.add(point(meters: 600, seconds: 200)))
        tracker.resume(at: start.addingTimeInterval(400))
        // Walked 500 m while paused; resume there. That gap must not count.
        steadyRun(meters: 300, tracker: &tracker, from: 800, timeOffset: 400)
        let end = start.addingTimeInterval(500)
        tracker.finish(at: end)

        XCTAssertEqual(tracker.distance, 600, accuracy: 5)
        XCTAssertEqual(tracker.movingTime(at: end), 200, accuracy: 0.001)
        XCTAssertEqual(tracker.segments.count, 2)
        XCTAssertEqual(tracker.pauses, [PauseInterval(start: start.addingTimeInterval(100), end: start.addingTimeInterval(400))])
    }

    func testMovingTimeFreezesWhilePaused() {
        var tracker = RunTracker()
        tracker.start(at: start)
        tracker.pause(at: start.addingTimeInterval(60))
        XCTAssertEqual(tracker.movingTime(at: start.addingTimeInterval(600)), 60)
        tracker.finish(at: start.addingTimeInterval(700))
        XCTAssertEqual(tracker.movingTime(at: start.addingTimeInterval(9999)), 60)
    }

    func testRejectsBadFixesAndJumps() {
        var tracker = RunTracker()
        tracker.start(at: start)
        XCTAssertTrue(tracker.add(point(meters: 0, seconds: 0)))
        XCTAssertFalse(tracker.add(point(meters: 3, seconds: 1, accuracy: 65)), "Too inaccurate")
        XCTAssertFalse(tracker.add(point(meters: 3, seconds: 1, accuracy: -1)), "Invalid fix")
        XCTAssertFalse(tracker.add(point(meters: 400, seconds: 2)), "200 m/s is a GPS jump")
        XCTAssertFalse(tracker.add(point(meters: 3, seconds: 0)), "Same timestamp")
        XCTAssertTrue(tracker.add(point(meters: 6, seconds: 2)))
        XCTAssertEqual(tracker.distance, 6, accuracy: 1.5, "Smoothed, so a little short of the raw 6 m at first")
        XCTAssertEqual(tracker.fixCount, 6)
        XCTAssertEqual(tracker.rejectedCount, 4)
    }

    func testPausingWhileStoppedClosesTheStop() {
        var tracker = RunTracker()
        tracker.start(at: start)
        steadyRun(meters: 300, tracker: &tracker)
        // Standing at the corner, then you hit Pause.
        for s in 101...130 { tracker.add(point(meters: 300, seconds: Double(s))) }
        XCTAssertTrue(tracker.isStopped)
        tracker.pause(at: start.addingTimeInterval(140))
        XCTAssertFalse(tracker.isStopped)
        tracker.resume(at: start.addingTimeInterval(200))
        steadyRun(meters: 300, tracker: &tracker, from: 300, timeOffset: 200)
        let end = start.addingTimeInterval(300)
        tracker.finish(at: end)

        XCTAssertEqual(tracker.stops.count, 1)
        XCTAssertEqual(tracker.stops[0].end, start.addingTimeInterval(140))
        XCTAssertEqual(tracker.pauses, [PauseInterval(start: start.addingTimeInterval(140), end: start.addingTimeInterval(200))])
        let stopped = tracker.stops[0].end.timeIntervalSince(tracker.stops[0].start)
        XCTAssertEqual(tracker.movingTime(at: end), 300 - 60 - stopped, accuracy: 0.001)
        XCTAssertEqual(stopped, 40, accuracy: 5)
        XCTAssertEqual(tracker.distance, 600, accuracy: 10)
    }

    func testIgnoresPointsBeforeStart() {
        var tracker = RunTracker()
        XCTAssertFalse(tracker.add(point(meters: 0, seconds: 0)))
        XCTAssertEqual(tracker.state, .idle)
    }

    func testCurrentPaceTracksRecentSpeed() {
        var tracker = RunTracker()
        tracker.start(at: start)
        // 300 m slow (2 m/s), then 300 m fast (4 m/s).
        for s in 0...150 { tracker.add(point(meters: Double(s) * 2, seconds: Double(s))) }
        for s in 1...75 { tracker.add(point(meters: 300 + Double(s) * 4, seconds: 150 + Double(s))) }
        XCTAssertEqual(tracker.currentPace(window: 200)!, 0.25, accuracy: 0.01)
    }

    func testPaceFormatting() {
        XCTAssertEqual(PaceFormat.pace(0.3, unitMeters: 1000), "5:00")
        XCTAssertEqual(PaceFormat.pace(0.3, unitMeters: 1609.344), "8:03")
        XCTAssertEqual(PaceFormat.pace(nil, unitMeters: 1000), "--:--")
        XCTAssertEqual(PaceFormat.pace(10, unitMeters: 1000), "--:--", "Standing still")
        XCTAssertEqual(PaceFormat.duration(3725), "1:02:05")
        XCTAssertEqual(PaceFormat.duration(65), "1:05")
        XCTAssertEqual(PaceFormat.distance(5012, unitMeters: 1609.344), "3.11")
    }
}

final class PolylineTests: XCTestCase {
    func testGoogleReferenceExample() {
        let points: [(latitude: Double, longitude: Double)] = [(38.5, -120.2), (40.7, -120.95), (43.252, -126.453)]
        XCTAssertEqual(Polyline.encode(points), "_p~iF~ps|U_ulLnnqC_mqNvxq`@")
    }

    func testRoundTrip() throws {
        let points: [(latitude: Double, longitude: Double)] = (0..<500).map { i -> (latitude: Double, longitude: Double) in
            let step = Double(i)
            let latitude: Double = 34.0522 + step * 0.00003
            let longitude: Double = -118.2437 - step * 0.00002
            return (latitude, longitude)
        }
        let decoded = try XCTUnwrap(Polyline.decode(Polyline.encode(points)))
        XCTAssertEqual(decoded.count, points.count)
        for (a, b) in zip(points, decoded) {
            XCTAssertEqual(a.latitude, b.latitude, accuracy: 0.00001)
            XCTAssertEqual(a.longitude, b.longitude, accuracy: 0.00001)
        }
    }

    func testRejectsGarbage() {
        XCTAssertNil(Polyline.decode("_p~iF~ps|U_"))
        XCTAssertEqual(Polyline.decode("")?.count, 0)
    }
}

final class MeditationTimerTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_792_000_000)

    func testRunsToCompletion() {
        var timer = MeditationTimer(duration: 600, intervalBell: 300)
        timer.start(at: t0)
        timer.update(at: t0.addingTimeInterval(299))
        XCTAssertEqual(timer.bellsDue(at: t0.addingTimeInterval(299)), 0)
        XCTAssertEqual(timer.bellsDue(at: t0.addingTimeInterval(301)), 1)
        XCTAssertEqual(timer.remaining(at: t0.addingTimeInterval(301)), 299)
        timer.update(at: t0.addingTimeInterval(600))
        XCTAssertEqual(timer.state, .completed)
        XCTAssertEqual(timer.bellsDue(at: t0.addingTimeInterval(600)), 1, "The 600 s mark is the end bell, not an interval bell")
        XCTAssertEqual(timer.loggableMinutes(at: t0.addingTimeInterval(9999)), 10)
        XCTAssertEqual(timer.bellOffsets, [300])
    }

    func testPauseAndResume() {
        var timer = MeditationTimer(duration: 600)
        timer.start(at: t0)
        timer.pause(at: t0.addingTimeInterval(120))
        XCTAssertEqual(timer.elapsed(at: t0.addingTimeInterval(500)), 120, "Frozen while paused")
        timer.resume(at: t0.addingTimeInterval(500))
        XCTAssertEqual(timer.elapsed(at: t0.addingTimeInterval(560)), 180)
        timer.update(at: t0.addingTimeInterval(979))
        XCTAssertEqual(timer.state, .running)
        timer.update(at: t0.addingTimeInterval(980))
        XCTAssertEqual(timer.state, .completed)
    }

    func testEndingEarlyLogsWhatWasSat() {
        var timer = MeditationTimer(duration: 1200)
        timer.start(at: t0)
        timer.end(at: t0.addingTimeInterval(450))
        XCTAssertEqual(timer.state, .completed)
        XCTAssertEqual(timer.loggableMinutes(at: t0.addingTimeInterval(9999)), 7.5)
    }

    func testAccidentalStartIsNotLogged() {
        var timer = MeditationTimer(duration: 600)
        timer.start(at: t0)
        timer.end(at: t0.addingTimeInterval(20))
        XCTAssertNil(timer.loggableMinutes(at: t0.addingTimeInterval(20)))
    }
}
