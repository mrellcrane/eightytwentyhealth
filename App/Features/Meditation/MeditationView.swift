import SwiftUI
import SwiftData
import UIKit
import EightyTwentyCore

/// Drives a `MeditationTimer` (core) and handles bells + logging.
@MainActor
@Observable
final class MeditationSession {
    private(set) var timer = MeditationTimer(duration: 600)
    private(set) var loggedMinutes: Double?
    /// What this sit is, so it logs as the right practice.
    private(set) var style: MeditationStyle = .breath
    private var startedAt: Date?

    var state: MeditationTimer.State { timer.state }

    func start(minutes: Int, bellMinutes: Int, style: MeditationStyle = .breath, notifications: NotificationService) {
        self.style = style
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
    /// that froze the app as soon as Meditate opened. (Same fix as 40d3c92 on
    /// claude/busy-hawking-5jpn3w.)
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
        await model.logMeditation(start: startedAt, end: startedAt.addingTimeInterval(minutes * 60), minutes: minutes,
                                  kind: style.logsAs, interventionID: style.interventionID)
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
    @AppStorage(PrefKey.energyNow) private var energyNow = 0
    @AppStorage(PrefKey.energyNowAt) private var energyNowAt = 0.0
    @State private var selectedStyle: MeditationStyle = .breath
    /// Fixed anchor for the clock. `.periodic(from: .now, ...)` made a new schedule on
    /// every re-render, which fired `onChange(of: context.date)` again straight away.
    @State private var clockStart = Date()

    @Query private var snapshots: [DailySnapshot]
    @Query(filter: #Predicate<MoodEntry> { $0.deletedAt == nil }) private var moods: [MoodEntry]
    @Query(filter: #Predicate<GratitudeEntry> { $0.deletedAt == nil }) private var gratitude: [GratitudeEntry]
    @Query(filter: #Predicate<ActivityLog> { $0.deletedAt == nil }) private var activities: [ActivityLog]

    /// Lives on AppModel so a sit survives navigating away from this screen.
    private var session: MeditationSession { model.meditation }

    /// 13 is the daily dose from Basso et al. 2019.
    private let durations = [3, 5, 10, 13, 15, 20, 30, 45]
    private let bellOptions = [0, 1, 2, 5, 10]

    var body: some View {
        // Worked out once per data change, not on every timer tick.
        let plan = currentPlan()
        let practiced = practicedDays()
        ScrollView {
            VStack(spacing: 28) {
                // Only the ring redraws every second; the rest of the screen doesn't.
                TimelineView(.periodic(from: clockStart, by: 1)) { context in
                    ring(at: context.date)
                        .onChange(of: context.date) { _, now in
                            if session.tick(at: now) {
                                Task { await session.log(using: model) }
                            }
                        }
                }
                .padding(.top, 8)
                if session.state != .ready {
                    Text(session.style.title).font(.headline).foregroundStyle(.secondary)
                }
                controls
                if session.state == .ready {
                    settings
                    planCard(plan, practiced: practiced)
                    guideSection("How long and how often",
                                 intro: "Daily beats long, and expect changes over weeks, not days.",
                                 findings: MeditationGuide.dose)
                    guideSection("What the research says",
                                 intro: "Mindfulness meditation unless noted. Grade A is a meta-analysis, B one randomized trial.",
                                 findings: MeditationGuide.findings + MeditationGuide.styles)
                }
            }
            .padding()
        }
        .navigationTitle("Meditate")
        .navigationBarTitleDisplayMode(.inline)
        // Keep the screen on only while running; locking is fine too (bells still ring).
        .onChange(of: session.state) { _, state in
            UIApplication.shared.isIdleTimerDisabled = state == .running
        }
        .onAppear { selectedStyle = plan.style }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    /// Style and length for right now, from the same data as the Mental screen.
    private func currentPlan() -> MeditationPlan {
        let input = BarsInput(snapshots: snapshots, moods: moods, gratitude: gratitude, activities: activities)
        let signals = Recommendations.signals(input: input, mental: input.display(.mental), moods: moods,
                                              activities: activities,
                                              energy: Recommendations.energy(level: energyNow, at: energyNowAt))
        return MeditationGuide.plan(signals: signals)
    }

    /// Days in the last 7 with a sit, breathwork or self-compassion practice.
    private func practicedDays() -> Int {
        let start = DayKey(date: .now).adding(days: -6)
        let kinds = Set(MeditationStyle.allCases.map(\.logsAs))
        return Set(activities.filter { log in log.activityKind.map { kinds.contains($0) } == true }
            .map { DayKey(date: $0.timestamp) }
            .filter { $0 >= start }).count
    }

    private func planCard(_ plan: MeditationPlan, practiced: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recommended for you now").font(.caption.bold()).foregroundStyle(.secondary)
            Text("\(plan.style.title), \(plan.minutes) min").font(.title3.bold())
            if let reason = plan.reason {
                Label(reason, systemImage: "chart.bar.doc.horizontal").font(.subheadline)
            }
            ForEach(Array(plan.style.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                    Text(step)
                }
                .font(.subheadline)
            }
            Text(plan.why).font(.subheadline).foregroundStyle(.secondary)
            if let url = plan.evidence.url {
                Link(destination: url) {
                    Label("\(plan.evidence.citation) · grade \(plan.evidence.grade.rawValue)", systemImage: "doc.text.magnifyingglass")
                }
                .font(.caption)
            }
            Button {
                minutes = plan.minutes
                selectedStyle = plan.style
                session.start(minutes: plan.minutes, bellMinutes: bellMinutes, style: plan.style, notifications: model.notifications)
            } label: {
                Label("Start \(plan.minutes) min", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)
            Text("You've practiced on \(practiced) of the last 7 days.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
    }

    private func guideSection(_ title: String, intro: String, findings: [MeditationFinding]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.bold())
            Text(intro).font(.subheadline).foregroundStyle(.secondary)
            ForEach(findings) { finding in
                VStack(alignment: .leading, spacing: 6) {
                    Text(finding.headline).font(.headline)
                    Text(finding.detail).font(.subheadline)
                    if let url = finding.url {
                        Link(destination: url) {
                            Label("\(finding.citation) · grade \(finding.grade.rawValue)", systemImage: "doc.text.magnifyingglass")
                        }
                        .font(.caption)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                session.start(minutes: minutes, bellMinutes: bellMinutes, style: selectedStyle, notifications: model.notifications)
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
            HStack {
                Text("Style")
                Spacer()
                Picker("Style", selection: $selectedStyle) {
                    ForEach(MeditationStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            DisclosureGroup("How to do it") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(selectedStyle.steps.enumerated()), id: \.offset) { index, step in
                        Text("\(index + 1). \(step)").frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .font(.subheadline)
                .padding(.top, 6)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Minutes").font(.subheadline).foregroundStyle(.secondary)
                Picker("Minutes", selection: $minutes) {
                    ForEach(durations, id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
            }
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
