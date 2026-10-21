import XCTest
@testable import EightyTwentyCore

/// Simulated runs with phone-like GPS error, so the filter is judged against the truth.
final class TrackFilterTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_792_000_000)
    let origin = (latitude: 47.6062, longitude: -122.3321)
    static let metersPerDegree = 6_371_000.0 * .pi / 180

    /// Repeatable noise.
    struct Noise: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }

        mutating func gaussian() -> Double {
            let u1 = max(Double.random(in: 0..<1, using: &self), 1e-12), u2 = Double.random(in: 0..<1, using: &self)
            return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
        }
    }

    /// Where you truly are each second: x east, y north, in meters.
    struct Truth {
        var x: Double
        var y: Double
        var speed: Double
        var course: Double
    }

    /// Legs of (meters, heading in degrees), or an arc: run at `speed`, one sample a second.
    enum Leg {
        case straight(Double, heading: Double)
        case arc(radius: Double, degrees: Double)
        case stand(seconds: Int)
    }

    func path(_ legs: [Leg], speed: Double = 2.7) -> (samples: [Truth], length: Double) {
        var x = 0.0, y = 0.0, heading = 0.0, length = 0.0
        var samples = [Truth(x: 0, y: 0, speed: speed, course: 0)]
        for leg in legs {
            switch leg {
            case .straight(let meters, let h):
                heading = h
                for _ in 0..<Int(meters / speed) {
                    x += speed * sin(heading * .pi / 180)
                    y += speed * cos(heading * .pi / 180)
                    length += speed
                    samples.append(Truth(x: x, y: y, speed: speed, course: heading))
                }
            case .arc(let radius, let degrees):
                let turnPerSecond = speed / radius * 180 / .pi * (degrees < 0 ? -1 : 1)
                for _ in 0..<Int(abs(degrees) / abs(turnPerSecond)) {
                    heading += turnPerSecond
                    x += speed * sin(heading * .pi / 180)
                    y += speed * cos(heading * .pi / 180)
                    length += speed
                    samples.append(Truth(x: x, y: y, speed: speed, course: (heading + 360).truncatingRemainder(dividingBy: 360)))
                }
            case .stand(let seconds):
                for _ in 0..<seconds { samples.append(Truth(x: x, y: y, speed: 0, course: -1)) }
            }
        }
        return (samples, length)
    }

    /// Phone GPS: an error that wanders slowly (about 3 m, over ~20 s) plus a little
    /// second-to-second jitter, and the chip's own speed and heading, a bit noisy.
    func fixes(_ truth: [Truth], doppler: Bool = true, seed: UInt64 = 7) -> [RoutePoint] {
        var noise = Noise(state: seed)
        let a = exp(-1.0 / 20), wander = 3.0, jitter = 1.5
        var ex = 0.0, ey = 0.0
        return truth.enumerated().map { i, t in
            ex = a * ex + (1 - a * a).squareRoot() * wander * noise.gaussian()
            ey = a * ey + (1 - a * a).squareRoot() * wander * noise.gaussian()
            let x = t.x + ex + jitter * noise.gaussian(), y = t.y + ey + jitter * noise.gaussian()
            let moving = t.speed > 0
            return RoutePoint(
                latitude: origin.latitude + y / Self.metersPerDegree,
                longitude: origin.longitude + x / (Self.metersPerDegree * cos(origin.latitude * .pi / 180)),
                timestamp: start.addingTimeInterval(Double(i)),
                horizontalAccuracy: 5,
                speed: doppler ? max(0, t.speed + 0.15 * noise.gaussian()) : nil,
                speedAccuracy: doppler ? 0.4 : nil,
                course: doppler && moving ? t.course + 4 * noise.gaussian() : nil,
                courseAccuracy: doppler && moving ? 10 : nil
            )
        }
    }

    func rawLength(_ points: [RoutePoint]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
    }

    /// Average distance from the truth, in meters.
    func error(_ points: [RoutePoint], _ truth: [Truth]) -> Double {
        let byTime = Dictionary(uniqueKeysWithValues: truth.enumerated().map { (start.addingTimeInterval(Double($0.offset)), $0.element) })
        let errors = points.compactMap { p -> Double? in
            guard let t = byTime[p.timestamp] else { return nil }
            let x = (p.longitude - origin.longitude) * Self.metersPerDegree * cos(origin.latitude * .pi / 180)
            let y = (p.latitude - origin.latitude) * Self.metersPerDegree
            return hypot(x - t.x, y - t.y)
        }
        return errors.reduce(0, +) / Double(errors.count)
    }

    /// Total turning along the line, in degrees: a jagged line turns far more than you did.
    func turning(_ points: [RoutePoint]) -> Double {
        var total = 0.0
        var lastBearing: Double?
        for (a, b) in zip(points, points.dropFirst()) where a.distance(to: b) > 0.5 {
            let bearing = atan2((b.longitude - a.longitude) * cos(a.latitude * .pi / 180), b.latitude - a.latitude) * 180 / .pi
            if let lastBearing {
                var turn = abs(bearing - lastBearing)
                if turn > 180 { turn = 360 - turn }
                total += turn
            }
            lastBearing = bearing
        }
        return total
    }

    func record(_ points: [RoutePoint]) -> RunTracker {
        var tracker = RunTracker(splitDistance: 1609.344)
        tracker.start(at: start)
        for point in points { tracker.add(point) }
        tracker.finish(at: points.last!.timestamp)
        return tracker
    }

    /// City blocks with a few square corners, a bend and a lap of a track.
    var blocks: [Leg] {
        [.straight(400, heading: 0), .straight(250, heading: 90), .straight(400, heading: 180),
         .straight(160, heading: 90), .arc(radius: 40, degrees: 90), .straight(300, heading: 180),
         .arc(radius: 36.5, degrees: 180), .straight(84, heading: 0), .arc(radius: 36.5, degrees: 180),
         .straight(84, heading: 180), .straight(500, heading: 270)]
    }

    func testCityBlocksComeOutSmoothAndTheRightLength() {
        let (truth, length) = path(blocks)
        let raw = fixes(truth)
        let tracker = record(raw)

        let rawError = (rawLength(raw) - length) / length
        let smoothError = (tracker.distance - length) / length
        print("City blocks \(Int(length)) m: raw \(String(format: "%+.1f%%", rawError * 100)), smoothed \(String(format: "%+.1f%%", smoothError * 100)); turning raw \(Int(turning(raw)))°, smoothed \(Int(turning(tracker.route)))°; off by raw \(String(format: "%.1f", error(raw, truth))) m, smoothed \(String(format: "%.1f", error(tracker.route, truth))) m")
        XCTAssertEqual(smoothError, 0, accuracy: 0.015, "Within 1.5% of the true distance")
        XCTAssertLessThan(abs(smoothError), abs(rawError), "Closer than adding up raw fixes")
        XCTAssertLessThan(turning(tracker.route), turning(raw) / 3, "Far less zigzag")
        XCTAssertLessThan(error(tracker.route, truth), error(raw, truth), "Closer to where you actually ran")
        XCTAssertTrue(tracker.stops.isEmpty, "Never stopped")
        XCTAssertEqual(tracker.movingTime(at: raw.last!.timestamp), Double(truth.count - 1), accuracy: 1)
    }

    func testWithoutTheChipsSpeedStillSmooths() {
        let (truth, length) = path(blocks)
        let raw = fixes(truth, doppler: false)
        let tracker = record(raw)
        let smoothError = (tracker.distance - length) / length
        print("Position only: smoothed \(String(format: "%+.1f%%", smoothError * 100)), turning raw \(Int(turning(raw)))°, smoothed \(Int(turning(tracker.route)))°")
        // This jitter is harsher than an iPhone's, whose fixes Core Location has already smoothed some.
        XCTAssertEqual(smoothError, 0, accuracy: 0.06)
        XCTAssertLessThan(smoothError, (rawLength(raw) - length) / length / 5)
        XCTAssertLessThan(turning(tracker.route), turning(raw) / 3)
    }

    func testFollowsATurnaround() {
        let (truth, length) = path([.straight(500, heading: 45), .straight(500, heading: 225)])
        let tracker = record(fixes(truth, seed: 11))
        XCTAssertEqual(tracker.distance, length, accuracy: length * 0.02)
    }

    func testStandingAtALightStopsTheClockAndAddsNothing() {
        let (truth, length) = path([.straight(300, heading: 0), .stand(seconds: 60), .straight(300, heading: 90)])
        let raw = fixes(truth, seed: 3)
        let tracker = record(raw)
        let end = raw.last!.timestamp

        print("Light: raw \(Int(rawLength(raw))) m, smoothed \(Int(tracker.distance)) m of \(Int(length)); moving \(Int(tracker.movingTime(at: end))) s of \(Int(tracker.elapsedTime(at: end))) s")
        XCTAssertEqual(tracker.distance, length, accuracy: 12)
        XCTAssertEqual(tracker.stops.count, 1)
        let stopped = tracker.stops.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        XCTAssertEqual(stopped, 60, accuracy: 6)
        XCTAssertEqual(tracker.movingTime(at: end), tracker.elapsedTime(at: end) - stopped, accuracy: 0.001)
    }

    func testStationaryHoldStopsTheClockUntilYouGoAgain() {
        let (truth, _) = path([.straight(300, heading: 0)])
        let raw = fixes(truth)
        var tracker = RunTracker()
        tracker.start(at: start)
        for point in raw { tracker.add(point) }
        let last = raw.last!.timestamp
        let moving = tracker.movingTime(at: last)

        // iOS says you've stopped and sends nothing for two minutes.
        tracker.markStationary(at: last.addingTimeInterval(5))
        XCTAssertTrue(tracker.isStopped)
        XCTAssertEqual(tracker.movingTime(at: last.addingTimeInterval(60)), moving, "Clock held")
        XCTAssertNil(tracker.currentPace())

        // Then you set off again from the same spot.
        let again = fixes(path([.straight(300, heading: 0)]).samples, seed: 5).map { point -> RoutePoint in
            var p = point
            p.latitude += 300 / Self.metersPerDegree
            p.timestamp = p.timestamp.addingTimeInterval(last.timeIntervalSince(start) + 120)
            return p
        }
        for point in again { tracker.add(point) }
        let end = again.last!.timestamp
        tracker.finish(at: end)
        XCTAssertFalse(tracker.isStopped)
        XCTAssertEqual(tracker.movingTime(at: end), moving + Double(again.count - 1), accuracy: 4)
        XCTAssertEqual(tracker.distance, 600, accuracy: 20)
    }

    func testThrowsOutAJump() {
        let (truth, length) = path([.straight(600, heading: 0)])
        var raw = fixes(truth)
        // Multipath: one fix lands 80 m off, claiming to be good to 10 m.
        raw[100].longitude += 80 / (Self.metersPerDegree * cos(origin.latitude * .pi / 180))
        raw[100].horizontalAccuracy = 10
        var filter = TrackFilter()
        var rejected = 0
        for point in raw where filter.update(point) == nil { rejected += 1 }
        XCTAssertEqual(rejected, 1)
        XCTAssertEqual(record(raw).distance, length, accuracy: length * 0.015)
    }

    func testFollowsGPSThatMovedForGood() {
        var filter = TrackFilter()
        let at = { (seconds: Double, east: Double) in
            RoutePoint(latitude: self.origin.latitude,
                       longitude: self.origin.longitude + east / (Self.metersPerDegree * cos(self.origin.latitude * .pi / 180)),
                       timestamp: self.start.addingTimeInterval(seconds), horizontalAccuracy: 5)
        }
        for s in 0...10 { XCTAssertNotNil(filter.update(at(Double(s), 0))) }
        // Everything from here on is 150 m east: a glitch at first, then where GPS is now.
        let after = (11...30).map { filter.update(at(Double($0), 150)) }
        XCTAssertNil(after.first!)
        let followed = after.firstIndex { $0 != nil }
        XCTAssertNotNil(followed)
        XCTAssertLessThanOrEqual(followed ?? 99, 9)
    }

    func testNeedsAGoodFirstFix() {
        var filter = TrackFilter()
        let point = { (accuracy: Double) in
            RoutePoint(latitude: self.origin.latitude, longitude: self.origin.longitude, timestamp: self.start, horizontalAccuracy: accuracy)
        }
        XCTAssertNil(filter.update(point(45)))
        XCTAssertNotNil(filter.update(point(8)))
    }
}
