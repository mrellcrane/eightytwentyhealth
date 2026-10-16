import Foundation
import SwiftData
import EightyTwentyCore

/// Your Claude API key, in this phone's Keychain. Never in the app binary (the repo is public).
enum ClaudeKey {
    static let service = "eightytwenty.claude"
    private static let account = "apiKey"

    static func load() -> String {
        Keychain.data(for: account, service: service).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    static func save(_ key: String) -> Bool {
        Keychain.set(Data(key.utf8), for: account, service: service)
    }

    static func remove() {
        Keychain.delete(account, service: service)
    }
}

/// The Claude coach: builds what Claude sees from your data, keeps the current
/// conversation, and saves every question and answer as a `CoachLog`.
///
/// Logs carry status codes, timings and step counts only: never what you typed,
/// what Claude said, or the health numbers in the context.
@MainActor
@Observable
final class CoachService {
    private(set) var hasKey: Bool
    private(set) var conversation: CoachConversation?
    /// The `CoachLog` that holds `conversation`.
    private(set) var logID: UUID?
    private(set) var isThinking = false
    private(set) var errorMessage: String?
    /// "Look up studies" in progress or failed, by turn of the current conversation.
    private(set) var lookups: [Int: LookupState] = [:]

    enum LookupState: Equatable {
        case searching
        case failed(String)
    }

    private let client: CoachClient

    init(transport: HTTPTransport = URLSessionTransport()) {
        hasKey = !ClaudeKey.load().isEmpty
        client = CoachClient(transport: transport, apiKey: { ClaudeKey.load() })
    }

    // MARK: Key

    @discardableResult
    func saveKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, ClaudeKey.save(trimmed) else { return false }
        hasKey = true
        Log.coach.info("API key saved")
        return true
    }

    func removeKey() {
        ClaudeKey.remove()
        hasKey = false
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
        lookups = [:]
        persist(modelContext)
    }

    func followUp(_ question: String, modelContext: ModelContext) {
        guard var conversation, !conversation.awaitingReply else { return }
        conversation.followUp(question.trimmingCharacters(in: .whitespacesAndNewlines), at: Self.stamp(.now))
        self.conversation = conversation
        errorMessage = nil
        persist(modelContext)
    }

    /// Picks a saved conversation back up, to ask a follow-up.
    func resume(_ log: CoachLog) {
        conversation = log.record.conversation
        logID = log.id
        errorMessage = nil
        lookups = [:]
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
        lookups = [:]
    }

    /// Sends whatever is waiting for an answer. Also the retry after an error.
    func send(modelContext: ModelContext) async {
        guard let sent = conversation, sent.awaitingReply, !isThinking else { return }
        isThinking = true
        errorMessage = nil
        let started = Date()
        defer { isThinking = false }
        do {
            let (reply, text) = try await client.reply(to: sent)
            // You may have started a new question while this one was out.
            guard conversation == sent else { return }
            var answered = sent
            answered.record(reply, text: text)
            conversation = answered
            persist(modelContext)
            Log.coach.info("Answered turn \(answered.turns.count) in \(Self.seconds(since: started)): \(reply.steps.count) steps")
        } catch let error as CoachError {
            errorMessage = error.userMessage
            let summary = "Turn \(sent.turns.count) failed after \(Self.seconds(since: started)): \(Self.logLabel(error))"
            switch error {
            case .unauthorized, .rateLimited, .overloaded, .refused, .noKey: Log.coach.warning(summary)
            default: Log.coach.error(summary)
            }
        } catch {
            errorMessage = "Couldn't reach Claude: \(error.localizedDescription)"
            Log.coach.warning("Turn \(sent.turns.count) failed after \(Self.seconds(since: started)): \(error.localizedDescription)")
        }
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
            let result = try await client.lookUpStudies(question, known: Self.unique(shown + saved))
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
