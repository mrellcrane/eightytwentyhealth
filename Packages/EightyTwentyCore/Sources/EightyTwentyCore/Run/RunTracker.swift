import Foundation

public struct RoutePoint: Codable, Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var timestamp: Date
    public var altitude: Double?
    /// Meters; GPS's own estimate of how wrong this fix might be.
    public var horizontalAccuracy: Double?
    /// Meters per second, measured by the GPS chip from the Doppler shift (not from position).
    public var speed: Double?
    public var speedAccuracy: Double?
    /// Degrees clockwise from true north.
    public var course: Double?
    public var courseAccuracy: Double?

    public init(latitude: Double, longitude: Double, timestamp: Date, altitude: Double? = nil, horizontalAccuracy: Double? = nil,
                speed: Double? = nil, speedAccuracy: Double? = nil, course: Double? = nil, courseAccuracy: Double? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.timestamp = timestamp
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
        self.speed = speed
        self.speedAccuracy = speedAccuracy
        self.course = course
        self.courseAccuracy = courseAccuracy
    }

    /// Great-circle distance in meters (haversine).
    public func distance(to other: RoutePoint) -> Double {
        let earthRadius = 6_371_000.0
        let lat1 = latitude * .pi / 180
        let lat2 = other.latitude * .pi / 180
        let dLat = (other.latitude - latitude) * .pi / 180
        let dLon = (other.longitude - longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * atan2(a.squareRoot(), (1 - a).squareRoot())
    }
}

public struct PauseInterval: Equatable, Sendable {
    public let start: Date
    public let end: Date
}

/// Distance covered between two times, all of it moving.
public struct DistanceSample: Equatable, Sendable {
    public let start: Date
    public let end: Date
    public let meters: Double

    public init(start: Date, end: Date, meters: Double) {
        self.start = start
        self.end = end
        self.meters = meters
    }
}

public struct Split: Equatable, Sendable {
    public let index: Int
    /// Seconds of moving time for this split.
    public let seconds: Double
}

/// The record-a-run state machine (Start / Pause / Resume / Finish), independent of
/// CoreLocation so the distance, pace and split math can be unit tested.
///
/// Fixes go through `TrackFilter` first, so the route, distance and pace come from the
/// smoothed track, not the raw GPS jitter. Distance adds up the speed the GPS chip
/// measures (as GPS watches do), falling back to the smoothed line where it has none.
/// Like Strava, standing still (a light, a map check) stops the clock on its own: pace
/// is moving time over distance.
///
/// Time comes from fix timestamps and the wall clock, so it stays correct if the app is
/// suspended while the screen is locked.
public struct RunTracker: Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case running
        case paused
        case finished
    }

    /// Fixes worse than this are ignored (urban canyons, first fix after unlock). The
    /// filter leans less on fixes the worse they are, so this can be fairly loose.
    public var maxHorizontalAccuracy: Double = 50
    /// Slower than this, you've stopped: the clock pauses until you get going again. In
    /// meters per second; 0.9 is a 30:00 /mi pace, Strava's line for runs.
    public var stopSpeed: Double = 0.9
    /// Split length in meters (1000 for km, 1609.344 for miles).
    public var splitDistance: Double

    public private(set) var state: State = .idle
    public private(set) var startedAt: Date?
    public private(set) var endedAt: Date?
    public private(set) var distance: Double = 0
    /// The smoothed track, in segments separated by pauses. What the map draws.
    public private(set) var segments: [[RoutePoint]] = []
    public private(set) var splits: [Split] = []
    /// When you paused, for the workout's pause/resume events in Apple Health.
    public private(set) var pauses: [PauseInterval] = []
    /// When you stopped moving without pausing; left out of moving time, like pauses.
    public private(set) var stops: [PauseInterval] = []
    /// The distance in stretches of up to 10 seconds, none of them over a pause or stop,
    /// for Apple Health. Health leaves out the part of a sample that falls in a pause, so
    /// one sample from start to finish comes up short by the time you stood still.
    public private(set) var distanceSamples: [DistanceSample] = []
    /// Standing still right now, so the clock isn't running.
    public private(set) var isStopped = false
    /// For checking the filter in the logs: fixes in, fixes thrown out, and the lengths of
    /// the raw and smoothed lines, in meters.
    public private(set) var fixCount = 0
    public private(set) var rejectedCount = 0
    public private(set) var rawLength: Double = 0
    public private(set) var lineLength: Double = 0

    private var filter = TrackFilter()
    /// Moving time up to `clockFrom`.
    private var movingSeconds: Double = 0
    /// The last accepted fix, or when you started or resumed. Moving time after it counts
    /// on the wall clock until the next fix says whether you were still moving.
    private var clockFrom: Date?
    private var stoppedAt: Date?
    private var pausedAt: Date?
    /// The last smoothed estimate, counted or not.
    private var previous: TrackFilter.Estimate?
    private var previousRaw: RoutePoint?
    /// Distance and moving time at each point of the current segment, for current pace.
    private var trail: [(meters: Double, seconds: Double)] = []
    private var splitStartMovingTime: Double = 0

    public init(splitDistance: Double = 1000) {
        self.splitDistance = splitDistance
    }

    public var route: [RoutePoint] { segments.flatMap { $0 } }

    public mutating func start(at date: Date) {
        guard state == .idle else { return }
        state = .running
        startedAt = date
        clockFrom = date
        segments = [[]]
    }

    public mutating func pause(at date: Date) {
        guard state == .running else { return }
        stopClock(at: date)
        pausedAt = date
        state = .paused
    }

    public mutating func resume(at date: Date) {
        guard state == .paused, let pausedAt else { return }
        pauses.append(PauseInterval(start: pausedAt, end: max(date, pausedAt)))
        self.pausedAt = nil
        state = .running
        clockFrom = date
        // New segment: no distance is counted across the gap, and the filter starts fresh
        // wherever you are now.
        segments.append([])
        trail = []
        filter.reset()
        previous = nil
        previousRaw = nil
    }

    public mutating func finish(at date: Date) {
        guard state == .running || state == .paused else { return }
        if state == .running {
            stopClock(at: date)
        } else if let pausedAt {
            pauses.append(PauseInterval(start: pausedAt, end: max(date, pausedAt)))
            self.pausedAt = nil
        }
        state = .finished
        endedAt = date
    }

    /// iOS says you've stopped moving (it holds location updates until you go again).
    public mutating func markStationary(at date: Date) {
        guard state == .running, !isStopped else { return }
        isStopped = true
        stoppedAt = clockFrom ?? date
    }

    /// Feeds a GPS fix. Returns whether it was accepted.
    @discardableResult
    public mutating func add(_ point: RoutePoint) -> Bool {
        guard state == .running else { return false }
        fixCount += 1
        if let accuracy = point.horizontalAccuracy, accuracy < 0 || accuracy > maxHorizontalAccuracy {
            rejectedCount += 1
            return false
        }
        guard let estimate = filter.update(point) else {
            rejectedCount += 1
            return false
        }
        let before = previousRaw
        if let before { rawLength += before.distance(to: point) }
        previousRaw = point
        let smoothed = RoutePoint(latitude: estimate.latitude, longitude: estimate.longitude, timestamp: estimate.timestamp,
                                  altitude: point.altitude, horizontalAccuracy: point.horizontalAccuracy,
                                  speed: estimate.speed)
        let from = clockFrom ?? point.timestamp
        let seconds = max(0, point.timestamp.timeIntervalSince(from))
        clockFrom = point.timestamp
        defer { previous = estimate }

        guard var segment = segments.popLast() else { return false }
        defer { segments.append(segment) }
        guard let last = segment.last else {
            // The first fix since starting or resuming: that time counts.
            if !isStopped { movingSeconds += seconds }
            segment.append(smoothed)
            trail.append((distance, movingSeconds))
            return true
        }

        if isMoving(estimate, seconds: seconds) {
            if isStopped, let stoppedAt {
                stops.append(PauseInterval(start: stoppedAt, end: from))
            }
            isStopped = false
            movingSeconds += seconds
            let meters: Double
            if seconds <= 5, let from = before.flatMap(Self.chipSpeed), let to = Self.chipSpeed(point) {
                // The chip's speed over time: unlike the line, it doesn't pick up GPS wander or
                // cut corners, and unlike the filter's, it doesn't dip in tight turns.
                meters = (from + to) / 2 * seconds
            } else {
                // From the last point counted, so creeping along while "stopped" isn't lost.
                meters = last.distance(to: smoothed)
            }
            lineLength += last.distance(to: smoothed)
            segment.append(smoothed)
            addDistance(meters, stepSeconds: seconds)
            addSample(meters, from: from, to: point.timestamp)
            trail.append((distance, movingSeconds))
        } else if !isStopped {
            isStopped = true
            stoppedAt = from
        }
        return true
    }

    /// Meters per second as the GPS chip measured it, if it did.
    private static func chipSpeed(_ point: RoutePoint) -> Double? {
        guard let speed = point.speed, speed >= 0, let accuracy = point.speedAccuracy, accuracy >= 0 else { return nil }
        return speed
    }

    /// Whether you were moving between the last fix and this one, with some slack either
    /// way so a slow jog at a crossing doesn't flicker the clock on and off.
    private func isMoving(_ estimate: TrackFilter.Estimate, seconds: Double) -> Bool {
        let threshold = isStopped ? stopSpeed * 1.25 : stopSpeed
        // After a gap in fixes, judge by how far you got.
        if seconds > 5, let previous {
            let from = RoutePoint(latitude: previous.latitude, longitude: previous.longitude, timestamp: previous.timestamp)
            let to = RoutePoint(latitude: estimate.latitude, longitude: estimate.longitude, timestamp: estimate.timestamp)
            return from.distance(to: to) / seconds >= threshold
        }
        // Just after a (re)start the filter's speed is a guess: stay as you were.
        guard estimate.isSettled else { return !isStopped }
        return estimate.speed >= threshold
    }

    /// Banks moving time up to `date` (a pause or the finish) and closes any stop.
    private mutating func stopClock(at date: Date) {
        if isStopped, let stoppedAt {
            stops.append(PauseInterval(start: stoppedAt, end: max(date, stoppedAt)))
        } else if let clockFrom {
            movingSeconds += max(0, date.timeIntervalSince(clockFrom))
        }
        isStopped = false
        stoppedAt = nil
        clockFrom = date
    }

    /// Seconds spent moving: not paused, not stopped.
    public func movingTime(at now: Date) -> Double {
        guard state == .running, !isStopped, let clockFrom else { return movingSeconds }
        return movingSeconds + max(0, now.timeIntervalSince(clockFrom))
    }

    /// Start to finish (or now), pauses and stops included.
    public func elapsedTime(at now: Date) -> Double {
        guard let startedAt else { return 0 }
        return max(0, (endedAt ?? now).timeIntervalSince(startedAt))
    }

    /// Seconds per meter over the whole run.
    public func averagePace(at now: Date) -> Double? {
        guard distance >= 50 else { return nil }
        return movingTime(at: now) / distance
    }

    /// Seconds per meter over roughly the last `window` meters, for the live "current pace".
    /// Nil while you're stopped.
    public func currentPace(window: Double = 200) -> Double? {
        guard !isStopped, let last = trail.last else { return nil }
        var earliest = last
        for mark in trail.reversed() {
            earliest = mark
            if last.meters - mark.meters >= window { break }
        }
        let meters = last.meters - earliest.meters
        let seconds = last.seconds - earliest.seconds
        guard meters >= 30, seconds > 0 else { return nil }
        return seconds / meters
    }

    /// Adds a step to the last distance sample if it carries straight on from it and the
    /// sample stays within 10 seconds, or starts a new one.
    private mutating func addSample(_ meters: Double, from start: Date, to end: Date) {
        let end = max(start, end)
        if let last = distanceSamples.last, last.end == start, end.timeIntervalSince(last.start) <= 10 {
            distanceSamples[distanceSamples.count - 1] = DistanceSample(start: last.start, end: end, meters: last.meters + meters)
        } else {
            distanceSamples.append(DistanceSample(start: start, end: end, meters: meters))
        }
    }

    private mutating func addDistance(_ meters: Double, stepSeconds: Double) {
        let before = distance
        distance += meters
        // Close any splits crossed by this step, interpolating the crossing time.
        var boundary = Double(splits.count + 1) * splitDistance
        while distance >= boundary {
            let fraction = meters > 0 ? (boundary - before) / meters : 1
            let crossingMovingTime = movingSeconds - stepSeconds * (1 - fraction)
            splits.append(Split(index: splits.count + 1, seconds: crossingMovingTime - splitStartMovingTime))
            splitStartMovingTime = crossingMovingTime
            boundary = Double(splits.count + 1) * splitDistance
        }
    }
}

public enum PaceFormat {
    /// "5:32" for a pace in seconds per meter, per `unitMeters` (1000 or 1609.344).
    public static func pace(_ secondsPerMeter: Double?, unitMeters: Double) -> String {
        guard let secondsPerMeter, secondsPerMeter.isFinite, secondsPerMeter > 0 else { return "--:--" }
        let total = Int((secondsPerMeter * unitMeters).rounded())
        guard total < 100 * 60 else { return "--:--" }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// "1:02:05" or "32:10".
    public static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    public static func distance(_ meters: Double, unitMeters: Double) -> String {
        String(format: "%.2f", meters / unitMeters)
    }
}
