import SwiftUI
import EightyTwentyCore

/// Built to take under 10 seconds: pick a face, optionally tap a word, save.
struct MoodCheckInView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var step = 3
    @State private var energy: Int?
    @State private var emotions: Set<String> = []
    @State private var note = ""
    @State private var saving = false

    private let faces = MoodFaces.all

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 12) {
                        Text(faces[step]).font(.system(size: 64))
                        Text(MoodScale.label(forValence: MoodScale.valence(forStep: step)))
                            .font(.headline)
                        Slider(value: Binding(
                            get: { Double(step) },
                            set: { step = Int($0.rounded()) }
                        ), in: 0...6, step: 1)
                        HStack {
                            Text("Unpleasant")
                            Spacer()
                            Text("Pleasant")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                } header: {
                    Text("How do you feel right now?")
                }

                Section("Energy (optional)") {
                    Picker("Energy", selection: $energy) {
                        Text("Skip").tag(Int?.none)
                        ForEach(1...5, id: \.self) { level in
                            Text("\(level)").tag(Int?.some(level))
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("What's going on? (optional)") {
                    FlowLayout {
                        ForEach(suggestedEmotions, id: \.self) { emotion in
                            Chip(title: emotion, isSelected: emotions.contains(emotion)) {
                                if emotions.contains(emotion) {
                                    emotions.remove(emotion)
                                } else {
                                    emotions.insert(emotion)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    TextField("Note", text: $note, axis: .vertical)
                }
            }
            .navigationTitle("Check in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saving = true
                        Task {
                            await model.logMood(step: step, energy: energy, emotions: Array(emotions).sorted(), note: note)
                            dismiss()
                        }
                    }
                    .disabled(saving)
                }
            }
        }
        .presentationDetents([.large])
    }

    /// Show words that match where the slider is, plus anything already picked.
    private var suggestedEmotions: [String] {
        let base: [String]
        switch step {
        case 0...2: base = MoodScale.unpleasantEmotions
        case 4...6: base = MoodScale.pleasantEmotions
        default: base = Array(MoodScale.pleasantEmotions.prefix(6)) + Array(MoodScale.unpleasantEmotions.prefix(6))
        }
        return base + emotions.filter { !base.contains($0) }.sorted()
    }
}
