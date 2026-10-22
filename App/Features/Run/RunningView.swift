import SwiftUI
import SwiftData
import Charts
import PhotosUI
import EightyTwentyCore

/// Running: this week's plan, how runs felt, weekly miles, and ways to add a run.
struct RunningView: View {
    @Environment(AppModel.self) private var model
    @Query(filter: #Predicate<ActivityLog> { $0.deletedAt == nil }) private var activities: [ActivityLog]
    @AppStorage(PrefKey.runPlanStart) private var planStart = ""
    @AppStorage(PrefKey.runPlanStartMiles) private var planStartMiles = 0.0
    @AppStorage(PrefKey.runCheckIns) private var checkInsRaw = ""
    @State private var addingRun = false
    @State private var confirmRestart = false

    static let rules = [
        "Easy pace, always: conversational. Grow distance before speed.",
        "About +1 mile a week. Every 4th week, cut back about 25%.",
        "3 runs a week, never 3 days in a row.",
        "The long run grows half a mile at a time and stays under 40% of the week.",
        "Treadmill miles count. A guess is fine.",
        "Ibuprofen around a run can hide the signal, so judge that check-in on the cautious side.",
    ]

    /// Walks don't count toward the plan, so they're shown on their own.
    @ViewBuilder
    private func walksThisWeek(_ walks: [RunEntry], today: DayKey) -> some View {
        let monday = TrainingCalendar.monday(of: today)
        let week = walks.filter { $0.day >= monday && $0.day <= today }
        if !week.isEmpty {
            let miles = week.reduce(0.0) { $0 + $1.miles }
            let distance = miles > 0 ? ", \(RunningPlan.format(miles)) mi" : ""
            Label("\(week.count) \(week.count == 1 ? "walk" : "walks")\(distance). Walks don't count toward your running.",
                  systemImage: "figure.walk")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    var body: some View {
        let input = TrainingInput(healthRuns: model.healthRuns, activities: activities)
        let checkIns = RunCheckIns.decode(checkInsRaw)
        let today = DayKey(date: .now)

        List {
            if let plan = RunPlanSettings.plan(start: planStart, miles: planStartMiles) {
                let guidance = plan.guidance(runs: input.runs, checkIns: checkIns, today: today)
                Section {
                    WeekSummary(guidance: guidance, today: today)
                    walksThisWeek(input.walks, today: today)
                } header: {
                    Text("This week")
                }

                feelSection(runs: input.runs, checkIns: checkIns, today: today)

                Section {
                    ForEach(plan.outlook(runs: input.runs, checkIns: checkIns, today: today)) { item in
                        OutlookRow(item: item)
                    }
                } header: {
                    Text("Coming up")
                } footer: {
                    Text("The first week holds at about what you've been running, so tendons and bones catch up before miles go up. Then about +1 mi a week, with a lighter week every 4th. Assumes each week goes green; a yellow or short week repeats, a red one drops back to your last green week.")
                }

                Section {
                    MilesChart(plan: plan, runs: input.runs, checkIns: checkIns, today: today)
                        .frame(height: 200)
                        .padding(.vertical, 8)
                } header: {
                    Text("Weekly miles")
                } footer: {
                    Text("Bars are what you ran; dots are the plan.")
                }
            } else {
                Section {
                    PlanSetup(suggestedMiles: suggestedMiles(input.runs, today: today)) { start, miles in
                        planStart = start.rawValue
                        planStartMiles = miles
                    }
                } header: {
                    Text("Set up your plan")
                }
                feelSection(runs: input.runs, checkIns: checkIns, today: today)
            }

            Section {
                Button { addingRun = true } label: {
                    Label("Add a run: Strava screenshot or treadmill", systemImage: "plus.circle")
                }
                NavigationLink { RunView(activity: .run) } label: {
                    Label("Record a run here", systemImage: "record.circle")
                }
            } footer: {
                Text("Apple Fitness runs and runs recorded here come in through Apple Health on their own. Walks are kept apart: they never count toward your plan.")
            }

            Section {
                DisclosureGroup("The rules") {
                    ForEach(Self.rules, id: \.self) { rule in
                        Text(rule).font(.subheadline)
                    }
                }
            }
        }
        .navigationTitle("Running")
        .toolbar {
            if !planStart.isEmpty {
                Menu {
                    Button("Restart plan", role: .destructive) { confirmRestart = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("Restart your plan?", isPresented: $confirmRestart, titleVisibility: .visible) {
            Button("Restart", role: .destructive) {
                planStart = ""
                planStartMiles = 0
            }
        } message: {
            Text("Your runs and check-ins stay. You pick a new first week and its miles.")
        }
        .sheet(isPresented: $addingRun) { AddRunSheet(existing: input.runs) }
        .task { await model.refreshRuns() }
        .refreshable { await model.refreshRuns() }
    }

    /// Every run of the last two weeks and how it felt, so you can rate one or change it any time.
    @ViewBuilder
    private func feelSection(runs: [RunEntry], checkIns: [DayKey: RunSignal], today: DayKey) -> some View {
        let days = RunEntry.recentDays(runs, today: today)
        if !days.isEmpty {
            Section {
                ForEach(days, id: \.day) { run in
                    CheckInRow(run: run, today: today, signal: checkIns[run.day]) { signal in
                        var updated = checkIns
                        updated[run.day] = signal
                        checkInsRaw = RunCheckIns.encode(updated)
                    }
                }
            } header: {
                Text("How did it feel?")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(RunSignal.allCases, id: \.self) { signal in
                        Text("\(signal.title): \(signal.meaning)")
                    }
                    Text("Tap a color to rate a run or change it, and tap it again to clear it.")
                }
            }
        }
    }

    /// Your biggest week lately, rounded: a sensible place to hold before building.
    private func suggestedMiles(_ runs: [RunEntry], today: DayKey) -> Double {
        let monday = TrainingCalendar.monday(of: today)
        var best = 0.0
        for offset in 0...4 {
            let start = monday.adding(days: -7 * offset)
            let end = start.adding(days: 6)
            best = max(best, runs.filter { $0.day >= start && $0.day <= end }.reduce(0.0) { $0 + $1.miles })
        }
        return best > 0 ? max(3, best.rounded()) : 10
    }
}

private struct WeekSummary: View {
    let guidance: RunningPlan.Guidance
    let today: DayKey

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if guidance.week.kind == .beforePlan {
                // No target yet: the plan's first week is next week.
                Text("\(RunningPlan.format(guidance.week.actual)) mi this week, \(guidance.week.runs) runs")
                    .font(.title2.bold())
                    .monospacedDigit()
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(RunningPlan.format(guidance.week.actual)) of \(RunningPlan.format(guidance.week.target)) mi")
                        .font(.title2.bold())
                        .monospacedDigit()
                    Spacer()
                    Text("\(guidance.week.runs) of \(RunningPlan.runsPerWeek) runs")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: min(guidance.week.actual, guidance.week.target), total: max(guidance.week.target, 1))
                    .tint(.orange)
            }
            Text(guidance.week.kind.note)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let signal = guidance.week.signal, signal != .green {
                Label(signal.action, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(signal == .red ? Color.red : Color.orange)
            }
            Text(guidance.headline)
                .font(.subheadline)
        }
        .padding(.vertical, 4)

        ForEach(guidance.planned, id: \.day) { run in
            HStack {
                Text(dayLabel(run.day))
                Spacer()
                Text("\(RunningPlan.format(run.miles)) mi\(run.isLong ? ", long" : "")")
                    .monospacedDigit()
            }
        }

    }

    private func dayLabel(_ day: DayKey) -> String {
        if day == today { return "Today" }
        if day == today.adding(days: 1) { return "Tomorrow" }
        return TrainingCalendar.shortName(day)
    }
}

private struct OutlookRow: View {
    let item: RunningPlan.WeekOutlook

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Week of \(TrainingCalendar.monthDay(item.week.start))")
                Text("\(item.split.map(RunningPlan.format).joined(separator: " / ")) mi")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(RunningPlan.format(item.week.target)) mi")
                    .font(.headline)
                    .monospacedDigit()
                if let tag = Self.tag(item.week.kind) {
                    Text(tag).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

extension OutlookRow {
    static func tag(_ kind: RunningPlan.Week.Kind) -> String? {
        switch kind {
        case .first: return "Hold"
        case .cutback: return "Cutback"
        case .repeated: return "Repeat"
        case .droppedBack: return "Drop back"
        case .build, .beforePlan: return nil
        }
    }
}

/// A run's day and miles, and how it felt: tap a color to set it, tap it again to clear it.
private struct CheckInRow: View {
    let run: RunEntry
    let today: DayKey
    let signal: RunSignal?
    let record: (RunSignal?) -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(dayLabel).font(.headline)
                Text("\(RunningPlan.format(run.miles)) mi, \(signal?.title.lowercased() ?? "not rated yet")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 14) {
                ForEach(RunSignal.allCases, id: \.self) { choice in
                    Button {
                        record(choice == signal ? nil : choice)
                    } label: {
                        ZStack {
                            Circle().fill(choice == signal ? Self.color(choice) : Color.clear)
                            Circle().strokeBorder(Self.color(choice), lineWidth: 2.5)
                        }
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(choice.title)
                    .accessibilityAddTraits(choice == signal ? [.isSelected] : [])
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var dayLabel: String {
        if run.day == today { return "Today" }
        if run.day == today.adding(days: -1) { return "Yesterday" }
        return TrainingCalendar.label(run.day)
    }

    static func color(_ signal: RunSignal) -> Color {
        switch signal {
        case .green: return .green
        case .yellow: return .yellow
        case .red: return .red
        }
    }
}

private struct MilesChart: View {
    let plan: RunningPlan
    let runs: [RunEntry]
    let checkIns: [DayKey: RunSignal]
    let today: DayKey

    private struct Point: Identifiable {
        let week: Date
        let miles: Double
        let isPlan: Bool
        var id: String { "\(week.timeIntervalSince1970)-\(isPlan)" }
    }

    var body: some View {
        Chart(points) { point in
            if point.isPlan {
                PointMark(x: .value("Week", point.week, unit: .weekOfYear), y: .value("Miles", point.miles))
                    .foregroundStyle(Color.gray)
            } else {
                BarMark(x: .value("Week", point.week, unit: .weekOfYear), y: .value("Miles", point.miles))
                    .foregroundStyle(Color.orange)
            }
        }
    }

    /// Five weeks before the plan (or today) through three weeks ahead.
    private var points: [Point] {
        let monday = TrainingCalendar.monday(of: today)
        var result: [Point] = []
        var weekStart = min(plan.start, monday).adding(days: -7 * 5)
        while weekStart <= monday {
            let end = weekStart.adding(days: 6)
            let miles = runs.filter { $0.day >= weekStart && $0.day <= end }.reduce(0.0) { $0 + $1.miles }
            result.append(Point(week: weekStart.startDate(), miles: miles, isPlan: false))
            weekStart = weekStart.adding(days: 7)
        }
        for week in plan.weeks(runs: runs, checkIns: checkIns, today: today, weeksAhead: 3) {
            result.append(Point(week: week.start.startDate(), miles: week.target, isPlan: true))
        }
        return result
    }
}

private struct PlanSetup: View {
    let onStart: (DayKey, Double) -> Void
    @State private var miles: Double
    @State private var startsNextWeek = true

    init(suggestedMiles: Double, onStart: @escaping (DayKey, Double) -> Void) {
        self.onStart = onStart
        _miles = State(initialValue: suggestedMiles)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Three easy runs a week. About a mile more each week, a lighter week every 4th, and how each run felt can hold or drop the next week.")
                .font(.subheadline)
            Stepper("First week: \(RunningPlan.format(miles)) mi", value: $miles, in: 3...40, step: 0.5)
            Picker("First week", selection: $startsNextWeek) {
                Text("This week").tag(false)
                Text("Next week").tag(true)
            }
            .pickerStyle(.segmented)
            Button("Start plan") {
                let monday = TrainingCalendar.monday(of: DayKey(date: .now))
                onStart(startsNextWeek ? monday.adding(days: 7) : monday, miles)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
        .padding(.vertical, 4)
    }
}

/// Adds a run Apple Health doesn't have. A Strava screenshot fills in the numbers.
struct AddRunSheet: View {
    let existing: [RunEntry]
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date.now
    @State private var miles = 3.0
    @State private var photo: PhotosPickerItem?
    @State private var reading = false
    @State private var readNote: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PhotosPicker(selection: $photo, matching: .images) {
                        Label(reading ? "Reading..." : "Fill in from a screenshot", systemImage: "text.viewfinder")
                    }
                    .disabled(reading)
                    if let readNote {
                        Text(readNote).font(.caption).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Read on your phone; the image goes nowhere. Check the numbers before saving.")
                }
                Section {
                    DatePicker("Day", selection: $date, in: ...Date.now, displayedComponents: .date)
                    Stepper("\(RunningPlan.format(miles)) mi", value: $miles, in: 0.5...30, step: 0.1)
                    if let duplicate {
                        Text(duplicate).font(.caption).foregroundStyle(.orange)
                    }
                } footer: {
                    Text("Treadmill miles count too, Orangetheory included. A guess is fine.")
                }
            }
            .navigationTitle("Add a run")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.logManualRun(miles: miles, on: date)
                        dismiss()
                    }
                }
            }
            .onChange(of: photo) { _, item in
                guard let item else { return }
                Task { await read(item) }
            }
        }
    }

    private var duplicate: String? {
        let day = DayKey(date: date)
        guard let match = existing.first(where: { $0.day == day }) else { return nil }
        return "You already have a \(RunningPlan.format(match.miles)) mi run that day. Only save this if it's a different run."
    }

    private func read(_ item: PhotosPickerItem) async {
        reading = true
        defer {
            reading = false
            photo = nil
        }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let lines = try? await ScreenshotReader.lines(in: data) else {
            readNote = "Couldn't read that image."
            Log.app.warning("Screenshot read failed")
            return
        }
        let result = RunScreenshotParser.parse(lines)
        if let found = result.miles { miles = (found * 100).rounded() / 100 }
        if let found = result.date { date = min(found, .now) }
        readNote = result.miles == nil ? "Couldn't find a distance; enter it below." : "Filled in from the screenshot."
        Log.app.info("Screenshot read: distance found \(result.miles != nil), date found \(result.date != nil)")
    }
}
