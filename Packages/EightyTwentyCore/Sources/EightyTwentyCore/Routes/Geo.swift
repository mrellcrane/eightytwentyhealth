import Foundation

/// A latitude/longitude pair, without CoreLocation so the route math runs on Linux.
public struct GeoPoint: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Great-circle distance in meters (haversine).
    public func distance(to other: GeoPoint) -> Double {
        let earthRadius = 6_371_000.0
        let lat1 = latitude * .pi / 180
        let lat2 = other.latitude * .pi / 180
        let dLat = (other.latitude - latitude) * .pi / 180
        let dLon = (other.longitude - longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * atan2(a.squareRoot(), (1 - a).squareRoot())
    }

    /// Meters to the closest point of a line. Flat-earth math around `self`, which is
    /// well under 1% off at the few-km scale this is used for.
    public func distance(toLine points: [GeoPoint]) -> Double {
        guard let first = points.first else { return .infinity }
        guard points.count > 1 else { return distance(to: first) }
        let metersPerDegreeLat = 111_195.0
        let metersPerDegreeLon = metersPerDegreeLat * cos(latitude * .pi / 180)
        func xy(_ p: GeoPoint) -> (Double, Double) {
            ((p.longitude - longitude) * metersPerDegreeLon, (p.latitude - latitude) * metersPerDegreeLat)
        }
        var best = Double.infinity
        var a = xy(first)
        for point in points.dropFirst() {
            let b = xy(point)
            let dx = b.0 - a.0, dy = b.1 - a.1
            let lengthSquared = dx * dx + dy * dy
            // Closest point on segment a-b to the origin (us).
            let t = lengthSquared > 0 ? max(0, min(1, -(a.0 * dx + a.1 * dy) / lengthSquared)) : 0
            let x = a.0 + t * dx, y = a.1 + t * dy
            best = min(best, (x * x + y * y).squareRoot())
            a = b
        }
        return best
    }
}

/// A latitude/longitude rectangle (no antimeridian handling; Seattle doesn't need it).
public struct GeoBox: Hashable, Sendable {
    public var minLatitude: Double
    public var minLongitude: Double
    public var maxLatitude: Double
    public var maxLongitude: Double

    public init(minLatitude: Double, minLongitude: Double, maxLatitude: Double, maxLongitude: Double) {
        self.minLatitude = minLatitude
        self.minLongitude = minLongitude
        self.maxLatitude = maxLatitude
        self.maxLongitude = maxLongitude
    }

    /// The box around a map view: its center and how many degrees it spans.
    public init(center: GeoPoint, latitudeSpan: Double, longitudeSpan: Double) {
        self.init(
            minLatitude: center.latitude - latitudeSpan / 2,
            minLongitude: center.longitude - longitudeSpan / 2,
            maxLatitude: center.latitude + latitudeSpan / 2,
            maxLongitude: center.longitude + longitudeSpan / 2
        )
    }

    /// The smallest box holding every point; nil for none.
    public init?(around points: [GeoPoint]) {
        guard let first = points.first else { return nil }
        self.init(minLatitude: first.latitude, minLongitude: first.longitude, maxLatitude: first.latitude, maxLongitude: first.longitude)
        for point in points.dropFirst() {
            minLatitude = min(minLatitude, point.latitude)
            minLongitude = min(minLongitude, point.longitude)
            maxLatitude = max(maxLatitude, point.latitude)
            maxLongitude = max(maxLongitude, point.longitude)
        }
    }

    public var center: GeoPoint {
        GeoPoint(latitude: (minLatitude + maxLatitude) / 2, longitude: (minLongitude + maxLongitude) / 2)
    }

    public var latitudeSpan: Double { maxLatitude - minLatitude }
    public var longitudeSpan: Double { maxLongitude - minLongitude }

    public func contains(_ point: GeoPoint) -> Bool {
        (minLatitude...maxLatitude).contains(point.latitude) && (minLongitude...maxLongitude).contains(point.longitude)
    }

    public func intersects(_ other: GeoBox) -> Bool {
        minLatitude <= other.maxLatitude && other.minLatitude <= maxLatitude
            && minLongitude <= other.maxLongitude && other.minLongitude <= maxLongitude
    }

    public func union(_ other: GeoBox) -> GeoBox {
        GeoBox(
            minLatitude: min(minLatitude, other.minLatitude),
            minLongitude: min(minLongitude, other.minLongitude),
            maxLatitude: max(maxLatitude, other.maxLatitude),
            maxLongitude: max(maxLongitude, other.maxLongitude)
        )
    }

    /// Grown on every side by `fraction` of its span, so a map shows a little around a route.
    public func padded(by fraction: Double) -> GeoBox {
        let lat = max(latitudeSpan * fraction, 0.002)
        let lon = max(longitudeSpan * fraction, 0.003)
        return GeoBox(minLatitude: minLatitude - lat, minLongitude: minLongitude - lon, maxLatitude: maxLatitude + lat, maxLongitude: maxLongitude + lon)
    }
}

extension Polyline {
    /// Decoded as `GeoPoint`s; nil if the string is malformed.
    static func points(_ encoded: String) -> [GeoPoint]? {
        decode(encoded)?.map { GeoPoint(latitude: $0.latitude, longitude: $0.longitude) }
    }
}

func lineLength(_ points: [GeoPoint]) -> Double {
    zip(points, points.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
}
