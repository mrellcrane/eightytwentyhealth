import SwiftUI
import SwiftData
import EightyTwentyCore

/// The Mental bar, the coach, and the evidence-backed things to do, ranked by
/// expected gain per minute for right now.
struct MentalView: View {
    @Environment(AppModel.self) private var model

    @Query private var snapshots: [DailySnapshot]
    @Query(filter: #Predicate<MoodEntry> { $0.deletedAt == nil }) private var moods: [MoodEntry]
    @Query(filter: #Predicate<GratitudeEntry> { $0.deletedAt == nil }) private var gratitude: [GratitudeEntry]
    @Query(filter: #Predicate<ActivityLog> { $0.deletedAt == nil }) private var activities: [ActivityLog]
    @Query(filter: #Predicate<CoachLog> { $0.deletedAt == nil }, sort: \CoachLog.startedAt, order: .reverse)
    private var conversations: [CoachLog]
    @Query(filter: #Predicate<SavedStudy> { $0.deletedAt == nil }) private var savedStudies: [SavedStudy]

    @AppStorage(PrefKey.energyNow) private var energyNow = 0
    @AppStorage(PrefKey.energyNowAt) private var energyNowAt = 0.0

    @State private var asking = false
    @State private var showingBar = false

    var body: some View {
        let input = BarsInput(snapshots: snapshots, moods: moods, gratitude: gratitude, activities: activities)
        let mental = input.display(.mental)
        let signals = Recommendations.signals(input: input, mental: mental, moods: moods, activities: activities,
                                              energy: Recommendations.energy(level: energyNow, at: energyNowAt))
        let ranked = Recommendations.rank(signals, activities: activities)

        List {
            Section {
                Button { showingBar = true } label: { HealthBarView(display: mental) }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section {
                AskCard {
                    model.coach.expireIfStale()
                    asking = true
                }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            if !conversations.isEmpty || !savedStudies.isEmpty {
                Section("Coach history") {
                    ForEach(conversations.prefix(3), id: \.persistentModelID) { log in
                        NavigationLink {
                            CoachLogView(log: log)
                        } label: {
                            PastQuestionRow(log: log)
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) { model.delete(log) }
                        }
                    }
                    if conversations.count > 3 {
                        NavigationLink("See all \(conversations.count) conversations") { CoachHistoryView() }
                    }
                    if !savedStudies.isEmpty {
                        NavigationLink {
                            StudyLibraryView()
                        } label: {
                            Label("Saved studies (\(savedStudies.count))", systemImage: "books.vertical")
                        }
                    }
                }
            }

            Section("What your data says") {
                EnergyNowPicker()
                DataSignalsView(signals: signals)
            }

            Section("Feel better now") {
                ForEach(ranked.filter { $0.intervention.timing == .rightAway }, id: \.intervention.id) { item in
                    NavigationLink {
                        InterventionDetailView(intervention: item.intervention, personal: item.personal)
                    } label: {
                        InterventionRow(ranked: item)
                    }
                }
            }

            Section {
                ForEach(ranked.filter { $0.intervention.timing == .overWeeks }, id: \.intervention.id) { item in
                    NavigationLink {
                        InterventionDetailView(intervention: item.intervention, personal: item.personal)
                    } label: {
                        InterventionRow(ranked: item)
                    }
                }
            } header: {
                Text("Build it up")
            } footer: {
                Text("≈ numbers are research estimates: the study's effect size × 33, roughly the average change against a comparison group. Ranked by that per minute, then reordered by what today's data shows: last night's sleep, steps since you woke, Oura stress, your check-ins and energy, and what you've already done. Once you've rated a step 3 times, your own before → after counts too.")
            }

            Section {
                CrisisLines()
            } footer: {
                Text("The coach is research-informed advice, not medical care.")
            }
        }
        .navigationTitle("Mental")
        .sheet(isPresented: $asking) { AskView() }
        .sheet(isPresented: $showingBar) {
            NavigationStack { BarDetailView(display: mental) }
                .presentationDetents([.medium, .large])
        }
    }
}

/// "What's going on?" Opens the coach.
struct AskCard: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.title2)
                    .foregroundStyle(BarKind.mental.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text("What's going on?").font(.headline)
                    Text("Tell the coach how you feel and why. It reads your Oura data and logs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding()
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }
}

/// 988, always one tap away.
struct CrisisLines: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("If you're thinking about hurting yourself, you don't have to handle it alone.")
                .font(.subheadline)
            HStack(spacing: 16) {
                Link(destination: URL(string: "tel:988")!) { Label("Call 988", systemImage: "phone.fill") }
                Link(destination: URL(string: "sms:988")!) { Label("Text 988", systemImage: "message.fill") }
            }
            .font(.subheadline.bold())
            // Without this, tapping anywhere in the list row fires the first link.
            .buttonStyle(.borderless)
            Text("Suicide & Crisis Lifeline, US, any time. In an emergency, call 911.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
