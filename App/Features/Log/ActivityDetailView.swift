import SwiftUI
import MapKit
import EightyTwentyCore

/// One logged activity, opened from the Log. For a recorded run or walk: the route on a
/// map fitted to the whole of it (so a screenshot shows where you went), then distance,
/// time and pace.
struct ActivityDetailView: View {
    let log: ActivityLog

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage(PrefKey.usesMiles) private var usesMiles = Units.defaultUsesMiles
    @State private var confirmDelete = false
    /// From the workout in Apple Health; nil until read, empty if there's nothing to cut up.
    @State private var splits: [DistanceSplit]?
    /// Decoded once, not on every redraw.
    private let route: [CLLocationCoordinate2D]

    init(log: ActivityLog) {
        self.log = log
        let points = log.routePolyline.flatMap(Polyline.decode) ?? []
        route = points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    private var kind: ActivityKind? { log.activityKind }
    private var isRunOrWalk: Bool { kind == .run || kind == .walk }
    private var unitMeters: Double { Units.meters(usesMiles: usesMiles) }
    private var unit: String { Units.label(usesMiles: usesMiles) }
    private var tint: Color { kind == .walk ? .green : .orange }
    private var seconds: Double? { log.minutes.map { $0 * 60 } }
    private var meters: Double? { log.distanceMeters.flatMap { $0 > 0 ? $0 : nil } }
    /// Worked out the same way as what's saved to Apple Health (`ActiveEnergy`): on top of
    /// what you'd burn sitting still, from your weight and the distance.
    private var calories: Double? {
        guard isRunOrWalk, let kind, let meters, let kilograms = Units.bodyKilograms else { return nil }
        return ActiveEnergy.kilocalories(meters: meters, kilograms: kilograms, kind: kind)
    }

    var body: some View {
        List {
            if route.count > 1 {
                Section {
                    map
                        .frame(height: 320)
                        .listRowInsets(EdgeInsets())
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Label(log.displayTitle, systemImage: kind?.systemImage ?? "circle")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(isRunOrWalk ? tint : .primary)
                    Text(log.timestamp.formatted(date: .complete, time: .shortened))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                if meters != nil || seconds != nil {
                    HStack {
                        if let meters { stat(PaceFormat.distance(meters, unitMeters: unitMeters), unit) }
                        if let seconds { stat(PaceFormat.duration(seconds), "Time") }
                        if let meters, let seconds, meters >= 50 {
                            stat(PaceFormat.pace(seconds / meters, unitMeters: unitMeters), "Pace /\(unit)")
                        }
                        if let calories {
                            stat("\(Int(calories.rounded()))", "Calories")
                        }
                    }
                    .padding(.vertical, 6)
                }
            }

            if let splits, !splits.isEmpty {
                Section("Splits · pace /\(unit)") {
                    ForEach(splits, id: \.number) { split in
                        splitRow(split, fastest: splits.map(\.pace).min() ?? split.pace,
                                 slowest: splits.map(\.pace).max() ?? split.pace)
                    }
                }
            }

            Section("Details") {
                if let amount = log.amount {
                    LabeledContent("Amount", value: "\(amount.formatted()) \(kind?.unitLabel ?? "")")
                }
                if let before = log.intensityBefore, let after = log.intensityAfter {
                    LabeledContent("Intensity", value: "\(before) → \(after)")
                }
                LabeledContent("From", value: source)
                if let note = log.note, !note.isEmpty, note != log.displayTitle {
                    Text(note)
                }
            }

            Section {
                if isRunOrWalk, let kind {
                    let other: ActivityKind = kind == .run ? .walk : .run
                    Button("Make it a \(other.title.lowercased())", systemImage: other.systemImage) {
                        Task { await model.change(log, to: other) }
                    }
                }
                Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
            }
        }
        .navigationTitle(log.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: usesMiles) { await loadSplits() }
        .confirmationDialog("Delete this \(log.displayTitle.lowercased())?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                model.delete(log)
                dismiss()
            }
        }
    }

    private var map: some View {
        Map(initialPosition: wholeRoute) {
            MapPolyline(coordinates: route)
                .stroke(.white, style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
            MapPolyline(coordinates: route)
                .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            if let start = route.first {
                Annotation("Start", coordinate: start) { dot(.green) }
                    .annotationTitles(.hidden)
            }
            if let end = route.last {
                Annotation("Finish", coordinate: end) { dot(.red) }
                    .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(emphasis: .muted))
    }

    /// The whole route with a margin, like the recorder's finished map.
    private var wholeRoute: MapCameraPosition {
        guard let box = GeoBox(around: route.map { GeoPoint($0) }) else { return .automatic }
        return .region(box.padded(by: 0.12).region)
    }

    /// Splits come from the workout's distance samples in Apple Health, so runs recorded
    /// before splits were shown have them too. Runs logged by hand have none.
    private func loadSplits() async {
        guard isRunOrWalk, let uuid = log.healthKitUUID,
              let samples = await model.healthKit.distances(ofWorkout: uuid) else {
            splits = []
            return
        }
        // One sample start to finish (some other apps save it that way) has no splits in it.
        let usable = samples.count > 1 ? samples : []
        splits = DistanceSplits.from(usable, every: unitMeters)
    }

    /// "1  9:32" with a bar: longer is faster, scaled between your slowest and fastest.
    private func splitRow(_ split: DistanceSplit, fastest: Double, slowest: Double) -> some View {
        let full = split.meters >= unitMeters * 0.999
        let label = full ? "\(split.number)" : PaceFormat.distance(split.meters, unitMeters: unitMeters)
        let range = slowest - fastest
        let share = range > 0 ? 0.35 + 0.65 * (slowest - split.pace) / range : 1
        return HStack(spacing: 12) {
            Text(label)
                .font(.subheadline.monospacedDigit())
                .frame(width: 44, alignment: .leading)
            Text(PaceFormat.pace(split.pace, unitMeters: unitMeters))
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .frame(width: 56, alignment: .leading)
            GeometryReader { geometry in
                Capsule()
                    .fill(tint.opacity(0.7))
                    .frame(width: geometry.size.width * share)
            }
            .frame(height: 8)
        }
        .accessibilityElement(children: .combine)
    }

    private func dot(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 12, height: 12)
            .overlay(Circle().stroke(.white, lineWidth: 2))
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title2.monospacedDigit().weight(.semibold))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var source: String {
        switch ActivitySource(rawValue: log.source) {
        case .runRecorder: return "Recorded in this app"
        case .meditationTimer: return "Meditation timer"
        case .napTimer: return "Nap timer"
        case .ouraTag, .ouraSession: return "Oura"
        case .healthKit: return "Apple Health"
        case .manual, nil: return "Logged by hand"
        }
    }
}
