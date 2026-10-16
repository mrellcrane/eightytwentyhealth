import SwiftUI
import SwiftData
import EightyTwentyCore

struct LogView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(PrefKey.usesMiles) private var usesMiles = Units.defaultUsesMiles

    @Query(filter: #Predicate<MoodEntry> { $0.deletedAt == nil }, sort: \MoodEntry.timestamp, order: .reverse)
    private var moods: [MoodEntry]
    @Query(filter: #Predicate<GratitudeEntry> { $0.deletedAt == nil }, sort: \GratitudeEntry.date, order: .reverse)
    private var gratitude: [GratitudeEntry]
    @Query(filter: #Predicate<ActivityLog> { $0.deletedAt == nil }, sort: \ActivityLog.timestamp, order: .reverse)
    private var activities: [ActivityLog]

    @State private var showingMood = false
    @State private var showingGratitude = false
    @State private var quickLogKind: ActivityKind?

    private let columns = [GridItem(.adaptive(minimum: 84), spacing: 10)]

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    QuickAction(title: "Mood", systemImage: "face.smiling") { showingMood = true }
                    QuickAction(title: "Gratitude", systemImage: "heart.text.square") { showingGratitude = true }
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            Section("Quick log") {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(ActivityKind.quickLog) { kind in
                        Button { quickLogKind = kind } label: {
                            VStack(spacing: 6) {
                                Image(systemName: kind.systemImage).font(.title3)
                                Text(kind.title)
                                    .font(.caption2)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.8)
                            }
                            .frame(maxWidth: .infinity, minHeight: 64)
                            .padding(6)
                            .background((kind.isGenerallyPositive ? Color.green : Color.orange).opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Recent") {
                if recent.isEmpty {
                    Text("Nothing logged yet. Start with a mood check-in.")
                        .foregroundStyle(.secondary)
                }
                ForEach(recent) { item in
                    RecentRow(item: item, usesMiles: usesMiles)
                        .swipeActions {
                            Button("Delete", role: .destructive) { delete(item) }
                        }
                        // Recorded a walk as a run, or the other way round.
                        .swipeActions(edge: .leading) {
                            if let log = item.runOrWalk {
                                let other: ActivityKind = log.activityKind == .run ? .walk : .run
                                Button("Make it a \(other.title.lowercased())", systemImage: other.systemImage) {
                                    Task { await model.change(log, to: other) }
                                }
                                .tint(other == .walk ? .green : .orange)
                            }
                        }
                }
            }
        }
        .navigationTitle("Log")
        .sheet(isPresented: $showingMood) { MoodCheckInView() }
        .sheet(isPresented: $showingGratitude) { GratitudeView() }
        .sheet(item: $quickLogKind) { kind in QuickLogSheet(kind: kind) }
    }

    private var recent: [RecentItem] {
        let items = moods.prefix(30).map(RecentItem.mood)
            + gratitude.prefix(30).map(RecentItem.gratitude)
            + activities.prefix(60).map(RecentItem.activity)
        return items.sorted { $0.date > $1.date }.prefix(50).map { $0 }
    }

    private func delete(_ item: RecentItem) {
        switch item {
        case .mood(let mood): model.delete(mood)
        case .gratitude(let entry): model.delete(entry)
        case .activity(let log): model.delete(log)
        }
    }
}

enum RecentItem: Identifiable {
    case mood(MoodEntry)
    case gratitude(GratitudeEntry)
    case activity(ActivityLog)

    var id: UUID {
        switch self {
        case .mood(let m): return m.id
        case .gratitude(let g): return g.id
        case .activity(let a): return a.id
        }
    }

    var date: Date {
        switch self {
        case .mood(let m): return m.timestamp
        case .gratitude(let g): return g.date
        case .activity(let a): return a.timestamp
        }
    }

    /// A run or a walk, which can be switched to the other.
    var runOrWalk: ActivityLog? {
        guard case .activity(let log) = self, log.activityKind == .run || log.activityKind == .walk else { return nil }
        return log
    }
}

struct RecentRow: View {
    let item: RecentItem
    let usesMiles: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .frame(width: 28)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                Text(item.date, format: .dateTime.weekday().hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var icon: String {
        switch item {
        case .mood: return "face.smiling"
        case .gratitude: return "heart.text.square"
        case .activity(let log): return log.activityKind?.systemImage ?? "circle"
        }
    }

    private var title: String {
        switch item {
        case .mood(let m):
            return MoodScale.label(forValence: m.valence)
        case .gratitude(let g):
            return g.items.first ?? "Gratitude"
        case .activity(let log):
            return log.displayTitle
        }
    }

    private var subtitle: String? {
        switch item {
        case .mood(let m):
            let parts = [m.emotions.joined(separator: ", "), m.note ?? "", m.source == "healthKit" ? "from Apple Health" : ""]
            return parts.filter { !$0.isEmpty }.joined(separator: " · ").nilIfEmpty
        case .gratitude(let g):
            return g.items.dropFirst().joined(separator: " · ").nilIfEmpty
        case .activity(let log):
            var parts: [String] = []
            if let meters = log.distanceMeters, meters > 0 {
                parts.append("\(PaceFormat.distance(meters, unitMeters: Units.meters(usesMiles: usesMiles))) \(Units.label(usesMiles: usesMiles))")
            }
            if let minutes = log.minutes { parts.append("\(Int(minutes.rounded())) min") }
            if let amount = log.amount { parts.append("\(amount.formatted()) \(log.activityKind.flatMap(\.unitLabel) ?? "")") }
            if let before = log.intensityBefore, let after = log.intensityAfter {
                parts.append("\(before) → \(after)")
            }
            if log.source == ActivitySource.ouraTag.rawValue || log.source == ActivitySource.ouraSession.rawValue {
                parts.append("from Oura")
            }
            // For coach steps outside the catalog the note is already the title.
            if let note = log.note, note != log.displayTitle { parts.append(note) }
            return parts.joined(separator: " · ").nilIfEmpty
        }
    }
}

extension ActivityKind {
    var unitLabel: String? {
        if case .count(let unit, _) = measure { return unit }
        return nil
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Log something that already happened, with a duration or amount.
struct QuickLogSheet: View {
    let kind: ActivityKind
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var minutes: Double = 10
    @State private var amount: Double = 1
    @State private var date = Date()
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                switch kind.measure {
                case .minutes:
                    Stepper("\(Int(minutes)) minutes", value: $minutes, in: 1...600, step: minutes < 10 ? 1 : 5)
                case .count(let unit, _):
                    Stepper("\(amount.formatted()) \(unit)", value: $amount, in: 1...20, step: 1)
                case .occurrence:
                    EmptyView()
                }
                DatePicker("When", selection: $date, in: ...Date())
                TextField("Note (optional)", text: $note, axis: .vertical)
            }
            .navigationTitle(kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Log") {
                        Task {
                            await model.logActivity(
                                kind,
                                minutes: isMinutes ? minutes : nil,
                                amount: isCount ? amount : nil,
                                at: date,
                                note: note
                            )
                            dismiss()
                        }
                    }
                }
            }
            .onAppear {
                switch kind.measure {
                case .minutes(let value): minutes = value
                case .count(_, let value): amount = value
                case .occurrence: break
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var isMinutes: Bool {
        if case .minutes = kind.measure { return true }
        return false
    }

    private var isCount: Bool {
        if case .count = kind.measure { return true }
        return false
    }
}
