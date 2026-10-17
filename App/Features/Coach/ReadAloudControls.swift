import SwiftUI
import EightyTwentyCore

/// Listen to a coach answer: play or pause, and the speed (1×, 1.5×, 2×). Without
/// an ElevenLabs key, play asks for one, then starts.
struct ReadAloudControls: View {
    let pieces: [String]
    /// Icon only, for chat answers; the speed shows once it's playing.
    var compact = false

    @Environment(AppModel.self) private var model
    @State private var addingKey = false

    var body: some View {
        let player = model.readAloud
        let id = ReadAloud.id(pieces)
        let status = player.state(of: id)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    if player.hasKey { player.toggle(pieces) } else { addingKey = true }
                } label: {
                    playLabel(status)
                }
                .accessibilityLabel(status == .playing ? "Pause" : status == .loading ? "Stop" : "Listen")
                if !compact || status != .idle {
                    Button(player.speed.label) { player.speed = player.speed.next }
                        .monospacedDigit()
                        .accessibilityLabel("Speed \(player.speed.label)")
                }
                if status == .playing || status == .paused {
                    Button { player.stop() } label: { Image(systemName: "stop.fill") }
                        .accessibilityLabel("Stop")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(compact ? .small : .regular)
            .disabled(pieces.isEmpty)
            if player.failedID == id, let error = player.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .sheet(isPresented: $addingKey) {
            NavigationStack {
                Form { ElevenLabsSection() }
                    .navigationTitle("ElevenLabs key")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { addingKey = false }
                        }
                    }
            }
            .onChange(of: player.hasKey) {
                if player.hasKey {
                    addingKey = false
                    player.toggle(pieces)
                }
            }
        }
    }

    @ViewBuilder
    private func playLabel(_ status: ReadAloudPlayer.Status) -> some View {
        switch status {
        case .loading:
            if compact {
                ProgressView().controlSize(.mini)
            } else {
                Label { Text("Getting audio") } icon: { ProgressView().controlSize(.small) }
            }
        case .playing:
            if compact { Image(systemName: "pause.fill") } else { Label("Pause", systemImage: "pause.fill") }
        case .paused:
            if compact { Image(systemName: "play.fill") } else { Label("Resume", systemImage: "play.fill") }
        case .idle:
            if compact { Image(systemName: "speaker.wave.2.fill") } else { Label("Listen", systemImage: "play.fill") }
        }
    }
}

/// Paste, save or remove the ElevenLabs key, and pick the voice. In Settings and
/// from a play button.
struct ElevenLabsSection: View {
    @Environment(AppModel.self) private var model
    @AppStorage(PrefKey.readAloudVoiceName) private var voiceName = ElevenLabsRequest.defaultVoiceName
    @State private var key = ""
    @State private var voices: [ElevenLabsVoice] = []
    @State private var voicesError: String?

    private static let sample = ["Hi. This is how your coach answers will sound."]

    var body: some View {
        let player = model.readAloud
        Section {
            if player.hasKey {
                Label("Key saved on this phone", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Picker("Voice", selection: Binding(get: { player.voiceID }, set: { id in
                    player.stop()
                    player.voiceID = id
                    voiceName = voices.first { $0.voiceID == id }?.name ?? voiceName
                })) {
                    if !voices.contains(where: { $0.voiceID == player.voiceID }) {
                        Text(voiceName).tag(player.voiceID)
                    }
                    ForEach(voices) { voice in
                        Text(voice.name).tag(voice.voiceID)
                    }
                }
                .task { await loadVoices() }
                if let voicesError {
                    Text(voicesError).font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("Hear it") {
                    ReadAloudControls(pieces: Self.sample, compact: true)
                }
                Button("Remove key", role: .destructive) {
                    player.removeKey()
                    voices = []
                }
            } else {
                SecureField("ElevenLabs API key", text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save key") {
                    if player.saveKey(key) { key = "" }
                }
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } header: {
            Text("Read answers out loud")
        } footer: {
            Text("Get a key at elevenlabs.io under Developers > API keys, with Text to Speech access (and Voices read, to choose a voice). It stays in this phone's Keychain. Only the text of an answer you play goes to ElevenLabs. Each answer's audio is made once, at about one credit per character, and kept on this phone for 30 days, so replaying it or changing the speed costs nothing.")
        }
    }

    private func loadVoices() async {
        guard voices.isEmpty else { return }
        do {
            voices = try await model.readAloud.voices()
            voicesError = nil
        } catch {
            let reason: String
            switch error {
            case ElevenLabsError.http(_, "missing_permissions", _): reason = "this key doesn't have Voices read access."
            case let error as ElevenLabsError: reason = error.userMessage
            default: reason = error.localizedDescription
            }
            voicesError = "Couldn't load your voices: \(reason) Reading with \(voiceName) meanwhile."
        }
    }
}
