import SwiftUI
import EightyTwentyCore

/// Ask the coach anything: it sees your bars, last two weeks, running plan, gym
/// sessions, patterns and your notes, and links back into the app.
struct CoachView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""
    @State private var hasKey = CoachSession.hasKey
    @State private var keyDraft = ""
    @State private var destination: CoachLink?
    @FocusState private var typing: Bool

    private var session: CoachSession { model.chat }

    private static let starters = [
        "What should I do today to feel my best tomorrow?",
        "How's my running going, and what's next?",
        "What's dragging my HRV down lately?",
    ]

    var body: some View {
        Group {
            if hasKey { chat } else { keyEntry }
        }
        .navigationTitle("Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if hasKey && !session.messages.isEmpty {
                Button("New chat") { session.reset() }
                    .disabled(session.isReplying)
            }
        }
        .sheet(item: $destination) { link in
            CoachDestinationView(link: link)
        }
    }

    // MARK: Chat

    private var chat: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if session.messages.isEmpty { welcome }
                        ForEach(session.messages) { message in
                            bubble(message).id(message.id)
                        }
                        if let error = session.error {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                    .padding()
                }
                .onChange(of: session.messages.last?.text) {
                    if let last = session.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            Divider()
            inputBar
        }
        // Links in replies: app links open here, research links open in Safari.
        .environment(\.openURL, OpenURLAction { url in
            guard let link = CoachLink(url: url) else { return .systemAction }
            destination = link
            return .handled
        })
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ask about anything in your data, or what to do next. Answers use your bars, last two weeks, running plan, gym sessions, patterns and your notes in Settings.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ForEach(Self.starters, id: \.self) { starter in
                Button(starter) { send(starter) }
                    .buttonStyle(.bordered)
                    .font(.subheadline)
            }
        }
    }

    private func bubble(_ message: CoachSession.Message) -> some View {
        let isUser = message.role == .user
        let streaming = session.isReplying && message.id == session.messages.last?.id
        return HStack {
            if isUser { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 6) {
                Group {
                    if message.text.isEmpty && session.isReplying {
                        ProgressView()
                    } else {
                        Text(Self.markdown(message.text))
                            .textSelection(.enabled)
                    }
                }
                .padding(12)
                .background(isUser ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1),
                            in: RoundedRectangle(cornerRadius: 14))
                if !isUser && !streaming && !message.text.isEmpty {
                    ReadAloudControls(pieces: ReadAloud.pieces(markdown: message.text), compact: true)
                }
            }
            if !isUser { Spacer(minLength: 40) }
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask the coach", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
                .focused($typing)
            Button {
                send(draft)
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title)
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.isReplying)
        }
        .padding()
    }

    private func send(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        draft = ""
        Task {
            let sent = await session.send(question) { CoachBriefing.systemPrompt(model.coachSnapshot()) }
            if !sent { draft = question }
        }
    }

    /// Links, bold and italics; line breaks kept. Anything that won't parse shows as plain text.
    private static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    // MARK: API key

    private var keyEntry: some View {
        Form {
            Section {
                SecureField("sk-ant-...", text: $keyDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save key") {
                    CoachSession.saveKey(keyDraft)
                    keyDraft = ""
                    hasKey = CoachSession.hasKey
                }
                .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("Your Claude API key")
            } footer: {
                Text("Create one at console.anthropic.com > API keys, and set a monthly spend limit there. It's stored in this iPhone's Keychain and only sent to Anthropic. Chats send your health summary to Anthropic's API.")
            }
        }
    }
}

/// What an app link in a reply opens.
private struct CoachDestinationView: View {
    let link: CoachLink

    var body: some View {
        switch link {
        case .mood:
            MoodCheckInView()
        case .gratitude:
            GratitudeView()
        case .addRun:
            AddRunSheet(existing: [])
        default:
            NavigationStack {
                content
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { DoneButton() }
                    }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch link {
        case .running: RunningView()
        case .recordRun: RunView(activity: .run)
        case .meditate: MeditationView()
        case .log: LogView()
        case .insights: InsightsView()
        case .mood, .gratitude, .addRun: EmptyView()
        }
    }
}

private struct DoneButton: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View { Button("Done") { dismiss() } }
}
