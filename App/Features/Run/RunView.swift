import SwiftUI
import UIKit
import MapKit
import EightyTwentyCore

/// Record a run or walk like Strava: Start, Pause/Resume, Finish (hold), then Save or Discard.
struct RunView: View {
    /// What to record when nothing is in progress. Nil means whatever you picked last.
    var activity: ActivityKind? = nil

    @Environment(AppModel.self) private var model
    @AppStorage(PrefKey.usesMiles) private var usesMiles = Units.defaultUsesMiles
    @AppStorage(PrefKey.recordActivity) private var lastActivity = ActivityKind.run.rawValue
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
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
        }
        .confirmationDialog("Discard this \(noun)?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { recorder.reset(usesMiles: usesMiles); saved = false }
        }
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
        Map(position: $camera) {
            UserAnnotation()
            // One line per segment, so a pause doesn't draw a straight line across town.
            ForEach(Array(recorder.tracker.segments.filter { $0.count > 1 }.enumerated()), id: \.offset) { _, segment in
                MapPolyline(coordinates: segment.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) })
                    .stroke(tint, lineWidth: 5)
            }
        }
        .mapControls {
            MapUserLocationButton()
        }
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
