import SwiftUI
import SwiftData
import EightyTwentyCore

/// Tell the coach what's going on; get 1-3 things to do, with the science.
struct AskView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var question = ""
    @State private var face: Int?
    @State private var energy: Int?
    @State private var emotions: Set<String> = []
    @State private var followUp = ""
    @State private var showingContext = false
    @State private var preview = ""
    @State private var logging: LoggableStep?
    @Query(filter: #Predicate<SavedStudy> { $0.deletedAt == nil }) private var savedStudies: [SavedStudy]
    @Query(filter: #Predicate<CoachLog> { $0.deletedAt == nil }, sort: \CoachLog.startedAt, order: .reverse)
    private var history: [CoachLog]
    @FocusState private var focus: Field?

    private enum Field { case question, followUp }

    private var coach: CoachService { model.coach }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !coach.hasKey { keyPrompt }
                    if let conversation = coach.conversation {
                        transcript(conversation)
                    } else {
                        compose
                    }
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("What's going on?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if coach.conversation != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button("New question") {
                            coach.reset()
                            question = ""
                            face = nil
                            energy = nil
                            emotions = []
                            followUp = ""
                        }
                        .disabled(coach.isThinking)
                    }
                } else {
                    // Up here so the keyboard never covers it.
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Ask", action: ask).disabled(!canAsk)
                    }
                }
            }
            .sheet(item: $logging) { item in
                stepLogSheet(item) {
                    coach.markStepLogged(turn: item.turn, step: item.index, modelContext: context)
                }
            }
            .onAppear {
                if coach.conversation == nil { focus = .question }
            }
        }
    }

    // MARK: Asking

    private var compose: some View {
        VStack(alignment: .leading, spacing: 20) {
            TextField("How do you feel, and what's going on? Anything: energy, stress, sleep, a headache...",
                      text: $question, axis: .vertical)
                .lineLimit(4...10)
                .focused($focus, equals: .question)
                .submitLabel(.send)
                .onChange(of: question) { _, text in
                    // Return sends instead of starting a new line.
                    if text.hasSuffix("\n") {
                        question = String(text.dropLast())
                        ask()
                    }
                }
                .padding(12)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 8) {
                Text("Mood (optional)").font(.subheadline.bold())
                HStack(spacing: 0) {
                    ForEach(MoodFaces.all.indices, id: \.self) { index in
                        Button {
                            face = face == index ? nil : index
                        } label: {
                            Text(MoodFaces.all[index])
                                .font(.system(size: 30))
                                .opacity(face == nil || face == index ? 1 : 0.35)
                                .scaleEffect(face == index ? 1.2 : 1)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(MoodScale.label(forValence: MoodScale.valence(forStep: index)))
                    }
                }
                if let face {
                    Text("\(MoodScale.label(forValence: MoodScale.valence(forStep: face))). Saved as a mood check-in, with what you wrote as the note.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Energy (optional)").font(.subheadline.bold())
                Picker("Energy", selection: $energy) {
                    Text("Skip").tag(Int?.none)
                    ForEach(1...5, id: \.self) { level in
                        Text("\(level)").tag(Int?.some(level))
                    }
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Feelings (optional)").font(.subheadline.bold())
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
            }

            Button(action: ask) {
                Label("Ask", systemImage: "paperplane.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canAsk)

            DisclosureGroup("What Claude sees", isExpanded: $showingContext) {
                ContextText(text: preview)
            }
            .onChange(of: showingContext) {
                if showingContext {
                    preview = coach.makeContext(question: question, checkIn: checkIn, modelContext: context).render()
                }
            }

            if !history.isEmpty {
                recent
            }
        }
    }

    /// Your last few questions. Tapping one reopens it here, answers and studies included.
    private var recent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Coach history").font(.headline)
                Spacer()
                NavigationLink("See all (\(history.count))") {
                    CoachHistoryView { log in coach.resume(log) }
                }
                .font(.subheadline)
            }
            ForEach(history.prefix(5), id: \.persistentModelID) { log in
                Button { coach.resume(log) } label: {
                    PastQuestionRow(log: log)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var checkIn: CoachContext.CheckIn? {
        let checkIn = CoachContext.CheckIn(valence: face.map { MoodScale.valence(forStep: $0) }, energy: energy,
                                           emotions: emotions.sorted())
        return checkIn.isEmpty ? nil : checkIn
    }

    private var canAsk: Bool {
        coach.hasKey && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func ask() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canAsk, coach.conversation == nil else { return }
        focus = nil
        // The context is built first, so the check-in below doesn't show up twice.
        coach.begin(text, checkIn: checkIn, modelContext: context)
        if let energy { Recommendations.saveEnergy(energy) }
        if let face {
            let energy = energy
            let emotions = emotions.sorted()
            Task { await model.logMood(step: face, energy: energy, emotions: emotions, note: text) }
        }
        Task { await coach.send(modelContext: context) }
    }

    /// Words that match the face, plus anything already picked.
    private var suggestedEmotions: [String] {
        let base: [String]
        switch face {
        case .some(0...2): base = MoodScale.unpleasantEmotions
        case .some(4...6): base = MoodScale.pleasantEmotions
        default: base = Array(MoodScale.unpleasantEmotions.prefix(6)) + Array(MoodScale.pleasantEmotions.prefix(6))
        }
        return base + emotions.filter { !base.contains($0) }.sorted()
    }

    private var keyPrompt: some View {
        NavigationLink {
            Form { ClaudeKeySection() }
                .navigationTitle("Claude key")
                .navigationBarTitleDisplayMode(.inline)
        } label: {
            Label("Add your Claude API key to ask the coach", systemImage: "key.fill")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    // MARK: The conversation

    private func transcript(_ conversation: CoachConversation) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(Array(conversation.turns.enumerated()), id: \.offset) { index, turn in
                VStack(alignment: .leading, spacing: 12) {
                    QuestionBubble(text: turn.question)
                    if let reply = turn.reply {
                        ReplyView(reply: reply, library: savedStudies.map(\.study), logged: turn.logged ?? []) { step, number in
                            logging = LoggableStep(step: step, turn: index, index: number)
                        }
                        StudyLookupPanel(turn: index, studies: turn.studies)
                    }
                }
            }

            if coach.isThinking {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Thinking. Usually 15 to 30 seconds.").foregroundStyle(.secondary)
                }
            } else if conversation.awaitingReply {
                VStack(alignment: .leading, spacing: 8) {
                    if let error = coach.errorMessage {
                        Text(error).foregroundStyle(.red)
                    }
                    Button("Try again") { Task { await coach.send(modelContext: context) } }
                        .buttonStyle(.bordered)
                        .disabled(!coach.hasKey)
                }
            } else {
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Follow up, like \"I can't nap at work\"", text: $followUp, axis: .vertical)
                        .lineLimit(1...5)
                        .focused($focus, equals: .followUp)
                        .submitLabel(.send)
                        .onChange(of: followUp) { _, text in
                            if text.hasSuffix("\n") {
                                followUp = String(text.dropLast())
                                sendFollowUp()
                            }
                        }
                        .padding(10)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
                    Button(action: sendFollowUp) {
                        Image(systemName: "arrow.up.circle.fill").font(.largeTitle)
                    }
                    .disabled(followUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !coach.hasKey)
                }
            }

            DisclosureGroup("What Claude saw") {
                ContextText(text: conversation.context)
            }
        }
    }

    private func sendFollowUp() {
        let text = followUp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, coach.hasKey, coach.conversation?.awaitingReply == false else { return }
        focus = nil
        followUp = ""
        coach.followUp(text, modelContext: context)
        Task { await coach.send(modelContext: context) }
    }
}

private struct LoggableStep: Identifiable {
    let id = UUID()
    let step: CoachReply.Step
    let turn: Int
    let index: Int
}

/// "Did it" on a coach step: the log sheet, prefilled from the step. Shared by
/// the Ask screen and Coach history.
private func stepLogSheet(_ item: LoggableStep, onLogged: @escaping () -> Void) -> InterventionLogSheet {
    InterventionLogSheet(
        title: item.step.intervention?.title ?? item.step.title,
        kind: item.step.intervention?.logsAs ?? item.step.activityKind,
        interventionID: item.step.intervention?.id,
        defaultMinutes: Double(max(item.step.minutes, 1)),
        note: item.step.intervention == nil ? item.step.title : nil,
        onLogged: onLogged
    )
}

struct QuestionBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BarKind.mental.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// The exact text sent to Claude ahead of your first question.
struct ContextText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
    }
}

/// Claude's answer: crisis lines first if needed, then the read, the steps, and the caveats.
struct ReplyView: View {
    let reply: CoachReply
    /// Saved studies, so Claude's citations of them link to the paper.
    var library: [Study] = []
    /// Steps already logged, to mark them done.
    var logged: [CoachConversation.Turn.LoggedStep] = []
    /// "Did it" on a step, with its index. Nil hides the buttons.
    var onDidIt: ((CoachReply.Step, Int) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if reply.crisis {
                CrisisLines()
                    .padding()
                    .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            }
            Text(reply.summary)
            ForEach(Array(reply.steps.enumerated()), id: \.offset) { index, step in
                StepCard(number: index + 1, step: step, library: library,
                         loggedAt: logged.last { $0.step == index }?.at,
                         onDidIt: onDidIt.map { action -> () -> Void in { action(step, index) } })
            }
            if !reply.avoid.isEmpty {
                Label(reply.avoid, systemImage: "hand.raised").font(.subheadline)
            }
            if !reply.seeADoctor.isEmpty {
                Label(reply.seeADoctor, systemImage: "cross.case").font(.subheadline).foregroundStyle(.red)
            }
        }
    }
}

struct StepCard: View {
    let number: Int
    let step: CoachReply.Step
    var library: [Study] = []
    /// When you last logged this step, if you did.
    var loggedAt: Date?
    var onDidIt: (() -> Void)?

    var body: some View {
        let checked = step.intervention
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(number). \(step.title)").font(.headline)
                Spacer()
                Text("\(step.minutes) min").font(.caption).foregroundStyle(.secondary)
            }
            Text(checked?.headline ?? step.effect)
                .font(.subheadline.bold())
                .foregroundStyle(BarKind.mental.color)
            Text(step.how)
            Text(step.why).font(.subheadline).foregroundStyle(.secondary)
            source(checked)
            if let loggedAt {
                Label("Logged \(loggedAt.formatted(.dateTime.weekday().hour().minute()))", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(.green)
            }
            HStack {
                if let onDidIt {
                    Button(loggedAt == nil ? "Did it" : "Log again", systemImage: "checkmark.circle", action: onDidIt)
                }
                if let checked {
                    NavigationLink("Details") { InterventionDetailView(intervention: checked) }
                }
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    /// Catalog numbers were checked against the paper; anything else is Claude's citation, with a way to look it up.
    @ViewBuilder
    private func source(_ checked: Intervention?) -> some View {
        if let checked, let url = checked.evidence.url {
            Link(destination: url) {
                Label("\(checked.evidence.citation) · checked", systemImage: "checkmark.seal")
            }
            .font(.caption)
        } else if let saved = StudyLibrary.study(citedAs: step.source, in: library), let url = saved.link {
            Link(destination: url) {
                Label("\(step.source) · found by search", systemImage: "checkmark.seal")
            }
            .font(.caption)
        } else if !step.source.isEmpty, let url = Self.scholarURL(step.source) {
            Link(destination: url) {
                Label("\(step.source) · cited by Claude", systemImage: "magnifyingglass")
            }
            .font(.caption)
        } else {
            Text("Basic physiology, no specific study").font(.caption).foregroundStyle(.secondary)
        }
    }

    static func scholarURL(_ query: String) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://scholar.google.com/scholar?q=\(encoded)")
    }
}

/// A saved conversation, from the Mental screen's "Past questions".
struct CoachLogView: View {
    let log: CoachLog
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @State private var continuing = false
    @State private var logging: LoggableStep?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(Array(log.turns.enumerated()), id: \.offset) { turnIndex, turn in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(turn.askedAt, format: .dateTime.weekday().month().day().hour().minute())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        QuestionBubble(text: turn.question)
                        if let reply = turn.reply {
                            ReplyView(reply: reply, library: turn.studies ?? [], logged: turn.logged ?? []) { step, number in
                                logging = LoggableStep(step: step, turn: turnIndex, index: number)
                            }
                        } else {
                            Text("No answer came back.").foregroundStyle(.secondary)
                        }
                        if let studies = turn.studies, !studies.isEmpty {
                            Text("Studies").font(.headline)
                            ForEach(studies) { StudyCard(study: $0) }
                        }
                    }
                }
                DisclosureGroup("What Claude saw") {
                    ContextText(text: log.context)
                }
            }
            .padding()
        }
        .navigationTitle("Conversation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Follow up") {
                    model.coach.resume(log)
                    continuing = true
                }
                .disabled(model.coach.isThinking)
            }
        }
        .sheet(isPresented: $continuing) { AskView() }
        .sheet(item: $logging) { item in
            stepLogSheet(item) {
                model.coach.markStepLogged(turn: item.turn, step: item.index, in: log, modelContext: context)
            }
        }
    }
}

/// Paste, save or remove the Claude API key. Used in Settings and from the Ask screen.
struct ClaudeKeySection: View {
    @Environment(AppModel.self) private var model
    @State private var key = ""

    var body: some View {
        Section {
            if model.coach.hasKey {
                Label("Key saved on this phone", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Button("Remove key", role: .destructive) { model.coach.removeKey() }
            } else {
                SecureField("Claude API key", text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save key") {
                    if model.coach.saveKey(key) { key = "" }
                }
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } header: {
            Text("Claude coach")
        } footer: {
            Text("Get a key at console.anthropic.com. It stays in this phone's Keychain. Claude is called only when you ask something: it gets what you typed plus \"What Claude sees\" (the time, your work hours and bedtime, both bars, last night's Oura data, your last two days of logs and moods, without mood notes). If Claude's safety filter declines a question, Anthropic retries it on another Claude model. Conversations are saved in the app, synced through iCloud and kept in your backups.")
        }
    }
}

/// "Look up studies" under an answer: your saved studies first, a web search only when needed.
struct StudyLookupPanel: View {
    let turn: Int
    let studies: [Study]?

    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context

    var body: some View {
        let state = model.coach.lookups[turn]
        VStack(alignment: .leading, spacing: 10) {
            if let studies {
                Text("Studies").font(.headline)
                if studies.isEmpty {
                    Text("No studies came back for this one.").font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(studies) { StudyCard(study: $0) }
            }

            switch state {
            case .searching:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Searching the research. About a minute.").foregroundStyle(.secondary)
                }
            case .failed(let message):
                Text(message).foregroundStyle(.red)
                Button("Try again") { lookUp(force: studies != nil) }.buttonStyle(.bordered)
            case nil:
                if studies == nil {
                    Button { lookUp(force: false) } label: {
                        Label("Look up studies on this", systemImage: "books.vertical")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.coach.hasKey)
                    Text("Checks your saved studies first. A new web search takes about a minute and sends only your question.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button { lookUp(force: true) } label: {
                        Label("Search for more", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.coach.hasKey)
                }
            }
        }
    }

    private func lookUp(force: Bool) {
        Task { await model.coach.lookUpStudies(turn: turn, force: force, modelContext: context) }
    }
}

/// One study: who, what kind, what it found, and whether its link came from a real search.
struct StudyCard: View {
    let study: Study

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(study.citation).font(.subheadline.bold())
            Text(study.design).font(.caption).foregroundStyle(.secondary)
            Text(study.finding).font(.subheadline)
            HStack {
                if let link = study.link {
                    Link(destination: link) {
                        Label(study.foundBySearch ? "Found by search" : "From Claude's memory, check it",
                              systemImage: study.foundBySearch ? "checkmark.seal" : "exclamationmark.triangle")
                    }
                    .foregroundStyle(study.foundBySearch ? Color.accentColor : Color.orange)
                }
                Spacer()
                Text("Saved \(study.foundAt.formatted(.dateTime.month().day()))").foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Every study the coach has found for you, by topic. Searchable; swipe to remove.
struct StudyLibraryView: View {
    @Environment(AppModel.self) private var model
    @Query(filter: #Predicate<SavedStudy> { $0.deletedAt == nil }, sort: \SavedStudy.foundAt, order: .reverse)
    private var saved: [SavedStudy]
    @State private var search = ""

    var body: some View {
        let shown = search.isEmpty ? saved : saved.filter {
            $0.citation.localizedCaseInsensitiveContains(search) || $0.title.localizedCaseInsensitiveContains(search)
                || $0.topic.localizedCaseInsensitiveContains(search) || $0.keywords.contains { $0.localizedCaseInsensitiveContains(search) }
        }
        let topics = Dictionary(grouping: shown, by: \.topic).sorted { $0.key < $1.key }
        List {
            if saved.isEmpty {
                Text("Nothing yet. Tap \"Look up studies on this\" under a coach answer, and what it finds is saved here.")
                    .foregroundStyle(.secondary)
            }
            ForEach(topics, id: \.key) { group in
                Section(group.key.isEmpty ? "Other" : group.key) {
                    ForEach(group.value, id: \.persistentModelID) { study in
                        StudyCard(study: study.study)
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                            .listRowBackground(Color.clear)
                            .swipeActions {
                                Button("Remove", role: .destructive) { model.delete(study) }
                            }
                    }
                }
            }
        }
        .searchable(text: $search)
        .navigationTitle("Saved studies")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One saved conversation in a list: the question, when, and how many follow-ups.
struct PastQuestionRow: View {
    let log: CoachLog

    var body: some View {
        let turns = log.turns
        VStack(alignment: .leading, spacing: 2) {
            Text(log.title).lineLimit(2)
            HStack(spacing: 4) {
                Text(log.startedAt, format: .dateTime.weekday().month().day().hour().minute())
                if turns.count > 1 { Text("· \(turns.count - 1) follow-up\(turns.count == 2 ? "" : "s")") }
                if turns.last?.reply == nil { Text("· no answer") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

/// Every coach question and answer, newest first. Searchable; swipe to delete.
struct CoachHistoryView: View {
    /// Set when shown from the Ask screen: picking a conversation reopens it there.
    /// Otherwise a conversation opens on its own screen.
    var onOpen: ((CoachLog) -> Void)?

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<CoachLog> { $0.deletedAt == nil }, sort: \CoachLog.startedAt, order: .reverse)
    private var logs: [CoachLog]
    @State private var search = ""

    var body: some View {
        let shown = search.isEmpty ? logs : logs.filter { log in
            log.turns.contains { $0.question.localizedCaseInsensitiveContains(search) }
        }
        List {
            if logs.isEmpty {
                Text("Nothing yet. Every question you ask the coach, and its answer, is saved here.")
                    .foregroundStyle(.secondary)
            }
            ForEach(shown, id: \.persistentModelID) { log in
                Group {
                    if let onOpen {
                        Button {
                            onOpen(log)
                            dismiss()
                        } label: {
                            PastQuestionRow(log: log)
                        }
                        .buttonStyle(.plain)
                    } else {
                        NavigationLink {
                            CoachLogView(log: log)
                        } label: {
                            PastQuestionRow(log: log)
                        }
                    }
                }
                .swipeActions {
                    Button("Delete", role: .destructive) { model.delete(log) }
                }
            }
        }
        .searchable(text: $search, prompt: "Search your questions")
        .navigationTitle("Coach history")
        .navigationBarTitleDisplayMode(.inline)
    }
}
