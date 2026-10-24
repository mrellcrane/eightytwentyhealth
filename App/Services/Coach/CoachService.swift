import Foundation
import SwiftData
import EightyTwentyCore

/// Your Claude API key, in this phone's Keychain. Never in the app binary (the repo
/// is public). One key for both coaches: the Mental screen's and the chat.
enum ClaudeKey {
    static let service = "eightytwenty.claude"
    private static let account = "apiKey"
    /// Where the chat kept its key before the two shared one. Still read, so a key
    /// pasted there works everywhere.
    private static let chatAccount = "anthropic-api-key"

    static func load() -> String {
        let key = Keychain.data(for: account, service: service).map { String(decoding: $0, as: UTF8.self) } ?? ""
        if !key.isEmpty { return key }
        return Keychain.data(for: chatAccount).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    static func save(_ key: String) -> Bool {
        guard Keychain.set(Data(key.utf8), for: account, service: service) else { return false }
        Keychain.delete(chatAccount)
        return true
    }

    static func remove() {
        Keychain.delete(account, service: service)
        Keychain.delete(chatAccount)
    }
}

/// The Claude coach: builds what Claude sees from your data, keeps the current
/// conversation, and saves every question and answer as a `CoachLog`. Chatting
/// about an answer afterwards isn't saved: closing the Ask screen ends the chat.
///
/// Logs carry status codes, timings and step counts only: never what you typed,
/// what Claude said, or the health numbers in the context.
@MainActor
@Observable
final class CoachService {
    /// Read from the Keychain each time: the chat can save or remove the shared key too.
    /// `keyVersion` is only there so views here redraw after a save or remove.
    var hasKey: Bool {
        _ = keyVersion
        return !ClaudeKey.load().isEmpty
    }
    private var keyVersion = 0
    private(set) var conversation: CoachConversation?
    /// The `CoachLog` that holds `conversation`.
    private(set) var logID: UUID?
    private(set) var isThinking = false
    private(set) var errorMessage: String?
    /// A lost connection cut the answer off, usually iOS pausing the app while you
    /// were in another one. `resendIfDropped` asks again once you're back.
    private(set) var dropped = false
    /// Answers asked again on their own since the last one came back, so a phone
    /// with no signal doesn't keep trying.
    private var resends = 0
    /// "Look up studies" in progress or failed, by turn of the current conversation.
    private(set) var lookups: [Int: LookupState] = [:]
    /// Talking the current answer through.
    private(set) var chat: CoachChat?
    private(set) var isChatting = false
    private(set) var chatError: String?
    /// Changes whenever a chat ends, so an answer still streaming for it is dropped.
    private var chatID: UUID?

    enum LookupState: Equatable {
        case searching
        case failed(String)
    }

    private let client: CoachClient

    init(transport: HTTPTransport = URLSessionTransport()) {
        client = CoachClient(transport: transport, apiKey: { ClaudeKey.load() })
    }

    // MARK: Key

    @discardableResult
    func saveKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, ClaudeKey.save(trimmed) else { return false }
        keyVersion += 1
        Log.coach.info("API key saved")
        return true
    }

    func removeKey() {
        ClaudeKey.remove()
        keyVersion += 1
        Log.coach.info("API key removed")
    }

    // MARK: Conversation

    /// Starts a new conversation. The context is built here, before anything
    /// else gets logged, so it shows the moment you asked.
    func begin(_ question: String, checkIn: CoachContext.CheckIn?, modelContext: ModelContext) {
        let text = makeContext(question: question, checkIn: checkIn, modelContext: modelContext).render()
        conversation = CoachConversation(context: text, question: question.trimmingCharacters(in: .whitespacesAndNewlines))
        logID = UUID()
        errorMessage = nil
        dropped = false
        resends = 0
        lookups = [:]
        endChat()
        persist(modelContext)
    }

    /// Picks a saved conversation back up, to ask a follow-up.
    func resume(_ log: CoachLog) {
        conversation = log.record.conversation
        logID = log.id
        errorMessage = nil
        dropped = false
        resends = 0
        lookups = [:]
        endChat()
    }

    /// Opening the coach hours later starts a new conversation; the old one is in Past questions.
    func expireIfStale(now: Date = .now) {
        if let last = conversation?.turns.last?.askedAt, now.timeIntervalSince(last) > 2 * 3600 {
            reset()
        }
    }

    func reset() {
        guard !isThinking else { return }
        conversation = nil
        logID = nil
        errorMessage = nil
        dropped = false
        lookups = [:]
        endChat()
    }

    /// Sends whatever is waiting for an answer. Also the retry after an error.
    func send(modelContext: ModelContext) async {
        guard let sent = conversation, sent.awaitingReply, !isThinking else { return }
        isThinking = true
        errorMessage = nil
        dropped = false
        let started = Date()
        defer { isThinking = false }
        do {
            let (reply, text, info) = try await BackgroundTime.keepAlive("Coach answer") { try await client.reply(to: sent) }
            // You may have started a new question while this one was out.
            guard conversation == sent else { return }
            var answered = sent
            answered.record(reply, text: text)
            conversation = answered
            resends = 0
            persist(modelContext)
            Log.coach.info("Answered turn \(answered.turns.count) in \(Self.seconds(since: started)): \(reply.steps.count) steps, \(info.summary)")
        } catch let error as CoachError {
            errorMessage = error.userMessage
            let summary = "Turn \(sent.turns.count) failed after \(Self.seconds(since: started)): \(Self.logLabel(error))"
            switch error {
            case .unauthorized, .rateLimited, .overloaded, .refused, .noKey: Log.coach.warning(summary)
            default: Log.coach.error(summary)
            }
        } catch {
            dropped = Self.isDropped(error)
            if !dropped {
                errorMessage = "Couldn't reach Claude: \(error.localizedDescription)"
            } else {
                errorMessage = resends < 2 ? "Lost the connection. Asking again..." : "Lost the connection. Check your signal and try again."
            }
            Log.coach.warning("Turn \(sent.turns.count) failed after \(Self.seconds(since: started)): \(error.localizedDescription)")
        }
    }

    /// Asks again for an answer a lost connection cut off. The Ask screen calls it
    /// when you're back in the app.
    func resendIfDropped(modelContext: ModelContext) async {
        guard dropped, !isThinking, resends < 2 else { return }
        resends += 1
        Log.coach.info("Asking again after a lost connection (\(resends) of 2)")
        await send(modelContext: modelContext)
    }

    private static func isDropped(_ error: Error) -> Bool {
        guard let code = (error as? URLError)?.code else { return false }
        return [.networkConnectionLost, .notConnectedToInternet, .timedOut, .cancelled].contains(code)
    }

    // MARK: Chat

    /// Asks about the answer; the first question starts the chat. Returns false if it
    /// didn't go through, so the view can put the question back.
    func ask(about question: String) async -> Bool {
        guard let conversation, !conversation.awaitingReply, !isThinking, !isChatting else { return false }
        let key = ClaudeKey.load()
        guard !key.isEmpty else { return false }
        if chat == nil {
            // Studies from "Look up studies", so Claude can talk about them.
            chat = CoachChat(base: conversation, studies: Self.unique(conversation.turns.flatMap { $0.studies ?? [] }))
            chatID = UUID()
        }
        guard let id = chatID else { return false }
        chat?.ask(question.trimmingCharacters(in: .whitespacesAndNewlines), at: Self.stamp(.now))
        let turn = chat?.turns.count ?? 0
        chatError = nil
        isChatting = true
        defer { if chatID == id { isChatting = false } }
        let started = Date()
        do {
            let stream = try await BackgroundTime.keepAlive("Coach chat") { try await streamChat(key: key, id: id) }
            guard chatID == id else { return true }
            let answer = try stream.answer()
            chat?.finish(answer)
            Log.coach.info("Chat turn \(turn) answered in \(Self.seconds(since: started)): stop \(stream.stopReason ?? "none"), \(stream.inputTokens) in, \(stream.cachedTokens) cached, \(stream.outputTokens) out\(stream.fellBack ? ", after a fallback" : "")")
            return true
        } catch {
            // Closed meanwhile: nothing to show or put back.
            guard chatID == id else { return true }
            chat?.withdraw()
            if let error = error as? CoachError {
                chatError = error.userMessage
                let summary = "Chat turn \(turn) failed after \(Self.seconds(since: started)): \(Self.logLabel(error))"
                switch error {
                case .unauthorized, .rateLimited, .overloaded, .refused: Log.coach.warning(summary)
                default: Log.coach.error(summary)
                }
            } else {
                chatError = "Couldn't reach Claude: \(error.localizedDescription)"
                Log.coach.warning("Chat turn \(turn) failed after \(Self.seconds(since: started)): \(error.localizedDescription)")
            }
            return false
        }
    }

    func endChat() {
        chat = nil
        chatID = nil
        chatError = nil
        isChatting = false
    }

    private func streamChat(key: String, id: UUID) async throws -> CoachStream {
        do {
            return try await streamChat(key: key, id: id, fallbacks: true)
        } catch CoachError.http(400, let message) where message.localizedCaseInsensitiveContains("fallback") {
            // As for answers: if the API ever rejects the fallback beta, go without it.
            return try await streamChat(key: key, id: id, fallbacks: false)
        }
    }

    private func streamChat(key: String, id: UUID, fallbacks: Bool) async throws -> CoachStream {
        guard let chat else { throw CancellationError() }
        let request = try CoachChatRequest.urlRequest(chat, apiKey: key, fallbacks: fallbacks)
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count > 8000 { break }
            }
            throw CoachClient.error(status: status, body: body)
        }
        var stream = CoachStream()
        for try await line in bytes.lines {
            guard chatID == id else { break }
            let text = try stream.read(line)
            if !text.isEmpty { self.chat?.receive(text) }
        }
        return stream
    }

    // MARK: Context

    func makeContext(question: String, checkIn: CoachContext.CheckIn?, modelContext: ModelContext,
                     now: Date = .now) -> CoachContext {
        let defaults = UserDefaults.standard
        // A recent "energy right now" rating counts as part of what you're reporting.
        var checkIn = checkIn
        if checkIn?.energy == nil, let energy = Recommendations.storedEnergy(now: now) {
            var merged = checkIn ?? CoachContext.CheckIn()
            merged.energy = energy.level
            checkIn = merged
        }
        let input = BarsInput(
            snapshots: (try? modelContext.fetch(FetchDescriptor<DailySnapshot>())) ?? [],
            moods: (try? modelContext.fetch(FetchDescriptor<MoodEntry>())) ?? [],
            gratitude: (try? modelContext.fetch(FetchDescriptor<GratitudeEntry>())) ?? [],
            activities: (try? modelContext.fetch(FetchDescriptor<ActivityLog>())) ?? []
        )
        let today = DayKey(date: now)
        let repository = Repository(context: modelContext)
        let recent = now.addingTimeInterval(-CoachContext.recentWindow)
        let monthLogs = repository.activities(since: now.addingTimeInterval(-CoachContext.triedWindow))

        return CoachContext(
            now: now,
            timeZone: .current,
            work: CoachContext.WorkHours(
                startMinutes: defaults.integer(forKey: PrefKey.workStartMinutes),
                endMinutes: defaults.integer(forKey: PrefKey.workEndMinutes),
                weekdaysOnly: defaults.bool(forKey: PrefKey.workWeekdaysOnly)
            ),
            bedtimeMinutes: defaults.integer(forKey: PrefKey.bedtimeMinutes),
            physical: input.display(.physical, on: today),
            mental: input.display(.mental, on: today),
            today: input.sensors[today],
            yesterday: input.sensors[today.adding(days: -1)],
            activities: monthLogs.filter { $0.timestamp >= recent }.map { log in
                CoachContext.Activity(
                    timestamp: log.timestamp,
                    title: log.displayTitle,
                    minutes: log.minutes,
                    distanceMeters: log.distanceMeters,
                    amount: log.amount.map { "\($0.formatted()) \(log.activityKind?.unitLabel ?? "")" }
                )
            },
            moods: repository.moods(since: recent).map {
                CoachContext.Mood(timestamp: $0.timestamp, valence: $0.valence, energy: $0.energy, emotions: $0.emotions)
            },
            checkIn: checkIn,
            tried: monthLogs
                .filter { $0.interventionID != nil || $0.intensityBefore != nil || $0.activityKind == .other }
                .map(\.interventionLog),
            studies: StudyLibrary.matches(question, in: library(modelContext)),
            usesMiles: defaults.object(forKey: PrefKey.usesMiles) as? Bool ?? Units.defaultUsesMiles
        )
    }

    // MARK: Did it

    /// Marks a step as logged on its conversation, current or from history.
    func markStepLogged(turn: Int, step: Int, in log: CoachLog? = nil, modelContext: ModelContext) {
        let now = Date()
        if log == nil || log?.id == logID {
            conversation?.markLogged(step: step, turn: turn, at: now)
            persist(modelContext)
        } else if let log {
            var turns = log.turns
            guard turns.indices.contains(turn) else { return }
            turns[turn].markLogged(step: step, at: now)
            log.turnsData = CoachRecord.encodeTurns(turns)
            log.updatedAt = now
            do {
                try modelContext.save()
            } catch {
                Log.coach.error("Couldn't save a logged step: \(error.localizedDescription)")
            }
        }
        Log.coach.info("Step logged from the coach (turn \(turn + 1), step \(step + 1))")
    }

    // MARK: Studies

    /// Your saved studies, not deleted.
    func library(_ modelContext: ModelContext) -> [Study] {
        let saved = (try? modelContext.fetch(FetchDescriptor<SavedStudy>(predicate: #Predicate { $0.deletedAt == nil }))) ?? []
        return saved.map(\.study)
    }

    /// Studies for one answer. Your library first: if enough saved studies match,
    /// they're shown and nothing is searched. Otherwise Claude searches the web
    /// (only the question is sent), skipping what you already have, and
    /// everything it finds is saved. `force` searches even with library matches.
    func lookUpStudies(turn index: Int, force: Bool = false, modelContext: ModelContext) async {
        guard let conversation, conversation.turns.indices.contains(index), lookups[index] != .searching else { return }
        let question = conversation.lookupQuestion(forTurn: index)
        let saved = StudyLibrary.matches(question, in: library(modelContext))
        let shown = conversation.turns[index].studies ?? []

        if !force, saved.count >= StudyLibrary.enoughToSkipSearch {
            attach(Self.unique(shown + saved), toTurn: index, modelContext: modelContext)
            Log.coach.info("Study lookup: \(saved.count) from the library, no search")
            return
        }

        let startedFor = logID
        lookups[index] = .searching
        let started = Date()
        do {
            let known = Self.unique(shown + saved)
            let result = try await BackgroundTime.keepAlive("Study lookup") { try await client.lookUpStudies(question, known: known) }
            store(result.studies, modelContext: modelContext)
            lookups[index] = nil
            // You may have moved to another question meanwhile; the studies are saved either way.
            if logID == startedFor {
                attach(Self.unique(shown + saved + result.studies), toTurn: index, modelContext: modelContext)
            }
            let verified = result.studies.filter(\.foundBySearch).count
            Log.coach.info("Study lookup in \(Self.seconds(since: started)): \(result.searches) searches, \(result.studies.count) new (\(verified) found by search), \(saved.count) from the library")
        } catch let error as CoachError {
            lookups[index] = .failed(error.userMessage)
            let summary = "Study lookup failed after \(Self.seconds(since: started)): \(Self.logLabel(error))"
            switch error {
            case .unauthorized, .rateLimited, .overloaded, .refused, .noKey: Log.coach.warning(summary)
            default: Log.coach.error(summary)
            }
        } catch {
            lookups[index] = .failed("Couldn't reach Claude: \(error.localizedDescription)")
            Log.coach.warning("Study lookup failed after \(Self.seconds(since: started)): \(error.localizedDescription)")
        }
    }

    private func attach(_ studies: [Study], toTurn index: Int, modelContext: ModelContext) {
        conversation?.attachStudies(studies, toTurn: index)
        persist(modelContext)
    }

    /// Saves new studies; one already saved gains the new keywords instead of a copy.
    private func store(_ studies: [Study], modelContext: ModelContext) {
        for study in studies {
            let key = study.id
            let existing = try? modelContext.fetch(FetchDescriptor<SavedStudy>(predicate: #Predicate { $0.key == key })).first
            if let existing {
                let merged = StudyLibrary.merge([study], into: [existing.study])[0]
                existing.keywords = merged.keywords
                existing.foundBySearch = merged.foundBySearch
                existing.deletedAt = nil
            } else {
                modelContext.insert(SavedStudy(study))
            }
        }
        do {
            try modelContext.save()
        } catch {
            Log.coach.error("Couldn't save studies: \(error.localizedDescription)")
        }
    }

    private static func unique(_ studies: [Study]) -> [Study] {
        var seen = Set<String>()
        return studies.filter { seen.insert($0.id).inserted }
    }

    // MARK: Private

    private func persist(_ modelContext: ModelContext) {
        guard let conversation, let logID else { return }
        let id = logID
        let existing = try? modelContext.fetch(FetchDescriptor<CoachLog>(predicate: #Predicate { $0.id == id })).first
        let log = existing ?? CoachLog(id: id, startedAt: conversation.turns.first?.askedAt ?? .now)
        if existing == nil { modelContext.insert(log) }
        log.update(conversation)
        do {
            try modelContext.save()
        } catch {
            Log.coach.error("Couldn't save conversation: \(error.localizedDescription)")
        }
    }

    /// "Thu 1:03 PM", sent in front of follow-ups.
    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE h:mm a"
        return formatter.string(from: date)
    }

    private static func seconds(since start: Date) -> String {
        "\(Int(Date().timeIntervalSince(start).rounded())) s"
    }

    /// The error without any text from the API, which could echo the question.
    private static func logLabel(_ error: CoachError) -> String {
        switch error {
        case .http(let status, _): return "HTTP \(status)"
        case .blank(let info): return "blank answer twice, \(info.summary)"
        default: return "\(error)"
        }
    }
}

extension ActivityLog {
    var interventionLog: InterventionLog {
        InterventionLog(interventionID: interventionID, title: displayTitle, timestamp: timestamp,
                        intensityBefore: intensityBefore, intensityAfter: intensityAfter, kind: activityKind)
    }
}
