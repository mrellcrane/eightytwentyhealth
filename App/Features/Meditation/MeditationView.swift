import SwiftUI
import UIKit
import EightyTwentyCore

/// Drives a `MeditationTimer` (core) and handles bells + logging.
@MainActor
@Observable
final class MeditationSession {
    private(set) var timer = MeditationTimer(duration: 600)
    private(set) var loggedMinutes: Double?
    private var startedAt: Date?

    var state: MeditationTimer.State { timer.state }

    func start(minutes: Int, bellMinutes: Int, notifications: NotificationService) {
        timer = MeditationTimer(duration: Double(minutes * 60), intervalBell: bellMinutes > 0 ? Double(bellMinutes * 60) : nil)
        loggedMinutes = nil
        let now = Date()
        startedAt = now
        timer.start(at: now)
        scheduleBells(notifications)
    }

    func pause(notifications: NotificationService) {
        timer.pause(at: .now)
        notifications.cancelMeditationBells()
    }

    func resume(notifications: NotificationService) {
        timer.resume(at: .now)
        scheduleBells(notifications)
    }

    /// Called every second by the view. Returns true the moment the session completes.
    ///
    /// Writes `timer` only when it actually changes. Every write re-renders the
    /// screen, which used to restart the TimelineView, which ticked again: a loop
    /// that froze the app as soon as Meditate opened.
    func tick(at now: Date) -> Bool {
        var next = timer
        next.update(at: now)
        guard next != timer else { return false }
        timer = next
        return next.state == .completed
    }

    func endEarly(notifications: NotificationService) {
        timer.end(at: .now)
        notifications.cancelMeditationBells()
    }

    func log(using model: AppModel) async {
        guard loggedMinutes == nil, let startedAt, let minutes = timer.loggableMinutes(at: .now) else { return }
        loggedMinutes = minutes
        // If the session finished while the phone was locked, "now" is later than
        // the real end; the sat minutes from the start are the honest record.
        await model.logMeditation(start: startedAt, end: startedAt.addingTimeInterval(minutes * 60), minutes: minutes)
    }

    func reset() {
        timer = MeditationTimer(duration: timer.duration)
        loggedMinutes = nil
        startedAt = nil
    }

    private func scheduleBells(_ notifications: NotificationService) {
        let now = Date()
        let elapsed = timer.elapsed(at: now)
        let upcoming = timer.bellOffsets.filter { $0 > elapsed }.map { $0 - elapsed }
        let remaining = timer.remaining(at: now)
        Task { await notifications.scheduleMeditationBells(intervalBellsIn: upcoming, endIn: remaining) }
    }
}

struct MeditationView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(PrefKey.meditationMinutes) private var minutes = 10
    @AppStorage(PrefKey.meditationBellMinutes) private var bellMinutes = 0
    /// Lives on AppModel so a sit survives navigating away from this screen.
    private var session: MeditationSession { model.meditation }

    /// Fixed anchor for the clock. `.periodic(from: .now, ...)` made a new schedule on
    /// every re-render, which fired `onChange(of: context.date)` again straight away.
    @State private var clockStart = Date()

    private let durations = [3, 5, 10, 15, 20, 30, 45]
    private let bellOptions = [0, 1, 2, 5, 10]

    var body: some View {
        TimelineView(.periodic(from: clockStart, by: 1)) { context in
            VStack(spacing: 32) {
                Spacer()
                ring(at: context.date)
                Spacer()
                controls
                if session.state == .ready { settings }
            }
            .padding()
            .onChange(of: context.date) { _, now in
                if session.tick(at: now) {
                    Task { await session.log(using: model) }
                }
            }
        }
        .navigationTitle("Meditate")
        .navigationBarTitleDisplayMode(.inline)
        // Keep the screen on only while running; locking is fine too (bells still ring).
        .onChange(of: session.state) { _, state in
            UIApplication.shared.isIdleTimerDisabled = state == .running
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private func ring(at now: Date) -> some View {
        let progress = session.state == .ready ? 0 : session.timer.progress(at: now)
        let remaining = session.state == .ready ? Double(minutes * 60) : session.timer.remaining(at: now)
        return ZStack {
            Circle().stroke(Color.indigo.opacity(0.15), lineWidth: 18)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.indigo.gradient, style: StrokeStyle(lineWidth: 18, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: progress)
            VStack(spacing: 8) {
                if session.state == .completed {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(.green)
                    if let logged = session.loggedMinutes {
                        Text("Logged \(Int(logged.rounded())) min").font(.headline)
                        Text("Saved to Apple Health as Mindful Minutes").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Under a minute, so not logged").font(.subheadline).foregroundStyle(.secondary)
                    }
                } else {
                    Text(PaceFormat.duration(remaining))
                        .font(.system(size: 56, weight: .light, design: .rounded))
                        .monospacedDigit()
                    if session.state == .paused {
                        Text("Paused").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(width: 260, height: 260)
    }

    @ViewBuilder
    private var controls: some View {
        switch session.state {
        case .ready:
            RoundButton(title: "Begin", systemImage: "play.fill", tint: .indigo) {
                session.start(minutes: minutes, bellMinutes: bellMinutes, notifications: model.notifications)
            }
        case .running:
            HStack(spacing: 40) {
                RoundButton(title: "Pause", systemImage: "pause.fill", tint: .gray) {
                    session.pause(notifications: model.notifications)
                }
                RoundButton(title: "End", systemImage: "stop.fill", tint: .indigo) {
                    session.endEarly(notifications: model.notifications)
                    Task { await session.log(using: model) }
                }
            }
        case .paused:
            HStack(spacing: 40) {
                RoundButton(title: "Resume", systemImage: "play.fill", tint: .indigo) {
                    session.resume(notifications: model.notifications)
                }
                RoundButton(title: "End", systemImage: "stop.fill", tint: .gray) {
                    session.endEarly(notifications: model.notifications)
                    Task { await session.log(using: model) }
                }
            }
        case .completed:
            Button("Done") { session.reset() }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
        }
    }

    private var settings: some View {
        VStack(spacing: 16) {
            Picker("Duration", selection: $minutes) {
                ForEach(durations, id: \.self) { Text("\($0) min").tag($0) }
            }
            .pickerStyle(.segmented)
            HStack {
                Text("Interval bell")
                Spacer()
                Picker("Interval bell", selection: $bellMinutes) {
                    ForEach(bellOptions, id: \.self) { option in
                        Text(option == 0 ? "None" : "Every \(option) min").tag(option)
                    }
                }
            }
            Text("Bells ring as notifications, so you can lock your phone.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
