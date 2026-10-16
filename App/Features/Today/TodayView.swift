import SwiftUI
import SwiftData
import EightyTwentyCore

struct TodayView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context

    @Query private var snapshots: [DailySnapshot]
    @Query(filter: #Predicate<MoodEntry> { $0.deletedAt == nil }) private var moods: [MoodEntry]
    @Query(filter: #Predicate<GratitudeEntry> { $0.deletedAt == nil }) private var gratitude: [GratitudeEntry]
    @Query(filter: #Predicate<ActivityLog> { $0.deletedAt == nil }) private var activities: [ActivityLog]

    @AppStorage(PrefKey.windDownOn) private var windDownOn = true
    @AppStorage(PrefKey.bedtimeMinutes) private var bedtimeMinutes = 22 * 60 + 15
    @AppStorage(PrefKey.energyNow) private var energyNow = 0
    @AppStorage(PrefKey.energyNowAt) private var energyNowAt = 0.0

    @State private var showingMood = false
    @State private var showingGratitude = false
    @State private var showingPhysical = false
    @State private var asking = false

    var body: some View {
        let input = BarsInput(snapshots: snapshots, moods: moods, gratitude: gratitude, activities: activities)
        let physical = input.display(.physical)
        let mental = input.display(.mental)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Button { showingPhysical = true } label: { HealthBarView(display: physical) }
                    .buttonStyle(.plain)
                NavigationLink { MentalView() } label: { HealthBarView(display: mental) }
                    .buttonStyle(.plain)

                AskCard {
                    model.coach.expireIfStale()
                    asking = true
                }

                quickActions

                let steps = nextSteps(physical: physical, mental: mental)
                if !steps.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Next best step").font(.title3.bold())
                        ForEach(steps, id: \.self) { step in
                            Label(step, systemImage: "arrow.right.circle")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }

                topPicks(input: input, mental: mental)

                syncStatus
            }
            .padding()
        }
        .navigationTitle("Today")
        .refreshable { await model.sync.sync(context: context) }
        .sheet(isPresented: $showingMood) { MoodCheckInView() }
        .sheet(isPresented: $showingGratitude) { GratitudeView() }
        .sheet(isPresented: $asking) { AskView() }
        .sheet(isPresented: $showingPhysical) {
            NavigationStack {
                BarDetailView(display: physical)
            }
            .presentationDetents([.medium, .large])
        }
    }

    /// The three best steps for right now, ranked from today's data like the Mental screen.
    private func topPicks(input: BarsInput, mental: BarDisplay) -> some View {
        let signals = Recommendations.signals(input: input, mental: mental, moods: moods, activities: activities,
                                              energy: Recommendations.energy(level: energyNow, at: energyNowAt))
        let picks = Recommendations.rank(signals, activities: activities).filter { !$0.doneToday }.prefix(3)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Your 80/20 right now").font(.title3.bold())
            EnergyNowPicker()
            ForEach(Array(picks), id: \.intervention.id) { item in
                NavigationLink {
                    InterventionDetailView(intervention: item.intervention, personal: item.personal)
                } label: {
                    InterventionRow(ranked: item)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
            NavigationLink { MentalView() } label: {
                Label("Why these, and everything else", systemImage: "list.bullet")
                    .font(.subheadline)
            }
        }
    }

    private var quickActions: some View {
        HStack(spacing: 12) {
            QuickAction(title: "Mood", systemImage: "face.smiling") { showingMood = true }
            QuickAction(title: "Gratitude", systemImage: "heart.text.square") { showingGratitude = true }
            NavigationLink {
                MeditationView()
            } label: {
                QuickActionLabel(title: "Meditate", systemImage: "figure.mind.and.body")
            }
            .buttonStyle(.plain)
            NavigationLink {
                RunView()
            } label: {
                QuickActionLabel(title: "Run", systemImage: "figure.run")
            }
            .buttonStyle(.plain)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Plain nudges about missing data. The ranked, evidence-backed steps live on the Mental screen.
    private func nextSteps(physical: BarDisplay, mental: BarDisplay) -> [String] {
        var steps: [String] = []
        if !model.oura.isConnected {
            steps.append("Connect Oura in Settings so your Physical bar has data.")
        }
        if snapshots.isEmpty && model.oura.isConnected {
            steps.append("Pull down to sync your Oura history.")
        }
        let today = DayKey(date: .now)
        let loggedMoodToday = moods.contains { DayKey(date: $0.timestamp) == today }
        if !loggedMoodToday {
            steps.append("Log a 10-second mood check-in. It's 40% of your Mental bar.")
        }
        let hour = Calendar.current.component(.hour, from: .now)
        let wroteGratitudeToday = gratitude.contains { DayKey(date: $0.date) == today }
        if !wroteGratitudeToday && hour >= 17 {
            steps.append("Write three good things from today.")
        }
        if windDownOn && hour >= 20 {
            steps.insert("Wind down: lights out by \(clockString(minutes: bedtimeMinutes)).", at: 0)
        }
        return steps
    }

    @ViewBuilder
    private var syncStatus: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.sync.isSyncing {
                ProgressView("Syncing...")
            } else if let last = model.sync.lastSyncedAt {
                Text("Synced \(last, style: .relative) ago")
            }
            if let error = model.sync.lastError {
                Text(error).foregroundStyle(.red)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

struct QuickAction: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { QuickActionLabel(title: title, systemImage: systemImage) }
            .buttonStyle(.plain)
    }
}

struct QuickActionLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 6) {
            // Fixed slot: SF Symbols differ in height, which knocked the labels out of line.
            Image(systemName: systemImage).font(.title2).frame(height: 30)
            Text(title).font(.caption)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Tap a bar: see exactly what built it.
struct BarDetailView: View {
    let display: BarDisplay

    var body: some View {
        List {
            Section {
                ForEach(display.today.components, id: \.id) { component in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(component.id.title).font(.headline)
                            Spacer()
                            Text("\(Int(component.score.rounded()))").monospacedDigit().bold()
                        }
                        Text(component.detail).font(.subheadline).foregroundStyle(.secondary)
                        Text("Counts \(Int((component.weight * 100).rounded()))%")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            } header: {
                Text("What's in it today")
            } footer: {
                Text("75 means your normal. Scores for HRV, resting HR and stress compare you to your own last 30 days, not to anyone else.")
            }

            if !display.today.missing.isEmpty {
                Section("No data yet") {
                    ForEach(display.today.missing, id: \.self) { id in
                        Text(id.title).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(display.kind.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
