import SwiftUI
import EightyTwentyCore

/// The nap in progress, its alarm, and logging it once you're up. Saved to
/// UserDefaults while you sleep, so a nap still logs if iOS closes the app.
@MainActor
@Observable
final class NapSession {
    struct Logged: Equatable {
        let start: Date
        let minutes: Double
    }

    private(set) var nap: Nap?
    /// The nap that just ended, for the screen's "Logged" state. Cleared by Done.
    private(set) var logged: Logged?
    /// The last one ended under a minute in, so it wasn't logged.
    private(set) var tooShort = false
    /// False when the alarm fell back to a notification, which silent mode mutes.
    private(set) var ringsOnSilent = true

    init() {
        nap = UserDefaults.standard.data(forKey: PrefKey.napInProgress)
            .flatMap { try? JSONDecoder().decode(Nap.self, from: $0) }
    }

    func start(minutes: Int, notifications: NotificationService) async {
        let nap = Nap(start: .now, minutes: minutes)
        self.nap = nap
        logged = nil
        tooShort = false
        ringsOnSilent = true
        save()
        Log.app.info("Nap started")
        let real = await NapAlarm.set(nap, notifications: notifications)
        // Cancelled or up already while the alarm was being set (the permission prompt).
        guard self.nap?.id == nap.id, self.nap?.endedEarlyAt == nil else {
            NapAlarm.cancel(nap, notifications: notifications)
            return
        }
        ringsOnSilent = real
    }

    /// "I'm up": turns the alarm off and logs the nap so far.
    func wakeUp(using model: AppModel) {
        guard var nap else { return }
        nap.wakeUp(at: .now)
        NapAlarm.cancel(nap, notifications: model.notifications)
        self.nap = nap
        Log.app.info("Up before the nap alarm")
        logIfOver(using: model)
    }

    /// Stops without logging.
    func cancel(notifications: NotificationService) {
        guard let nap else { return }
        NapAlarm.cancel(nap, notifications: notifications)
        self.nap = nil
        save()
        Log.app.info("Nap cancelled")
    }

    /// Logs the nap once it's over. Runs on every tick of the Nap screen and whenever
    /// the app comes to the front, so a nap whose alarm rang while the app was closed
    /// still counts. Leaves the alarm alone: it may be ringing right now.
    ///
    /// Writes only when the nap is over, so the ticking screen doesn't re-render itself.
    func logIfOver(using model: AppModel, at now: Date = .now) {
        guard let nap, nap.isOver(at: now) else { return }
        self.nap = nil
        save()
        if let minutes = nap.loggableMinutes(at: now) {
            model.logNap(start: nap.start, minutes: minutes)
            logged = Logged(start: nap.start, minutes: minutes)
        } else {
            tooShort = true
            Log.app.info("Nap under a minute, not logged")
        }
    }

    /// Back to picking a length.
    func reset() {
        logged = nil
        tooShort = false
    }

    private func save() {
        let data = nap.flatMap { try? JSONEncoder().encode($0) }
        UserDefaults.standard.set(data, forKey: PrefKey.napInProgress)
    }
}

/// Pick a length, lie down, and an alarm wakes you. The nap logs itself; one you
/// already took can be logged by hand.
struct NapView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(PrefKey.napMinutes) private var minutes = NapGuide.defaultMinutes
    /// Fixed anchor for the clock, as on the Meditate screen: `.periodic(from: .now, ...)`
    /// would make a new schedule on every re-render.
    @State private var clockStart = Date()
    @State private var loggingPast = false

    /// Lives on AppModel so a nap survives navigating away from this screen.
    private var session: NapSession { model.nap }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                // Only the ring redraws every second.
                TimelineView(.periodic(from: clockStart, by: 1)) { context in
                    ring(at: context.date)
                        .onChange(of: context.date) { _, now in
                            session.logIfOver(using: model, at: now)
                        }
                }
                .padding(.top, 8)
                controls
                if session.nap == nil, session.logged == nil, !session.tooShort {
                    settings
                    research
                }
            }
            .padding()
        }
        .navigationTitle("Nap")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $loggingPast) { QuickLogSheet(kind: .nap) }
        .onAppear {
            session.logIfOver(using: model)
            Log.app.info("Nap screen opened, \(session.nap == nil ? "idle" : "napping")")
        }
    }

    private func ring(at now: Date) -> some View {
        let nap = session.nap
        let progress = nap?.progress(at: now) ?? (session.logged == nil ? 0 : 1)
        let remaining = nap?.remaining(at: now) ?? Double(minutes * 60)
        return ZStack {
            Circle().stroke(Color.purple.opacity(0.15), lineWidth: 18)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.purple.gradient, style: StrokeStyle(lineWidth: 18, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: progress)
            VStack(spacing: 8) {
                if let logged = session.logged {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(.green)
                    Text("Logged \(Int(logged.minutes.rounded())) min").font(.headline)
                    Text("Nap from \(logged.start.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if session.tooShort {
                    Text("Under a minute, so not logged").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    Text(PaceFormat.duration(remaining))
                        .font(.system(size: 56, weight: .light, design: .rounded))
                        .monospacedDigit()
                    if let nap {
                        Label(nap.alarmAt.formatted(date: .omitted, time: .shortened), systemImage: "alarm")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(width: 260, height: 260)
    }

    @ViewBuilder
    private var controls: some View {
        if session.nap != nil {
            HStack(spacing: 40) {
                RoundButton(title: "Cancel", systemImage: "xmark", tint: .gray) {
                    session.cancel(notifications: model.notifications)
                }
                RoundButton(title: "I'm up", systemImage: "sun.max.fill", tint: .purple) {
                    session.wakeUp(using: model)
                }
            }
            Text(session.ringsOnSilent
                 ? "Lock your phone and close your eyes. The alarm rings even on silent."
                 : "Turn your ringer on. Alarms aren't allowed for 80/20, so this one is a notification, and silent mode mutes it.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        } else if session.logged != nil || session.tooShort {
            Button("Done") { session.reset() }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
        } else {
            RoundButton(title: "Start", systemImage: "powersleep", tint: .purple) {
                Task { await session.start(minutes: minutes, notifications: model.notifications) }
            }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Minutes, falling asleep included").font(.subheadline).foregroundStyle(.secondary)
            Picker("Minutes", selection: $minutes) {
                ForEach(NapGuide.lengths, id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.segmented)
            ForEach(NapGuide.notes(minutes: minutes, hour: Calendar.current.component(.hour, from: .now)), id: \.self) { note in
                Label(note, systemImage: "exclamationmark.circle").font(.subheadline)
            }
            Button { loggingPast = true } label: {
                Label("Log a nap you already took", systemImage: "square.and.pencil")
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var research: some View {
        if let intervention = NapGuide.intervention {
            let evidence = intervention.evidence
            VStack(alignment: .leading, spacing: 10) {
                Text("What the research says").font(.caption.bold()).foregroundStyle(.secondary)
                Text(intervention.summary).font(.headline)
                Text(evidence.finding).font(.subheadline)
                if let url = evidence.url {
                    Link(destination: url) {
                        Label("\(evidence.citation) · grade \(evidence.grade.rawValue)", systemImage: "doc.text.magnifyingglass")
                    }
                    .font(.caption)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}
