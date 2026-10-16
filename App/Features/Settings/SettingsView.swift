import SwiftUI
import SwiftData
import AuthenticationServices
import UniformTypeIdentifiers
import EightyTwentyCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    @AppStorage(PrefKey.usesMiles) private var usesMiles = Units.defaultUsesMiles
    @AppStorage(PrefKey.moodReminderOn) private var moodReminderOn = false
    @AppStorage(PrefKey.moodReminderMinutes) private var moodReminderMinutes = 13 * 60
    @AppStorage(PrefKey.gratitudeReminderOn) private var gratitudeReminderOn = false
    @AppStorage(PrefKey.gratitudeReminderMinutes) private var gratitudeReminderMinutes = 21 * 60
    @AppStorage(PrefKey.windDownOn) private var windDownOn = true
    @AppStorage(PrefKey.bedtimeMinutes) private var bedtimeMinutes = 22 * 60 + 15
    @AppStorage(PrefKey.windDownLeadMinutes) private var windDownLeadMinutes = 45
    @AppStorage(PrefKey.morningBriefOn) private var morningBriefOn = true

    @AppStorage(PrefKey.coachNotes) private var coachNotes = ""
    @State private var hasCoachKey = CoachSession.hasKey
    @State private var connecting = false
    @State private var latestBackupURL: URL?
    @State private var importing = false
    @State private var message: String?

    var body: some View {
        Form {
            ouraSection
            healthSection
            coachSection
            backupSection
            sleepAndMorningSection
            remindersSection

            Section("Units") {
                Picker("Distance", selection: $usesMiles) {
                    Text("Miles").tag(true)
                    Text("Kilometers").tag(false)
                }
                .pickerStyle(.segmented)
            }

            barsSection
        }
        .navigationTitle("Settings")
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            restore(result)
        }
        .alert("Backup", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }

    // MARK: Oura

    private var ouraSection: some View {
        Section {
            if !model.oura.isConfigured {
                Text("Add your Oura client ID and secret to Config/Secrets.xcconfig, then rebuild. See the README.")
                    .foregroundStyle(.secondary)
            } else if model.oura.isConnected {
                Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Button {
                    Task { await model.sync.sync(context: context) }
                } label: {
                    HStack {
                        Text("Sync now")
                        Spacer()
                        if model.sync.isSyncing { ProgressView() }
                    }
                }
                .disabled(model.sync.isSyncing)
                Button("Disconnect", role: .destructive) {
                    Task { await model.oura.disconnect() }
                }
            } else {
                Button {
                    connecting = true
                    Task {
                        do {
                            try await model.oura.connect(using: webAuthenticationSession)
                            await model.sync.sync(context: context)
                        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
                            // You closed the sheet; nothing to report.
                        } catch {
                            model.notice = "Couldn't connect Oura: \(error.localizedDescription)"
                        }
                        connecting = false
                    }
                } label: {
                    HStack {
                        Text("Connect Oura")
                        Spacer()
                        if connecting { ProgressView() }
                    }
                }
                .disabled(connecting)
            }
            if let last = model.sync.lastSyncedAt {
                LabeledContent("Last sync") { Text(last, style: .relative) + Text(" ago") }
            }
            if let error = model.sync.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Oura")
        } footer: {
            Text("Readiness, sleep, HRV, stress and your Oura tags and Moments. Tags like alcohol or late caffeine become activity logs automatically.")
        }
    }

    // MARK: Apple Health

    private var healthSection: some View {
        Section {
            if model.healthAsked == true {
                Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Link("Change access in the Health app", destination: URL(string: "x-apple-health://")!)
            } else {
                Button("Allow Apple Health access") {
                    Task { await model.connectHealth() }
                }
                .disabled(!model.healthKit.isAvailable)
            }
        } header: {
            Text("Apple Health")
        } footer: {
            Text("Reads steps, workouts, VO2 max, mindful minutes and moods you log in the Health app. Writes your check-ins, meditations and runs, so Apple Health holds a second copy."
                + (model.healthAsked == true ? " To change what 80/20 can read or write: Health app > your profile picture > Apps > 80/20." : ""))
        }
        .task { await model.refreshHealthStatus() }
    }

    // MARK: Coach

    private var coachSection: some View {
        Section {
            TextEditor(text: $coachNotes)
                .frame(minHeight: 120)
            if hasCoachKey {
                Button("Remove Claude API key", role: .destructive) {
                    CoachSession.deleteKey()
                    hasCoachKey = CoachSession.hasKey
                }
            } else {
                Text("Add your Claude API key the first time you open Coach (the sparkles on Today).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Coach")
        } footer: {
            Text("Notes for your coach: your history, injuries, goals, anything it should keep in mind. They stay on this iPhone and go to Claude with each chat.")
        }
        .onAppear { hasCoachKey = CoachSession.hasKey }
    }

    // MARK: Backups

    private var backupSection: some View {
        Section {
            LabeledContent("iCloud") {
                Text(FileManager.default.ubiquityIdentityToken != nil ? "Signed in" : "Off")
                    .foregroundStyle(FileManager.default.ubiquityIdentityToken != nil ? Color.green : Color.red)
            }
            if let last = model.backup.lastBackupAt {
                LabeledContent("Last backup") { Text(last, style: .relative) + Text(" ago") }
                if !model.backup.lastLocations.isEmpty {
                    LabeledContent("Saved to", value: model.backup.lastLocations.joined(separator: " + "))
                }
            } else {
                Text("No backup yet. One runs automatically once you've logged something.")
                    .foregroundStyle(.secondary)
            }
            Button("Back up now") {
                Task { latestBackupURL = await model.backup.backupNow(context: context) }
            }
            if let latestBackupURL {
                ShareLink(item: latestBackupURL) {
                    Label("Share latest backup", systemImage: "square.and.arrow.up")
                }
            }
            Button("Restore from a backup file") { importing = true }
            if let error = model.backup.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Your data")
        } footer: {
            Text("Mood, gratitude and activity logs sync through iCloud. On top of that, a plain JSON backup is written daily to iCloud Drive and to Files > On My iPhone > 80/20. Restoring only adds missing entries; it never overwrites or deletes.")
        }
    }

    private func restore(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let counts = try model.backup.restore(from: url, context: context)
            let total = counts.moods + counts.gratitude + counts.activities
            message = total == 0
                ? "Everything in that file is already here."
                : "Restored \(counts.moods) moods, \(counts.gratitude) gratitude entries and \(counts.activities) activities."
        } catch {
            message = "Couldn't restore: \(error.localizedDescription)"
        }
    }

    // MARK: Wind-down and morning brief

    private var sleepAndMorningSection: some View {
        Section {
            Toggle("Wind-down reminder", isOn: $windDownOn)
            if windDownOn {
                DatePicker("Target bedtime", selection: minutesBinding($bedtimeMinutes), displayedComponents: .hourAndMinute)
                Picker("Remind me", selection: $windDownLeadMinutes) {
                    ForEach([15, 30, 45, 60, 90], id: \.self) { Text("\($0) min before").tag($0) }
                }
            }
            Toggle("Morning brief", isOn: $morningBriefOn)
        } header: {
            Text("Sleep and mornings")
        } footer: {
            Text("The morning brief arrives after Oura has your night: both bars, the number dragging them, and one thing to do. iOS decides exactly when background refresh runs and learns from when you use the app, so it can come later than you'd like, or not at all on a day you open the app first (you've seen it then). Opening the Oura app in the morning gets your night uploaded sooner.")
        }
        .onChange(of: windDownOn) { updateReminders() }
        .onChange(of: bedtimeMinutes) { updateReminders() }
        .onChange(of: windDownLeadMinutes) { updateReminders() }
    }

    // MARK: Reminders

    private var remindersSection: some View {
        Section("Reminders") {
            Toggle("Mood check-in", isOn: $moodReminderOn)
            if moodReminderOn {
                DatePicker("Time", selection: minutesBinding($moodReminderMinutes), displayedComponents: .hourAndMinute)
            }
            Toggle("Evening gratitude", isOn: $gratitudeReminderOn)
            if gratitudeReminderOn {
                DatePicker("Time", selection: minutesBinding($gratitudeReminderMinutes), displayedComponents: .hourAndMinute)
            }
        }
        .onChange(of: moodReminderOn) { updateReminders() }
        .onChange(of: moodReminderMinutes) { updateReminders() }
        .onChange(of: gratitudeReminderOn) { updateReminders() }
        .onChange(of: gratitudeReminderMinutes) { updateReminders() }
    }

    private func minutesBinding(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding(
            get: { Date.todayAt(minutes: minutes.wrappedValue) },
            set: { minutes.wrappedValue = $0.minutesSinceMidnight }
        )
    }

    private func updateReminders() {
        Task { await model.applyReminderSettings() }
    }

    // MARK: How the bars work

    private var barsSection: some View {
        Section {
            ForEach(BarKind.allCases) { kind in
                let weights = BarWeights.default.weights(for: kind).sorted { $0.value > $1.value }
                VStack(alignment: .leading, spacing: 4) {
                    Text(kind.title).font(.headline)
                    Text(weights.map { "\($0.key.title) \(Int(($0.value * 100).rounded()))%" }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("How the bars work")
        } footer: {
            Text("75 means your normal. Missing data is left out and the rest re-weighted, never counted as zero.")
        }
    }
}
