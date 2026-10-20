import Foundation

/// One stretch of path from OpenStreetMap, drawn on the run map in its surface's color.
public struct TrailLine: Identifiable, Sendable {
    public let id: Int
    public let name: String?
    public let surface: RunSurface
    /// False when OpenStreetMap doesn't say what it's made of (or only says "paved"),
    /// so `surface` is a best guess from the kind of path.
    public let surfaceMapped: Bool
    public let points: [GeoPoint]
    public let box: GeoBox
    /// Meters.
    public let length: Double

    public init(id: Int, name: String?, surface: RunSurface, surfaceMapped: Bool, points: [GeoPoint]) {
        self.id = id
        self.name = name
        self.surface = surface
        self.surfaceMapped = surfaceMapped
        self.points = points
        box = GeoBox(around: points) ?? GeoBox(minLatitude: 0, minLongitude: 0, maxLatitude: 0, maxLongitude: 0)
        length = lineLength(points)
    }

    /// A running track's oval (a closed loop of track size), rather than a path.
    public var isRunningTrack: Bool {
        guard let first = points.first, let last = points.last else { return false }
        return first.distance(to: last) < 5 && (250...700).contains(length)
    }
}

/// A researched route: a loop, a trail, a park's trail web or a running track.
public struct RunRoute: Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case loop
        case outAndBack = "out-and-back"
        case pointToPoint = "point-to-point"
        case network
        case track

        public var title: String {
            switch self {
            case .loop: return "Loop"
            case .outAndBack: return "Out and back"
            case .pointToPoint: return "One way"
            case .network: return "Trail network"
            case .track: return "Track"
            }
        }
    }

    /// Whether the public can use it: for tracks, which mostly belong to schools.
    public enum Availability: String, Codable, Sendable {
        case open
        case afterHours = "after-hours"
        case limited
        case unknown

        public var title: String {
            switch self {
            case .open: return "Open to the public"
            case .afterHours: return "Outside school hours"
            case .limited: return "Limited access"
            case .unknown: return "Access not confirmed"
            }
        }
    }

    public enum Elevation: String, Codable, Sendable {
        case flat, rolling, hilly

        public var title: String { rawValue.capitalized }
    }

    public let id: String
    public let name: String
    /// Neighborhood or city.
    public let area: String
    public let kind: Kind
    /// Meters for the usual run: once around a loop, the whole trail, one lap of a track.
    public let length: Double
    /// Share of the route on each surface; adds up to 1.
    public let surfaces: [RunSurface: Double]
    public let elevation: Elevation
    public let start: GeoPoint
    public let startLabel: String
    public let notes: String
    /// Who can use it and when (tracks at schools).
    public let access: String?
    public let availability: Availability?
    /// The route as drawn; several pieces for networks and trails with branches.
    public let lines: [[GeoPoint]]
    public let box: GeoBox

    public init(
        id: String, name: String, area: String, kind: Kind, length: Double,
        surfaces: [RunSurface: Double], elevation: Elevation, start: GeoPoint, startLabel: String,
        notes: String, access: String? = nil, availability: Availability? = nil, lines: [[GeoPoint]]
    ) {
        self.id = id
        self.name = name
        self.area = area
        self.kind = kind
        self.length = length
        self.surfaces = surfaces
        self.elevation = elevation
        self.start = start
        self.startLabel = startLabel
        self.notes = notes
        self.access = access
        self.availability = availability
        self.lines = lines
        box = lines.compactMap { GeoBox(around: $0) }.reduce(nil as GeoBox?) { $0?.union($1) ?? $1 }
            ?? GeoBox(around: [start])!
    }

    /// The surface it's mostly on.
    public var mainSurface: RunSurface {
        RunSurface.allCases.max { (surfaces[$0] ?? 0) < (surfaces[$1] ?? 0) } ?? .asphalt
    }

    /// Surfaces with their share, biggest first, leaving out slivers under 5%.
    public var surfaceBreakdown: [(surface: RunSurface, share: Double)] {
        RunSurface.allCases
            .compactMap { s in surfaces[s].flatMap { $0 >= 0.05 ? (s, $0) : nil } }
            .sorted { $0.1 > $1.1 }
    }

    /// Share of the route on any of these surfaces.
    public func share(of picked: Set<RunSurface>) -> Double {
        picked.reduce(0) { $0 + (surfaces[$1] ?? 0) }
    }

    /// Shown when at least half the route is on surfaces you picked.
    public func matches(_ picked: Set<RunSurface>) -> Bool {
        picked.count == RunSurface.allCases.count || share(of: picked) >= 0.5
    }

    /// Meters from `point` to the nearest bit of the route.
    public func distance(from point: GeoPoint) -> Double {
        lines.reduce(point.distance(to: start)) { min($0, point.distance(toLine: $1)) }
    }
}

/// Every path and named route the run map knows about, and the questions it asks of them.
public struct RouteCatalog: Sendable {
    public let trails: [TrailLine]
    public let routes: [RunRoute]
    /// Credit line for the map data (OpenStreetMap's license requires it).
    public let attribution: String
    private let lengthByName: [String: Double]

    public static let empty = RouteCatalog(trails: [], routes: [], attribution: "")

    public init(trails: [TrailLine], routes: [RunRoute], attribution: String) {
        self.trails = trails
        self.routes = routes
        self.attribution = attribution
        lengthByName = trails.reduce(into: [:]) { totals, line in
            if let name = line.name { totals[name, default: 0] += line.length }
        }
    }

    /// The bundled Seattle-area data (`seattle-routes.json`, built by `tools/routes`).
    public static func loadSeattle() throws -> RouteCatalog {
        guard let url = Bundle.module.url(forResource: "seattle-routes", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try RouteCatalog(json: Data(contentsOf: url))
    }

    public init(json: Data) throws {
        let file = try JSONDecoder().decode(CatalogFile.self, from: json)
        var trails: [TrailLine] = []
        trails.reserveCapacity(file.trails.count)
        for (index, row) in file.trails.enumerated() {
            guard let points = Polyline.points(row.line), points.count > 1 else { continue }
            trails.append(TrailLine(id: index, name: row.name, surface: row.surface, surfaceMapped: row.mapped, points: points))
        }
        let routes = file.routes.map { r in
            RunRoute(
                id: r.id, name: r.name, area: r.area, kind: r.kind, length: r.meters,
                surfaces: Dictionary(uniqueKeysWithValues: r.surfaces.compactMap { key, share in
                    RunSurface(rawValue: key).map { ($0, share) }
                }),
                elevation: r.elevation,
                start: GeoPoint(latitude: r.start[0], longitude: r.start[1]),
                startLabel: r.startLabel, notes: r.notes, access: r.access, availability: r.availability,
                lines: r.lines.compactMap(Polyline.points)
            )
        }
        self.init(trails: trails, routes: routes, attribution: file.attribution)
    }

    /// Paths to draw in this part of the map. Past `limit`, the longest win, so a
    /// zoomed-out map shows the big trails rather than a random scatter of stubs.
    public func trails(in box: GeoBox, surfaces: Set<RunSurface>, limit: Int) -> [TrailLine] {
        let visible = trails.filter { surfaces.contains($0.surface) && $0.box.intersects(box) }
        guard visible.count > limit else { return visible }
        return Array(visible.sorted { $0.length > $1.length }.prefix(limit))
    }

    /// Named routes in this part of the map that are mostly on the picked surfaces.
    public func routes(in box: GeoBox, surfaces: Set<RunSurface>) -> [RunRoute] {
        routes.filter { $0.box.intersects(box) && $0.matches(surfaces) }
    }

    /// Named routes mostly on the picked surfaces, nearest first, with meters away.
    public func routes(near point: GeoPoint, surfaces: Set<RunSurface>) -> [(route: RunRoute, distance: Double)] {
        routes.filter { $0.matches(surfaces) }
            .map { ($0, $0.distance(from: point)) }
            .sorted { $0.1 < $1.1 }
    }

    public func route(id: String) -> RunRoute? {
        routes.first { $0.id == id }
    }

    /// Total mapped meters of paths with this name (all of the Burke-Gilman, not just the tapped piece).
    public func mappedLength(named name: String) -> Double {
        lengthByName[name] ?? 0
    }

    public enum Hit: Sendable {
        case route(RunRoute)
        case trail(TrailLine)
    }

    /// What a tap at `point` landed on among what's drawn, within `tolerance` meters. A
    /// named route wins over a plain path when both are close, since it has more to say.
    public static func hit(at point: GeoPoint, tolerance: Double, routes: [RunRoute], trails: [TrailLine]) -> Hit? {
        let near = GeoBox(center: point, latitudeSpan: tolerance / 55_000, longitudeSpan: tolerance / 37_000)
        let route = routes
            .filter { $0.box.intersects(near) }
            .map { ($0, $0.distance(from: point)) }
            .filter { $0.1 <= tolerance }
            .min { $0.1 < $1.1 }
        if let route { return .route(route.0) }
        let trail = trails
            .filter { $0.box.intersects(near) }
            .map { ($0, point.distance(toLine: $0.points)) }
            .filter { $0.1 <= tolerance }
            .min { $0.1 < $1.1 }
        return trail.map { .trail($0.0) }
    }
}

/// "2.8 mi", "0.4 mi away", "here".
public enum RouteFormat {
    public static func length(_ meters: Double, usesMiles: Bool) -> String {
        let value = meters / (usesMiles ? RunningPlan.metersPerMile : 1000)
        let unit = usesMiles ? "mi" : "km"
        if value >= 10 { return "\(Int(value.rounded())) \(unit)" }
        return String(format: "%.1f", value) + " \(unit)"
    }

    public static func away(_ meters: Double, usesMiles: Bool) -> String {
        meters < 100 ? "You're here" : "\(length(meters, usesMiles: usesMiles)) away"
    }
}

// MARK: File format

/// `trails` rows are `[surface, mapped, name, polyline]` arrays to keep the file small.
private struct CatalogFile: Decodable {
    struct TrailRow: Decodable {
        let surface: RunSurface
        let mapped: Bool
        let name: String?
        let line: String

        init(from decoder: Decoder) throws {
            var row = try decoder.unkeyedContainer()
            surface = try row.decode(RunSurface.self)
            mapped = try row.decode(Int.self) == 1
            name = try row.decodeNil() ? nil : try row.decode(String.self)
            line = try row.decode(String.self)
        }
    }

    struct RouteRow: Decodable {
        let id: String
        let name: String
        let area: String
        let kind: RunRoute.Kind
        let meters: Double
        let surfaces: [String: Double]
        let elevation: RunRoute.Elevation
        let start: [Double]
        let startLabel: String
        let notes: String
        let access: String?
        let availability: RunRoute.Availability?
        let lines: [String]
    }

    let attribution: String
    let trails: [TrailRow]
    let routes: [RouteRow]
}
