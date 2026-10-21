import SwiftUI
import MapKit
import EightyTwentyCore

/// The Seattle-area paths and researched routes (`RouteCatalog`), loaded once off the
/// main thread the first time the run map opens.
@MainActor
@Observable
final class RouteLibrary {
    static let shared = RouteLibrary()

    private(set) var catalog: RouteCatalog = .empty
    private var loading: Task<Void, Never>?

    func load() async {
        if loading == nil {
            loading = Task {
                let started = Date()
                let result = await Task.detached(priority: .userInitiated) {
                    Result { try RouteCatalog.loadSeattle() }
                }.value
                switch result {
                case .success(let catalog):
                    self.catalog = catalog
                    let ms = Int(Date().timeIntervalSince(started) * 1000)
                    Log.app.info("Route map loaded: \(catalog.trails.count) paths, \(catalog.routes.count) routes in \(ms) ms")
                case .failure(let error):
                    Log.app.error("Route map data failed to load: \(error.localizedDescription)")
                }
            }
        }
        await loading?.value
    }
}

extension RunSurface {
    var color: Color {
        switch self {
        case .asphalt: return Color(red: 0.15, green: 0.39, blue: 0.92)
        case .concrete: return Color(red: 0.49, green: 0.23, blue: 0.93)
        case .gravel: return Color(red: 0.85, green: 0.62, blue: 0.05)
        case .dirt: return Color(red: 0.62, green: 0.36, blue: 0.16)
        case .boardwalk: return Color(red: 0.05, green: 0.58, blue: 0.53)
        case .track: return Color(red: 0.86, green: 0.15, blue: 0.47)
        }
    }
}

extension RunRoute.Availability {
    var color: Color {
        switch self {
        case .open: return .green
        case .afterHours: return .blue
        case .limited: return .orange
        case .unknown: return .gray
        }
    }

    var systemImage: String {
        switch self {
        case .open: return "checkmark.circle.fill"
        case .afterHours: return "clock.fill"
        case .limited: return "key.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }
}

/// "Outside school hours" as a small colored tag.
struct AvailabilityTag: View {
    let availability: RunRoute.Availability

    var body: some View {
        Label(availability.title, systemImage: availability.systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(availability.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(availability.color.opacity(0.15), in: Capsule())
    }
}

extension GeoPoint {
    init(_ coordinate: CLLocationCoordinate2D) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

extension GeoBox {
    init(_ region: MKCoordinateRegion) {
        self.init(center: GeoPoint(region.center), latitudeSpan: region.span.latitudeDelta, longitudeSpan: region.span.longitudeDelta)
    }

    var region: MKCoordinateRegion {
        MKCoordinateRegion(
            center: center.coordinate,
            span: MKCoordinateSpan(latitudeDelta: latitudeSpan, longitudeDelta: longitudeSpan)
        )
    }
}

/// What's picked on the run map.
enum RouteSelection {
    case route(RunRoute)
    case trail(TrailLine)
}

/// Surface filter chips across the top of the run map. With everything on they double
/// as the color key; tap one to show only that surface. A filter has to be obvious, since
/// it hides routes and tracks too: off chips are dimmed with a hollow dot, and "Show all"
/// stands out at the front until everything's back on.
struct SurfaceFilterBar: View {
    @Binding var stored: String
    let showRoutes: () -> Void

    private var picked: Set<RunSurface> { RunSurface.set(from: stored) }
    private var filtered: Bool { picked.count < RunSurface.allCases.count }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Button(action: showRoutes) {
                    Label("Routes", systemImage: "list.bullet")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.regularMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                allChip
                ForEach(RunSurface.allCases) { surface in
                    chip(surface)
                }
            }
            .padding(.horizontal, 12)
        }
    }

    private var allChip: some View {
        Button {
            stored = ""
        } label: {
            Label(filtered ? "Show all" : "All", systemImage: filtered ? "xmark.circle.fill" : "checkmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(filtered ? .white : .primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(filtered ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.regularMaterial), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(filtered ? "Show all surfaces" : "All surfaces showing")
    }

    private func chip(_ surface: RunSurface) -> some View {
        let on = picked.contains(surface)
        return Button {
            stored = RunSurface.stored(RunSurface.toggled(surface, in: picked))
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .strokeBorder(on ? Color.white : surface.color, lineWidth: 1.5)
                    .background(Circle().fill(on ? Color.white : Color.clear))
                    .frame(width: 8, height: 8)
                Text(surface.title)
                    .strikethrough(!on)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(on ? .white : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(on ? AnyShapeStyle(surface.color) : AnyShapeStyle(.regularMaterial), in: Capsule())
            .opacity(on ? 1 : 0.7)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(surface.title)
        .accessibilityValue(on ? "Showing" : "Hidden")
    }
}

/// A route's surfaces as one bar, in proportion.
struct SurfaceBar: View {
    let route: RunRoute

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 1) {
                ForEach(route.surfaceBreakdown, id: \.surface) { part in
                    Rectangle()
                        .fill(part.surface.color)
                        .frame(width: max(2, proxy.size.width * part.share - 1))
                }
            }
        }
        .frame(height: 6)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }
}

/// "70% gravel · 30% asphalt".
func surfaceSummary(_ route: RunRoute) -> String {
    route.surfaceBreakdown
        .map { "\(Int(($0.share * 100).rounded()))% \($0.surface.title.lowercased())" }
        .joined(separator: " · ")
}

/// The card at the bottom of the run map for whatever you tapped.
struct RouteCard: View {
    let selection: RouteSelection
    let catalog: RouteCatalog
    let origin: GeoPoint?
    let usesMiles: Bool
    @Binding var followedRouteID: String
    let close: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch selection {
            case .route(let route): routeBody(route)
            case .trail(let trail): trailBody(trail)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(alignment: .topTrailing) {
            Button(action: close) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .accessibilityLabel("Close")
        }
    }

    @ViewBuilder
    private func routeBody(_ route: RunRoute) -> some View {
        Text(route.name).font(.headline).padding(.trailing, 32)
        Text(facts(route)).font(.subheadline).foregroundStyle(.secondary)
        if let availability = route.availability {
            AvailabilityTag(availability: availability)
        }
        SurfaceBar(route: route)
        Text(surfaceSummary(route)).font(.caption).foregroundStyle(.secondary)
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(route.notes)
                if let access = route.access {
                    Label(access, systemImage: "clock")
                }
                Text("Start: \(route.startLabel)").foregroundStyle(.secondary)
            }
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 110)
        HStack {
            let following = followedRouteID == route.id
            Button {
                followedRouteID = following ? "" : route.id
            } label: {
                Label(following ? "On your map" : "Keep on map", systemImage: following ? "checkmark" : "pin")
            }
            .buttonStyle(.borderedProminent)
            .tint(route.mainSurface.color)
            Button {
                if let url = URL(string: "https://maps.apple.com/?daddr=\(route.start.latitude),\(route.start.longitude)&dirflg=w") {
                    openURL(url)
                }
            } label: {
                Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond")
            }
            .buttonStyle(.bordered)
        }
        .font(.subheadline)
    }

    @ViewBuilder
    private func trailBody(_ trail: TrailLine) -> some View {
        Text(trail.name ?? "Unnamed path").font(.headline).padding(.trailing, 32)
        HStack(spacing: 6) {
            Circle().fill(trail.surface.color).frame(width: 10, height: 10)
            Text(trail.surface.title).font(.subheadline.weight(.semibold))
        }
        Text(trail.surfaceMapped ? trail.surface.detail : "Surface isn't mapped here. Most paths like this nearby are \(trail.surface.title.lowercased()).")
            .font(.caption)
            .foregroundStyle(.secondary)
        if trail.isRunningTrack {
            Text("Running track, \(RouteFormat.length(trail.length, usesMiles: usesMiles)) around the outside. Most belong to schools or colleges, so check the posted hours before you go.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else if let name = trail.name {
            Text("\(RouteFormat.length(catalog.mappedLength(named: name), usesMiles: usesMiles)) of \(name) mapped around Seattle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            Text("This stretch: \(RouteFormat.length(trail.length, usesMiles: usesMiles))")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        Text(catalog.attribution).font(.caption2).foregroundStyle(.tertiary)
    }

    private func facts(_ route: RunRoute) -> String {
        var parts = [route.area, RouteFormat.length(route.length, usesMiles: usesMiles) + (route.kind == .track ? " lap" : ""), route.kind.title]
        if route.kind != .track { parts.append(route.elevation.title) }
        if let origin { parts.append(RouteFormat.away(route.distance(from: origin), usesMiles: usesMiles)) }
        return parts.joined(separator: " · ")
    }
}

/// "Routes near you": the researched routes, nearest first, filtered by surface and kind.
struct NearbyRoutesView: View {
    let catalog: RouteCatalog
    let origin: GeoPoint
    let surfaces: Set<RunSurface>
    let usesMiles: Bool
    @Binding var showTrails: Bool
    let pick: (RunRoute) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var kind = KindFilter.all

    enum KindFilter: String, CaseIterable, Identifiable {
        case all = "All", loops = "Loops", trails = "Trails", tracks = "Tracks"
        var id: String { rawValue }

        func includes(_ kind: RunRoute.Kind) -> Bool {
            switch self {
            case .all: return true
            case .loops: return kind == .loop
            case .trails: return kind == .outAndBack || kind == .pointToPoint || kind == .network
            case .tracks: return kind == .track
            }
        }
    }

    private var nearby: [(route: RunRoute, distance: Double)] {
        Array(catalog.routes(near: origin, surfaces: surfaces).filter { kind.includes($0.route.kind) }.prefix(50))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Kind", selection: $kind) {
                        ForEach(KindFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Show every path on the map", isOn: $showTrails)
                } footer: {
                    if surfaces.count < RunSurface.allCases.count {
                        Text("Routes at least half on \(RunSurface.allCases.filter(surfaces.contains).map { $0.title.lowercased() }.joined(separator: " or ")). Change it with the chips on the map.")
                    }
                }
                Section {
                    if nearby.isEmpty {
                        Text("Nothing nearby matches. Turn on more surfaces with the chips on the map.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(nearby, id: \.route.id) { item in
                        Button {
                            pick(item.route)
                            dismiss()
                        } label: {
                            row(item.route, distance: item.distance)
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text(catalog.attribution)
                }
            }
            .navigationTitle("Routes near you")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func row(_ route: RunRoute, distance: Double) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(route.name).font(.headline)
                Spacer()
                Text(RouteFormat.away(distance, usesMiles: usesMiles))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("\(route.area) · \(RouteFormat.length(route.length, usesMiles: usesMiles))\(route.kind == .track ? " lap" : "") · \(route.kind.title)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let availability = route.availability {
                AvailabilityTag(availability: availability)
            }
            SurfaceBar(route: route)
            Text(surfaceSummary(route)).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
