import Foundation

public struct RoutePoint: Codable, Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var timestamp: Date
    public var altitude: Double?
    /// Meters; GPS's own estimate of how wrong this fix might be.
    public var horizontalAccuracy: Double?

    public init(latitude: Double, longitude: Double, timestamp: Date, altitude: Double? = nil, horizontalAccuracy: Double? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.timestamp = timestamp
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
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

public struct Split: Equatable, Sendable {
    public let index: Int
    /// Seconds of moving time for this split.
    public let seconds: Double
}

/// The record-a-run state machine (Start / Pause / Resume / Finish), independent of
/// CoreLocation so the distance, pace and split math can be unit tested.
///
/// Time is wall-clock based, so it stays correct if the app is suspended while
/// the screen is locked.
public struct RunTracker: Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case running
        case paused
        case finished
    }

    /// Fixes worse than this are ignored (urban canyons, first fix after unlock).
    public var maxHorizontalAccuracy: Double = 30
    /// Faster than this between two fixes is a GPS jump, not you. (~2:20 per km.)
    public var maxPlausibleSpeed: Double = 7.5
    /// Split length in meters (1000 for km, 1609.344 for miles).
    public var splitDistance: Double

    public private(set) var state: State = .idle
    public private(set) var startedAt: Date?
    public private(set) var endedAt: Date?
    public private(set) var distance: Double = 0
    /// Accepted points, grouped into segments separated by pauses.
    public private(set) var segments: [[RoutePoint]] = []
    public private(set) var splits: [Split] = []
    /// When you paused, for the workout's pause/resume events in Apple Health.
    public private(set) var pauses: [PauseInterval] = []

    private var pausedDuration: Double = 0
    private var pausedAt: Date?
    private var splitStartMovingTime: Double = 0

    public init(splitDistance: Double = 1000) {
        self.splitDistance = splitDistance
    }

    public var route: [RoutePoint] { segments.flatMap { $0 } }

    public mutating func start(at date: Date) {
        guard state == .idle else { return }
        state = .running
        startedAt = date
        segments = [[]]
    }

    public mutating func pause(at date: Date) {
        guard state == .running else { return }
        state = .paused
        pausedAt = date
    }

    public mutating func resume(at date: Date) {
        guard state == .paused, let pausedAt else { return }
        pausedDuration += max(0, date.timeIntervalSince(pausedAt))
        pauses.append(PauseInterval(start: pausedAt, end: max(date, pausedAt)))
        self.pausedAt = nil
        state = .running
        // New segment: no distance is counted across the gap.
        segments.append([])
    }

    public mutating func finish(at date: Date) {
        guard state == .running || state == .paused else { return }
        if state == .paused, let pausedAt {
            pausedDuration += max(0, date.timeIntervalSince(pausedAt))
            pauses.append(PauseInterval(start: pausedAt, end: max(date, pausedAt)))
            self.pausedAt = nil
        }
        state = .finished
        endedAt = date
    }

    /// Feeds a GPS fix. Returns whether it was accepted.
    @discardableResult
    public mutating func add(_ point: RoutePoint) -> Bool {
        guard state == .running else { return false }
        if let accuracy = point.horizontalAccuracy, accuracy < 0 || accuracy > maxHorizontalAccuracy {
            return false
        }
        guard var segment = segments.popLast() else { return false }
        defer { segments.append(segment) }

        if let last = segment.last {
            let seconds = point.timestamp.timeIntervalSince(last.timestamp)
            guard seconds > 0 else { return false }
            let meters = last.distance(to: point)
            guard meters / seconds <= maxPlausibleSpeed else { return false }
            segment.append(point)
            addDistance(meters, stepSeconds: seconds, at: point.timestamp)
        } else {
            segment.append(point)
        }
        return true
    }

    /// Seconds spent running, excluding pauses.
    public func movingTime(at now: Date) -> Double {
        guard let startedAt else { return 0 }
        let end = endedAt ?? (state == .paused ? (pausedAt ?? now) : now)
        return max(0, end.timeIntervalSince(startedAt) - pausedDuration)
    }

    /// Seconds per meter over the whole run.
    public func averagePace(at now: Date) -> Double? {
        guard distance >= 50 else { return nil }
        return movingTime(at: now) / distance
    }

    /// Seconds per meter over roughly the last `window` meters, for the live "current pace".
    public func currentPace(window: Double = 200) -> Double? {
        guard let segment = segments.last, segment.count >= 2, let last = segment.last else { return nil }
        var meters = 0.0
        var earliest = last
        for (a, b) in zip(segment.dropLast().reversed(), segment.reversed()) {
            meters += a.distance(to: b)
            earliest = a
            if meters >= window { break }
        }
        let seconds = last.timestamp.timeIntervalSince(earliest.timestamp)
        guard meters >= 30, seconds > 0 else { return nil }
        return seconds / meters
    }

    private mutating func addDistance(_ meters: Double, stepSeconds: Double, at timestamp: Date) {
        let before = distance
        distance += meters
        // Close any splits crossed by this step, interpolating the crossing time.
        var boundary = Double(splits.count + 1) * splitDistance
        while distance >= boundary {
            let fraction = meters > 0 ? (boundary - before) / meters : 1
            let crossingMovingTime = movingTime(at: timestamp) - stepSeconds * (1 - fraction)
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
