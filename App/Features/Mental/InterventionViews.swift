import SwiftUI
import EightyTwentyCore

extension Intervention.Grade {
    var label: String {
        switch self {
        case .a: return "A: meta-analysis"
        case .b: return "B: randomized trial"
        case .c: return "C: observational"
        }
    }
}

/// One row in the Mental screen's lists.
struct InterventionRow: View {
    let ranked: RankedIntervention

    var body: some View {
        let item = ranked.intervention
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.logsAs.systemImage)
                .frame(width: 28)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.body)
                Text(item.headline).font(.subheadline.bold()).foregroundStyle(BarKind.mental.color)
                Text("\(Int(item.minutes)) min · grade \(item.evidence.grade.rawValue)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let personal = ranked.personal, personal.count >= 3 {
                    Text("You: \(PersonalResult.text(personal))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let reason = ranked.reason {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

enum PersonalResult {
    /// "7.0 → 4.3 on average, 3 tries".
    static func text(_ personal: PersonalEffect) -> String {
        String(format: "%.1f → %.1f on average, %ld tries", personal.averageBefore, personal.averageAfter, personal.count)
    }
}

/// Steps, the science, your results, and the main button.
struct InterventionDetailView: View {
    let intervention: Intervention
    var personal: PersonalEffect?

    @State private var logging = false
    @State private var writingGratitude = false

    var body: some View {
        let evidence = intervention.evidence
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(intervention.headline)
                        .font(.title2.bold())
                        .foregroundStyle(BarKind.mental.color)
                    Text(intervention.summary)
                    Text("\(Int(intervention.minutes)) min · "
                         + (intervention.timing == .rightAway ? "measured right after one session" : "measured after weeks of practice"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section("How") {
                ForEach(Array(intervention.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                        Text(step)
                    }
                }
            }

            Section {
                Text(evidence.finding)
                LabeledContent("Evidence", value: evidence.grade.label)
                if let url = evidence.url {
                    Link(destination: url) {
                        Label(evidence.citation, systemImage: "doc.text.magnifyingglass")
                    }
                } else {
                    Text(evidence.citation)
                }
            } header: {
                Text("The science")
            } footer: {
                Text(String(format: "≈%ld%% is the study's effect size (%.2f) × 33: a research estimate of the average change, not a promise. Checked against the paper.",
                            intervention.researchPercent, evidence.effectSize))
            }

            if let personal, personal.count > 0 {
                Section {
                    Text(PersonalResult.text(personal))
                } header: {
                    Text("Your results")
                } footer: {
                    Text(personal.count >= 3
                         ? "How strong the problem felt before and after, 0-10. Your tries now count toward the ranking."
                         : "Shown on the list once you've rated 3 tries.")
                }
            }

            Section {
                mainButton
            }
        }
        .navigationTitle(intervention.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $logging) {
            InterventionLogSheet(
                title: intervention.title,
                kind: intervention.logsAs,
                interventionID: intervention.id,
                defaultMinutes: intervention.minutes,
                note: nil
            )
        }
        .sheet(isPresented: $writingGratitude) { GratitudeView() }
    }

    @ViewBuilder
    private var mainButton: some View {
        switch intervention.action {
        case .log:
            Button { logging = true } label: { Label("I did it", systemImage: "checkmark.circle") }
        case .gratitude:
            Button { writingGratitude = true } label: { Label("Write three good things", systemImage: "heart.text.square") }
        case .meditationTimer:
            NavigationLink { MeditationView() } label: { Label("Start the timer", systemImage: "timer") }
        }
    }
}

/// Logs a step you did, with optional before/after ratings.
struct InterventionLogSheet: View {
    let title: String
    let kind: ActivityKind
    let interventionID: String?
    let defaultMinutes: Double
    /// Saved with the log. For coach steps outside the catalog, the step's title.
    let note: String?

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var minutes: Double = 10
    @State private var date = Date()
    @State private var before: Int?
    @State private var after: Int?
    @State private var extraNote = ""
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if case .minutes = kind.measure {
                        Stepper("\(Int(minutes)) minutes", value: $minutes, in: 1...600, step: minutes < 10 ? 1 : 5)
                    }
                    DatePicker("When", selection: $date, in: ...Date())
                }

                Section {
                    ratingPicker("Before", selection: $before)
                    ratingPicker("After", selection: $after)
                } header: {
                    Text("How strong was it? (optional)")
                } footer: {
                    Text("Rate the problem itself (stress, tiredness, a headache) from 0 to 10, before and after. After 3 rated tries, your own average shows next to the research.")
                }

                Section("Note (optional)") {
                    TextField("Note", text: $extraNote, axis: .vertical)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Log") {
                        saving = true
                        Task {
                            let isMinutes: Bool = { if case .minutes = kind.measure { return true } else { return false } }()
                            let combined = [note, extraNote.nilIfEmpty].compactMap { $0 }.joined(separator: " · ")
                            await model.logActivity(
                                kind,
                                minutes: isMinutes ? minutes : nil,
                                amount: nil,
                                at: date,
                                note: combined,
                                interventionID: interventionID,
                                intensityBefore: before,
                                intensityAfter: after
                            )
                            dismiss()
                        }
                    }
                    .disabled(saving)
                }
            }
            .onAppear { minutes = max(1, defaultMinutes.rounded()) }
        }
        .presentationDetents([.medium, .large])
    }

    private func ratingPicker(_ label: String, selection: Binding<Int?>) -> some View {
        Picker(label, selection: selection) {
            Text("Skip").tag(Int?.none)
            ForEach(0...10, id: \.self) { value in
                Text("\(value)").tag(Int?.some(value))
            }
        }
        .pickerStyle(.menu)
    }
}
