import SwiftUI
import UIKit
import MapKit
import EightyTwentyCore

/// Record a run or walk like Strava: Start, Pause/Resume, Finish (hold), then Save or Discard.
/// Before you start, the map shows where to run: every path colored by surface and the
/// researched routes and tracks (`RouteCatalog`), filtered by the surface chips.
struct RunView: View {
    /// What to record when nothing is in progress. Nil means whatever you picked last.
    var activity: ActivityKind? = nil

    @Environment(AppModel.self) private var model
    @AppStorage(PrefKey.usesMiles) private var usesMiles = Units.defaultUsesMiles
    @AppStorage(PrefKey.recordActivity) private var lastActivity = ActivityKind.run.rawValue
    @AppStorage(PrefKey.cueEvery) private var cueEvery = 1.0
    @AppStorage(PrefKey.cueSpeak) private var cueSpeak = true
    @AppStorage(PrefKey.routeSurfaces) private var surfacesStored = ""
    @AppStorage(PrefKey.showTrails) private var showTrails = true
    @AppStorage(PrefKey.followedRoute) private var followedRouteID = ""
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var library = RouteLibrary.shared
    @State private var mapBox: GeoBox?
    @State private var visibleTrails: [TrailLine] = []
    @State private var visibleRoutes: [RunRoute] = []
    @State private var selection: RouteSelection?
    /// Where you were when you opened the card or the list. Read then rather than in
    /// `body`, so the map isn't rebuilt on every GPS fix while you stand there.
    @State private var pickedFrom: GeoPoint?
    @State private var showingRoutes = false
    @State private var confirmDiscard = false
    @State private var saving = false
    @State private var saved = false

    /// Lives on AppModel so a run survives navigating away from this screen.
    private var recorder: RunRecorder { model.runRecorder }
    private var unitMeters: Double { Units.meters(usesMiles: usesMiles) }
    private var unit: String { Units.label(usesMiles: usesMiles) }
    /// "run" or "walk", for buttons.
    private var noun: String { recorder.activity.title.lowercased() }
    private var tint: Color { recorder.activity == .walk ? .green : .orange }
    private var surfaces: Set<RunSurface> { RunSurface.set(from: surfacesStored) }
    /// Paths and routes show while you pick where to go. While recording and after, only
    /// the route you chose stays, so the map is about your run (and stays light).
    private var showsLayers: Bool { recorder.state == .idle }
    private var followedRoute: RunRoute? {
        followedRouteID.isEmpty ? nil : library.catalog.route(id: followedRouteID)
    }
    /// Only read in actions, never in `body` (see `pickedFrom`).
    private var here: GeoPoint? { recorder.lastLocation.map { GeoPoint($0.coordinate) } }

    /// Past this many degrees of latitude (about 15 km), paths are too dense to draw; routes still show.
    private static let trailSpan = 0.14
    private static let maxTrails = 450

    var body: some View {
        VStack(spacing: 0) {
            map
                .frame(maxHeight: recorder.state == .finished ? 260 : .infinity)
            // Before you start, or after you finish and before saving, in case you picked wrong.
            if recorder.state == .idle || (recorder.state == .finished && !saved) {
                activityPicker
                    .padding(.horizontal)
                    .padding(.top, 12)
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                stats(at: context.date)
            }
            controls
                .padding(.vertical, 24)
        }
        .navigationTitle(recorder.activity.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(recorder.state == .running || recorder.state == .paused)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { updatesMenu }
        }
        .onChange(of: cueEvery) { recorder.updateCues() }
        .onChange(of: surfacesStored) { refreshLayers() }
        .onChange(of: showTrails) { refreshLayers() }
        .task {
            await library.load()
            refreshLayers()
        }
        .sheet(isPresented: $showingRoutes) {
            NearbyRoutesView(
                catalog: library.catalog,
                origin: pickedFrom ?? mapBox?.center ?? GeoPoint(latitude: 47.6062, longitude: -122.3321),
                surfaces: surfaces,
                usesMiles: usesMiles,
                showTrails: $showTrails
            ) { route in
                select(.route(route))
                withAnimation { camera = .region(route.box.padded(by: 0.15).region) }
            }
        }
        .onAppear {
            if recorder.state == .idle {
                recorder.activity = activity ?? ActivityKind(rawValue: lastActivity) ?? .run
                recorder.reset(usesMiles: usesMiles)
                recorder.prepare()
            }
        }
        .onDisappear {
            if recorder.state == .idle { recorder.stopUpdates() }
        }
        .onChange(of: recorder.state) { _, state in
            UIApplication.shared.isIdleTimerDisabled = state == .running
            if state != .idle { selection = nil }
            refreshLayers()
        }
        .confirmationDialog("Discard this \(noun)?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { recorder.reset(usesMiles: usesMiles); saved = false }
        }
    }

    /// How often you hear how far you've gone, and whether it's read out loud.
    private var updatesMenu: some View {
        Menu {
            Picker("Distance updates", selection: $cueEvery) {
                Text("No updates").tag(0.0)
                ForEach(DistanceCues.choices, id: \.self) { units in
                    Text("Every \(DistanceCues.number(units)) \(unit)").tag(units)
                }
            }
            Toggle("Read out loud", isOn: $cueSpeak)
                .disabled(cueEvery == 0)
        } label: {
            Image(systemName: cueEvery > 0 ? "bell.badge" : "bell.slash")
        }
        .accessibilityLabel("Distance updates")
    }

    private var updatesSummary: String {
        guard cueEvery > 0 else { return "No distance updates. Tap the bell to turn them on." }
        return "Updates every \(DistanceCues.number(cueEvery)) \(unit)\(cueSpeak ? ", read out loud" : ""). Tap the bell to change."
    }

    private var activityPicker: some View {
        Picker("Recording", selection: Binding(
            get: { recorder.activity },
            set: { kind in
                recorder.activity = kind
                lastActivity = kind.rawValue
            }
        )) {
            ForEach(RunRecorder.activities) { kind in
                Text(kind.title).tag(kind)
            }
        }
        .pickerStyle(.segmented)
    }

    // MARK: Map

    private var map: some View {
        MapReader { proxy in
            Map(position: $camera) {
                UserAnnotation()
                trailLayer
                routeLayer
                // One line per segment, so a pause doesn't draw a straight line across town.
                ForEach(Array(recorder.tracker.segments.filter { $0.count > 1 }.enumerated()), id: \.offset) { _, segment in
                    MapPolyline(coordinates: segment.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) })
                        .stroke(tint, lineWidth: 5)
                }
            }
            .mapStyle(.standard(emphasis: .muted))
            .mapControls {
                MapUserLocationButton()
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                mapBox = GeoBox(context.region)
                refreshLayers()
            }
            .onTapGesture { screenPoint in
                tap(at: screenPoint, proxy: proxy)
            }
        }
        .overlay(alignment: .top) {
            if showsLayers {
                SurfaceFilterBar(stored: $surfacesStored) {
                    pickedFrom = here
                    showingRoutes = true
                }
                    .padding(.top, 8)
                    .padding(.trailing, 52) // clear of the location button
            }
        }
        .overlay(alignment: .bottom) {
            if let selection, showsLayers {
                RouteCard(
                    selection: selection,
                    catalog: library.catalog,
                    origin: pickedFrom,
                    usesMiles: usesMiles,
                    followedRouteID: $followedRouteID
                ) {
                    self.selection = nil
                }
                .padding(10)
            } else if showsLayers, !visibleTrails.isEmpty {
                Text("© OpenStreetMap contributors")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.regularMaterial, in: Capsule())
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(8)
            }
        }
    }

    /// Every path in view, in its surface's color; faded where the surface is a guess.
    @MapContentBuilder
    private var trailLayer: some MapContent {
        ForEach(visibleTrails) { line in
            MapPolyline(coordinates: line.points.map(\.coordinate))
                .stroke(line.surface.color.opacity(line.surfaceMapped ? 0.9 : 0.5), lineWidth: 3)
        }
        if case .trail(let trail) = selection {
            let coordinates = trail.points.map(\.coordinate)
            MapPolyline(coordinates: coordinates).stroke(.white, lineWidth: 9)
            MapPolyline(coordinates: coordinates).stroke(trail.surface.color, lineWidth: 5)
        }
    }

    /// Researched routes and tracks with a pin at each start; while recording, just the one you picked.
    @MapContentBuilder
    private var routeLayer: some MapContent {
        ForEach(visibleRoutes) { route in
            routeLines(route, emphasized: isPicked(route))
        }
        if let followedRoute, !showsLayers {
            routeLines(followedRoute, emphasized: true)
        }
        ForEach(visibleRoutes) { route in
            Annotation(route.name, coordinate: route.start.coordinate, anchor: .center) {
                Button {
                    select(.route(route))
                } label: {
                    Image(systemName: route.kind == .track ? "circle.circle" : "figure.run")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(route.mainSurface.color, in: Circle())
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                }
                .accessibilityLabel(route.name)
            }
            .annotationTitles((mapBox?.latitudeSpan ?? 1) < 0.03 ? .automatic : .hidden)
        }
    }

    /// A route drawn Strava style: its main surface's color over a white casing.
    @MapContentBuilder
    private func routeLines(_ route: RunRoute, emphasized: Bool) -> some MapContent {
        ForEach(Array(route.lines.enumerated()), id: \.offset) { _, line in
            let coordinates = line.map(\.coordinate)
            MapPolyline(coordinates: coordinates)
                .stroke(.white, style: StrokeStyle(lineWidth: emphasized ? 10 : 7, lineCap: .round, lineJoin: .round))
            MapPolyline(coordinates: coordinates)
                .stroke(route.mainSurface.color, style: StrokeStyle(lineWidth: emphasized ? 6 : 4, lineCap: .round, lineJoin: .round))
        }
    }

    private func isPicked(_ route: RunRoute) -> Bool {
        if case .route(let picked) = selection, picked.id == route.id { return true }
        return route.id == followedRouteID
    }

    /// Recomputes what's drawn: on camera moves, filter changes, and when recording starts or ends.
    private func refreshLayers() {
        guard showsLayers, let box = mapBox else {
            visibleTrails = []
            visibleRoutes = []
            return
        }
        let catalog = library.catalog
        visibleRoutes = box.latitudeSpan < 0.6 ? catalog.routes(in: box, surfaces: surfaces) : []
        visibleTrails = showTrails && box.latitudeSpan < Self.trailSpan
            ? catalog.trails(in: box, surfaces: surfaces, limit: Self.maxTrails)
            : []
    }

    /// Picks the route or path under your finger, with about 24 points of slack.
    private func tap(at screenPoint: CGPoint, proxy: MapProxy) {
        guard showsLayers,
              let tapped = proxy.convert(screenPoint, from: .local),
              let edge = proxy.convert(CGPoint(x: screenPoint.x + 24, y: screenPoint.y), from: .local)
        else { return }
        let point = GeoPoint(tapped)
        let hit = RouteCatalog.hit(at: point, tolerance: point.distance(to: GeoPoint(edge)), routes: visibleRoutes, trails: visibleTrails)
        switch hit {
        case .route(let route): select(.route(route))
        case .trail(let trail): select(.trail(trail))
        case nil: selection = nil
        }
    }

    private func select(_ picked: RouteSelection) {
        pickedFrom = here
        selection = picked
    }

    // MARK: Stats

    private func stats(at now: Date) -> some View {
        let tracker = recorder.tracker
        return VStack(spacing: 16) {
            if recorder.isLocationDenied {
                Label("Location is off for 80/20. Turn it on in Settings > Privacy > Location Services.", systemImage: "location.slash")
                    .font(.footnote)
                    .foregroundStyle(.red)
            } else if recorder.state == .idle {
                Text(recorder.gpsQuality).font(.footnote).foregroundStyle(.secondary)
                Text(updatesSummary).font(.footnote).foregroundStyle(.secondary)
            }

            HStack {
                stat(PaceFormat.duration(tracker.movingTime(at: now)), "Time")
                stat(PaceFormat.distance(tracker.distance, unitMeters: unitMeters), unit)
            }
            HStack {
                stat(PaceFormat.pace(tracker.currentPace(), unitMeters: unitMeters), "Pace /\(unit)")
                stat(PaceFormat.pace(tracker.averagePace(at: now), unitMeters: unitMeters), "Avg /\(unit)")
            }

            if recorder.state == .finished, !tracker.splits.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Splits").font(.headline)
                    ForEach(tracker.splits, id: \.index) { split in
                        HStack {
                            Text("\(unit) \(split.index)")
                            Spacer()
                            Text(PaceFormat.duration(split.seconds)).monospacedDigit()
                        }
                        .font(.subheadline)
                    }
                }
                .padding(.horizontal)
            }
        }
        .padding(.top, 16)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 36, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Controls

    @ViewBuilder
    private var controls: some View {
        switch recorder.state {
        case .idle:
            RoundButton(title: "Start", systemImage: "play.fill", tint: tint) {
                recorder.start()
            }
            .disabled(recorder.isLocationDenied)
        case .running:
            HStack(spacing: 40) {
                RoundButton(title: "Pause", systemImage: "pause.fill", tint: .gray) { recorder.pause() }
            }
        case .paused:
            HStack(spacing: 40) {
                RoundButton(title: "Resume", systemImage: "play.fill", tint: tint) { recorder.resume() }
                HoldToFinishButton { recorder.finish() }
            }
        case .finished:
            if saved {
                VStack(spacing: 12) {
                    Label("Saved to your log and Apple Health", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Button("New \(noun)") {
                        recorder.reset(usesMiles: usesMiles)
                        saved = false
                        recorder.prepare()
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                HStack(spacing: 24) {
                    Button("Discard", role: .destructive) { confirmDiscard = true }
                        .buttonStyle(.bordered)
                    Button {
                        saving = true
                        Task {
                            saved = await model.logRecording(recorder)
                            saving = false
                        }
                    } label: {
                        if saving { ProgressView() } else { Text("Save \(noun)") }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(tint)
                    .disabled(saving)
                }
            }
        }
    }
}

/// Finish needs a 1-second hold, so a pocket tap can't end your run or walk.
struct HoldToFinishButton: View {
    let action: () -> Void
    @State private var holding = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "stop.fill").font(.title)
            Text(holding ? "Hold..." : "Finish").font(.headline)
        }
        .frame(width: 96, height: 96)
        .background(Color.red.gradient, in: Circle())
        .foregroundStyle(.white)
        .scaleEffect(holding ? 1.1 : 1)
        .animation(.easeInOut(duration: 0.2), value: holding)
        .onLongPressGesture(minimumDuration: 1) {
            action()
        } onPressingChanged: { pressing in
            holding = pressing
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }
}
