import SwiftUI

/// Three good things. Specific beats generic: "Sam made me laugh at lunch" over "friends".
struct GratitudeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var items = ["", "", ""]
    @State private var note = ""
    @FocusState private var focused: Int?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(items.indices, id: \.self) { index in
                        TextField("Good thing \(index + 1)", text: $items[index], axis: .vertical)
                            .focused($focused, equals: index)
                            .submitLabel(index < items.count - 1 ? .next : .done)
                            .onSubmit { focused = index < items.count - 1 ? index + 1 : nil }
                    }
                } header: {
                    Text("Three things that went well")
                } footer: {
                    Text("Be specific, and add why it happened if you can. That's the version that worked in the studies.")
                }
                Section("Anything else? (optional)") {
                    TextField("Note", text: $note, axis: .vertical)
                }
            }
            .navigationTitle("Gratitude")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.logGratitude(items: items, note: note)
                        dismiss()
                    }
                    .disabled(items.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty })
                }
            }
            .onAppear { focused = 0 }
        }
    }
}
