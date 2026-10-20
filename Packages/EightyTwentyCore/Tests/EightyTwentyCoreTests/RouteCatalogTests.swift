import XCTest
@testable import EightyTwentyCore

final class RouteCatalogTests: XCTestCase {
    /// Green Lake-ish origin; offsets in meters.
    let origin = GeoPoint(latitude: 47.68, longitude: -122.33)

    func point(north: Double, east: Double) -> GeoPoint {
        GeoPoint(
            latitude: origin.latitude + north / 111_195,
            longitude: origin.longitude + east / (111_195 * cos(origin.latitude * .pi / 180))
        )
    }

    func encoded(_ points: [GeoPoint]) -> String {
        Polyline.encode(points.map { (latitude: $0.latitude, longitude: $0.longitude) })
    }

    /// An asphalt trail running east from the origin, a dirt one 1 km north, and a
    /// mostly-dirt loop around the dirt trail.
    func sampleJSON() -> Data {
        let asphalt = encoded([point(north: 0, east: 0), point(north: 0, east: 500)])
        let dirt = encoded([point(north: 1000, east: 0), point(north: 1000, east: 200)])
        let loop = encoded([point(north: 950, east: -50), point(north: 1050, east: -50), point(north: 1050, east: 250), point(north: 950, east: -50)])
        let json = """
        {"attribution": "OSM",
         "trails": [["asphalt", 1, "Lake Path", "\(asphalt)"], ["dirt", 0, null, "\(dirt)"], ["gravel", 1, null, "?"]],
         "routes": [{"id": "woods-loop", "name": "Woods Loop", "area": "Park", "kind": "loop", "meters": 800,
                     "surfaces": {"dirt": 0.6, "asphalt": 0.4, "mystery": 0.0}, "elevation": "rolling",
                     "start": [\(point(north: 950, east: -50).latitude), \(point(north: 950, east: -50).longitude)],
                     "startLabel": "Lot", "notes": "Shady.", "lines": ["\(loop)"]}]}
        """
        return Data(json.utf8)
    }

    func testDecodesTrailsAndRoutes() throws {
        let catalog = try RouteCatalog(json: sampleJSON())
        // The one-point gravel line ("?") is dropped rather than drawn as nothing.
        XCTAssertEqual(catalog.trails.map(\.surface), [.asphalt, .dirt])
        XCTAssertEqual(catalog.trails[0].name, "Lake Path")
        XCTAssertTrue(catalog.trails[0].surfaceMapped)
        XCTAssertFalse(catalog.trails[1].surfaceMapped)
        XCTAssertEqual(catalog.trails[0].length, 500, accuracy: 2)
        XCTAssertEqual(catalog.mappedLength(named: "Lake Path"), 500, accuracy: 2)
        XCTAssertFalse(catalog.trails[0].isRunningTrack)
        let oval = TrailLine(id: 9, name: nil, surface: .track, surfaceMapped: false, points: [
            point(north: 0, east: 0), point(north: 0, east: 100), point(north: 70, east: 100), point(north: 70, east: 0), point(north: 0, east: 0),
        ])
        XCTAssertTrue(oval.isRunningTrack)

        let route = try XCTUnwrap(catalog.route(id: "woods-loop"))
        XCTAssertEqual(route.kind, .loop)
        XCTAssertEqual(route.elevation, .rolling)
        XCTAssertEqual(route.mainSurface, .dirt)
        XCTAssertEqual(route.surfaceBreakdown.map(\.surface), [.dirt, .asphalt])
        XCTAssertEqual(route.lines.count, 1)
        XCTAssertEqual(catalog.attribution, "OSM")
    }

    func testRouteShowsWhenPickedSurfacesAreAtLeastHalf() throws {
        let route = try XCTUnwrap(RouteCatalog(json: sampleJSON()).routes.first)
        XCTAssertTrue(route.matches([.dirt]))
        XCTAssertTrue(route.matches([.dirt, .gravel, .track]))
        XCTAssertFalse(route.matches([.asphalt]))
        XCTAssertFalse(route.matches([.asphalt, .concrete]))
        XCTAssertTrue(route.matches(Set(RunSurface.allCases)))
        XCTAssertEqual(route.share(of: [.asphalt, .dirt]), 1, accuracy: 1e-9)
    }

    func testTrailsInViewFilterBySurfaceAndKeepTheLongest() throws {
        let catalog = try RouteCatalog(json: sampleJSON())
        let all = Set(RunSurface.allCases)
        let around = GeoBox(center: point(north: 500, east: 250), latitudeSpan: 0.03, longitudeSpan: 0.03)
        XCTAssertEqual(catalog.trails(in: around, surfaces: all, limit: 10).count, 2)
        XCTAssertEqual(catalog.trails(in: around, surfaces: [.dirt], limit: 10).map(\.surface), [.dirt])
        // Past the limit, the 500 m asphalt line beats the 200 m dirt one.
        XCTAssertEqual(catalog.trails(in: around, surfaces: all, limit: 1).map(\.surface), [.asphalt])
        // Somewhere else entirely.
        let away = GeoBox(center: GeoPoint(latitude: 47.5, longitude: -122.2), latitudeSpan: 0.01, longitudeSpan: 0.01)
        XCTAssertTrue(catalog.trails(in: away, surfaces: all, limit: 10).isEmpty)
    }

    func testNearbyRoutesSortedByDistanceAndFiltered() throws {
        let catalog = try RouteCatalog(json: sampleJSON())
        let near = catalog.routes(near: point(north: 0, east: 0), surfaces: Set(RunSurface.allCases))
        XCTAssertEqual(near.count, 1)
        // The loop's nearest edge is 950 m north.
        XCTAssertEqual(near[0].distance, 950, accuracy: 15)
        XCTAssertTrue(catalog.routes(near: origin, surfaces: [.concrete]).isEmpty)
    }

    func testTapPrefersARouteThenAPathAmongWhatsDrawn() throws {
        let catalog = try RouteCatalog(json: sampleJSON())
        func hit(_ p: GeoPoint, trails: [TrailLine]? = nil) -> RouteCatalog.Hit? {
            RouteCatalog.hit(at: p, tolerance: 30, routes: catalog.routes, trails: trails ?? catalog.trails)
        }
        // On the loop's edge, which also runs near the dirt trail: the route wins.
        guard case .route(let route)? = hit(point(north: 1040, east: 100)) else { return XCTFail("expected the loop") }
        XCTAssertEqual(route.id, "woods-loop")
        // Next to the asphalt trail.
        guard case .trail(let trail)? = hit(point(north: 10, east: 250)) else { return XCTFail("expected the asphalt trail") }
        XCTAssertEqual(trail.name, "Lake Path")
        // Not drawn (filtered out, or paths hidden), so not tappable.
        XCTAssertNil(hit(point(north: 10, east: 250), trails: []))
        XCTAssertNil(hit(point(north: 500, east: 250)))
    }

    func testDistanceToLine() {
        let line = [point(north: 0, east: 0), point(north: 0, east: 1000)]
        XCTAssertEqual(point(north: 50, east: 500).distance(toLine: line), 50, accuracy: 0.5)
        // Past the end, it's the distance to the end point.
        XCTAssertEqual(point(north: 0, east: 1300).distance(toLine: line), 300, accuracy: 1)
        XCTAssertEqual(point(north: 30, east: 0).distance(toLine: [point(north: 0, east: 0)]), 30, accuracy: 0.5)
        XCTAssertEqual(origin.distance(toLine: []), .infinity)
    }

    func testBoxes() {
        let box = GeoBox(around: [point(north: 0, east: 0), point(north: 100, east: 200)])!
        XCTAssertTrue(box.contains(point(north: 50, east: 100)))
        XCTAssertFalse(box.contains(point(north: 150, east: 100)))
        XCTAssertTrue(box.intersects(GeoBox(center: point(north: 100, east: 200), latitudeSpan: 0.001, longitudeSpan: 0.001)))
        XCTAssertFalse(box.intersects(GeoBox(center: point(north: 1000, east: 0), latitudeSpan: 0.001, longitudeSpan: 0.001)))
        XCTAssertNil(GeoBox(around: []))
        XCTAssertGreaterThan(box.padded(by: 0.2).latitudeSpan, box.latitudeSpan)
    }

    func testSurfaceFilterIsStoredAsText() {
        XCTAssertEqual(RunSurface.set(from: ""), Set(RunSurface.allCases))
        XCTAssertEqual(RunSurface.set(from: "nonsense"), Set(RunSurface.allCases))
        XCTAssertEqual(RunSurface.set(from: "dirt,gravel"), [.dirt, .gravel])
        XCTAssertEqual(RunSurface.stored([.gravel, .dirt]), "gravel,dirt")
        XCTAssertEqual(Set(RunSurface.allCases.filter(\.isSoft)), [.gravel, .dirt, .track])
    }

    func testSurfaceChipTaps() {
        let all = Set(RunSurface.allCases)
        XCTAssertEqual(RunSurface.toggled(.dirt, in: all), [.dirt])
        XCTAssertEqual(RunSurface.toggled(.gravel, in: [.dirt]), [.dirt, .gravel])
        XCTAssertEqual(RunSurface.toggled(.dirt, in: [.dirt, .gravel]), [.gravel])
        XCTAssertEqual(RunSurface.toggled(.dirt, in: [.dirt]), all)
    }

    func testFormatting() {
        XCTAssertEqual(RouteFormat.length(4506, usesMiles: true), "2.8 mi")
        XCTAssertEqual(RouteFormat.length(4506, usesMiles: false), "4.5 km")
        XCTAssertEqual(RouteFormat.length(30_000, usesMiles: true), "19 mi")
        XCTAssertEqual(RouteFormat.away(60, usesMiles: true), "You're here")
        XCTAssertEqual(RouteFormat.away(805, usesMiles: true), "0.5 mi away")
    }

    // MARK: The bundled Seattle data

    func testBundledSeattleCatalogIsSane() throws {
        let catalog = try RouteCatalog.loadSeattle()
        let region = GeoBox(minLatitude: 47.3, minLongitude: -122.55, maxLatitude: 47.9, maxLongitude: -121.9)

        XCTAssertGreaterThan(catalog.trails.count, 5000)
        XCTAssertTrue(catalog.trails.allSatisfy { region.contains($0.box.center) })
        for surface in RunSurface.allCases {
            XCTAssertTrue(catalog.trails.contains { $0.surface == surface }, "no \(surface) trails")
        }
        XCTAssertTrue(catalog.attribution.contains("OpenStreetMap"))

        XCTAssertGreaterThan(catalog.routes.count, 50)
        XCTAssertEqual(Set(catalog.routes.map(\.id)).count, catalog.routes.count, "duplicate route ids")
        for route in catalog.routes {
            XCTAssertEqual(route.surfaces.values.reduce(0, +), 1, accuracy: 0.02, route.id)
            XCTAssertFalse(route.lines.isEmpty, route.id)
            XCTAssertTrue(region.contains(route.start), route.id)
            XCTAssertGreaterThan(route.length, 100, route.id)
            // The start pin sits on (or right by) the drawn route.
            XCTAssertLessThan(route.lines.map { route.start.distance(toLine: $0) }.min() ?? .infinity, 400, route.id)
            XCTAssertFalse(route.notes.isEmpty, route.id)
            XCTAssertFalse((route.notes + route.name + (route.access ?? "")).contains("\u{2014}"), "em-dash in \(route.id)")
        }
        // Somewhere to run on every surface, and tracks among the routes.
        for surface in RunSurface.allCases {
            XCTAssertTrue(catalog.routes.contains { $0.matches([surface]) }, "no route mostly on \(surface)")
        }
        XCTAssertGreaterThan(catalog.routes.filter { $0.kind == .track }.count, 10)
    }

    func testEverySeattleNeighborhoodHasARouteWithinTwoMiles() throws {
        let catalog = try RouteCatalog.loadSeattle()
        let neighborhoods: [(String, Double, Double)] = [
            ("Ballard", 47.6687, -122.3847), ("Green Lake", 47.6795, -122.3255), ("U District", 47.6614, -122.3132),
            ("Lake City", 47.7190, -122.2950), ("Northgate", 47.7060, -122.3250), ("Capitol Hill", 47.6253, -122.3222),
            ("Downtown", 47.6080, -122.3352), ("Queen Anne", 47.6370, -122.3570), ("Magnolia", 47.6505, -122.3990),
            ("West Seattle Junction", 47.5612, -122.3868), ("Beacon Hill", 47.5680, -122.3080),
            ("Columbia City", 47.5596, -122.2864), ("Rainier Beach", 47.5120, -122.2620), ("Georgetown", 47.5470, -122.3210),
            ("Bellevue", 47.6101, -122.2015), ("Kirkland", 47.6769, -122.2060), ("Redmond", 47.6740, -122.1215),
            ("Shoreline", 47.7557, -122.3415), ("Mercer Island", 47.5707, -122.2221), ("Renton", 47.4829, -122.2171),
        ]
        for (name, lat, lon) in neighborhoods {
            let nearest = catalog.routes(near: GeoPoint(latitude: lat, longitude: lon), surfaces: Set(RunSurface.allCases)).first
            XCTAssertLessThan(nearest?.distance ?? .infinity, 2 * RunningPlan.metersPerMile, name)
        }
    }
}
