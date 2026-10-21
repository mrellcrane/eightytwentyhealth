import Foundation

/// Smooths GPS the way running apps and watches do before they draw or measure
/// anything: a Kalman filter that follows where you are and how fast you're going,
/// trusts each fix by the accuracy GPS reports for it, takes the GPS chip's own speed
/// and heading (from the Doppler shift, much steadier than the gap between two fixes),
/// and throws out fixes that land somewhere you couldn't have run to.
///
/// Raw fixes wander a few meters either side of you every second. Drawn, that's a
/// jagged line; added up, it's distance you didn't run. Filtered, the line is smooth
/// and corners still come out round rather than cut.
///
/// Works in meters on a flat plane around the first fix, close enough across a city.
public struct TrackFilter: Sendable {
    public struct Estimate: Equatable, Sendable {
        public let latitude: Double
        public let longitude: Double
        public let timestamp: Date
        /// Meters per second.
        public let speed: Double
        /// False for the first few fixes after a (re)start, while speed is still a guess.
        public let isSettled: Bool
    }

    /// How hard a runner speeds up, slows down or turns, in m/s². Higher follows the raw
    /// fixes more closely; lower smooths more. Tuned on simulated runs (`TrackFilterTests`).
    public var acceleration: Double = 1.0
    /// The same for a fix without the chip's speed: positions alone need more smoothing.
    public var positionOnlyAcceleration: Double = 0.5
    /// A fix further than this many standard deviations from where you should be is a glitch.
    public var gate: Double = 5
    /// The first fix (and any restart) has to be at least this good.
    public var startAccuracy: Double = 30
    /// Faster than this, after allowing for the fix's accuracy, is a GPS jump, not you. (~2:15 /km.)
    public var maxSpeed: Double = 7.5
    /// No fix for this long (GPS lost, or iOS held updates while you stood still): start
    /// over from the next one rather than guess where you went.
    public var restartGap: Double = 15
    /// Rejecting everything for this long means GPS moved and isn't coming back: follow it.
    public var giveUpAfter: Double = 8

    private struct Axis: Sendable {
        var position = 0.0
        var velocity = 0.0
        var pp = 0.0
        var pv = 0.0
        var vv = 0.0

        init(position: Double, velocity: Double, positionVariance: Double, velocityVariance: Double) {
            self.position = position
            self.velocity = velocity
            pp = positionVariance
            vv = velocityVariance
        }

        /// Constant velocity, with white-noise acceleration of spectral density `q`.
        mutating func predict(_ dt: Double, q: Double) {
            position += velocity * dt
            pp += 2 * dt * pv + dt * dt * vv + q * dt * dt * dt / 3
            pv += dt * vv + q * dt * dt / 2
            vv += q * dt
        }

        func positionInnovation(_ z: Double, variance r: Double) -> (residual: Double, variance: Double) {
            (z - position, pp + r)
        }

        mutating func measurePosition(_ z: Double, variance r: Double) {
            let s = pp + r
            let kp = pp / s, kv = pv / s
            let residual = z - position
            position += kp * residual
            velocity += kv * residual
            (pp, pv, vv) = (pp - kp * pp, pv - kp * pv, vv - kv * pv)
        }

        mutating func measureVelocity(_ z: Double, variance r: Double) {
            let s = vv + r
            let kp = pv / s, kv = vv / s
            let residual = z - velocity
            position += kp * residual
            velocity += kv * residual
            (pp, pv, vv) = (pp - kp * pv, pv - kp * vv, vv - kv * vv)
        }
    }

    private struct Origin: Sendable {
        let latitude: Double
        let longitude: Double
        let metersPerDegreeLongitude: Double
    }

    private static let metersPerDegree = 6_371_000.0 * .pi / 180

    private var origin: Origin?
    private var east: Axis?
    private var north: Axis?
    private var last: Date?
    private var updates = 0
    /// When the current run of rejected fixes began.
    private var rejectingSince: Date?

    public init() {}

    /// Forget everything; the next good fix starts a new track (after a pause, say).
    public mutating func reset() {
        east = nil
        north = nil
        last = nil
        updates = 0
        rejectingSince = nil
    }

    /// Feeds a fix. Returns where you most likely are, or nil if the fix was thrown out.
    public mutating func update(_ point: RoutePoint) -> Estimate? {
        let accuracy = max(point.horizontalAccuracy ?? 10, 3)
        guard let east, let north, let last else {
            return accuracy <= startAccuracy ? restart(at: point) : nil
        }
        let dt = point.timestamp.timeIntervalSince(last)
        guard dt > 0 else { return nil }
        if dt > restartGap {
            return accuracy <= startAccuracy ? restart(at: point) : nil
        }

        let (x, y) = local(point)
        let r = accuracy * accuracy
        var e = east, n = north
        let velocity = Self.velocity(point)
        let q = pow(velocity == nil ? positionOnlyAcceleration : acceleration, 2)
        e.predict(dt, q: q)
        n.predict(dt, q: q)
        if let velocity {
            e.measureVelocity(velocity.east, variance: velocity.variance)
            n.measureVelocity(velocity.north, variance: velocity.variance)
        }

        // How far from where you should be, in standard deviations, and in meters you couldn't have covered.
        let ie = e.positionInnovation(x, variance: r), inn = n.positionInnovation(y, variance: r)
        let surprise = ie.residual * ie.residual / ie.variance + inn.residual * inn.residual / inn.variance
        let jump = (hypot(x - east.position, y - north.position) - accuracy) / dt
        if surprise > gate * gate || jump > maxSpeed {
            let since = rejectingSince ?? point.timestamp
            rejectingSince = since
            if point.timestamp.timeIntervalSince(since) >= giveUpAfter, accuracy <= startAccuracy {
                return restart(at: point)
            }
            return nil
        }

        e.measurePosition(x, variance: r)
        n.measurePosition(y, variance: r)
        self.east = e
        self.north = n
        self.last = point.timestamp
        rejectingSince = nil
        updates += 1
        return estimate(at: point.timestamp)
    }

    private mutating func restart(at point: RoutePoint) -> Estimate {
        if origin == nil {
            origin = Origin(latitude: point.latitude, longitude: point.longitude,
                            metersPerDegreeLongitude: Self.metersPerDegree * cos(point.latitude * .pi / 180))
        }
        let (x, y) = local(point)
        let r = pow(max(point.horizontalAccuracy ?? 10, 3), 2)
        let v = Self.velocity(point)
        // Speed unknown without the chip's reading: anywhere up to a sprint.
        east = Axis(position: x, velocity: v?.east ?? 0, positionVariance: r, velocityVariance: v?.variance ?? 25)
        north = Axis(position: y, velocity: v?.north ?? 0, positionVariance: r, velocityVariance: v?.variance ?? 25)
        last = point.timestamp
        updates = v == nil ? 0 : 2
        rejectingSince = nil
        return estimate(at: point.timestamp)
    }

    private func estimate(at timestamp: Date) -> Estimate {
        let e = east!, n = north!, origin = origin!
        return Estimate(
            latitude: origin.latitude + n.position / Self.metersPerDegree,
            longitude: origin.longitude + e.position / origin.metersPerDegreeLongitude,
            timestamp: timestamp,
            speed: hypot(e.velocity, n.velocity),
            isSettled: updates >= 3
        )
    }

    private func local(_ point: RoutePoint) -> (x: Double, y: Double) {
        guard let origin else { return (0, 0) }
        return ((point.longitude - origin.longitude) * origin.metersPerDegreeLongitude,
                (point.latitude - origin.latitude) * Self.metersPerDegree)
    }

    /// The GPS chip's velocity as east and north components, with its variance, when it gave one.
    private static func velocity(_ point: RoutePoint) -> (east: Double, north: Double, variance: Double)? {
        guard let speed = point.speed, speed >= 0, let speedAccuracy = point.speedAccuracy, speedAccuracy >= 0 else { return nil }
        let speedSigma = max(speedAccuracy, 0.2)
        // Standing still, heading means nothing but "not moving" still does.
        guard speed >= 0.5, let course = point.course, course >= 0 else {
            return speed < 0.5 ? (0, 0, pow(speedSigma + 0.5, 2)) : nil
        }
        let courseSigma = (point.courseAccuracy.flatMap { $0 >= 0 ? $0 : nil } ?? 20) * .pi / 180
        let radians = course * .pi / 180
        // Heading error moves the velocity sideways; spread it over both axes.
        let variance = speedSigma * speedSigma + pow(speed * courseSigma, 2)
        return (speed * sin(radians), speed * cos(radians), variance)
    }
}
