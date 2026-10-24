import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What Claude sends back: a short read of what's going on and 1-3 things to do.
/// Enforced by a JSON schema (`CoachRequest.replySchema`), so it always decodes.
public struct CoachReply: Codable, Equatable, Sendable {
    public struct Step: Codable, Equatable, Sendable {
        public var title: String
        public var minutes: Int
        /// Exactly how to do it.
        public var how: String
        /// The evidence, in plain words.
        public var why: String
        /// The effect, short: "about 2.5 h more alertness".
        public var effect: String
        /// "Brooks & Lack 2006, Sleep", or empty when it rests on basic physiology.
        public var source: String
        /// An `Intervention.id`, or "none".
        public var catalogID: String
        /// An `ActivityKind` raw value, or "other".
        public var logAs: String

        public init(title: String, minutes: Int, how: String, why: String, effect: String, source: String,
                    catalogID: String, logAs: String) {
            self.title = title
            self.minutes = minutes
            self.how = how
            self.why = why
            self.effect = effect
            self.source = source
            self.catalogID = catalogID
            self.logAs = logAs
        }

        public var intervention: Intervention? { Intervention.find(catalogID) }
        public var activityKind: ActivityKind { ActivityKind(rawValue: logAs) ?? .other }
    }

    public var summary: String
    public var steps: [Step]
    /// Something to skip right now, or empty.
    public var avoid: String
    /// When to get it checked, or empty.
    public var seeADoctor: String
    /// Anything suggesting risk of harm. The app then shows crisis lines first.
    public var crisis: Bool

    public init(summary: String, steps: [Step], avoid: String, seeADoctor: String, crisis: Bool) {
        self.summary = summary
        self.steps = steps
        self.avoid = avoid
        self.seeADoctor = seeADoctor
        self.crisis = crisis
    }

    /// The schema holds but there's nothing to show: no summary, or a step with no title.
    /// Claude once answered with every field empty, which drew a blank "1." card.
    public var isBlank: Bool {
        summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || steps.contains { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

/// How an answer came back, for the log: no text, only counts and names.
public struct CoachReplyInfo: Equatable, Sendable {
    public var stopReason: String?
    /// The model that wrote the answer.
    public var model: String?
    public var inputTokens = 0
    public var cachedTokens = 0
    public var outputTokens = 0
    /// Another model answered after the first declined.
    public var fellBack = false
    /// Blank answers thrown away before this one.
    public var blankRetries = 0

    public init() {}

    init(_ json: JSONValue) {
        stopReason = json["stop_reason"]?.stringValue
        model = json["model"]?.stringValue
        let usage = json["usage"]
        inputTokens = usage?["input_tokens"]?.intValue ?? 0
        cachedTokens = usage?["cache_read_input_tokens"]?.intValue ?? 0
        outputTokens = usage?["output_tokens"]?.intValue ?? 0
        // The block marks a switch this turn; usage.iterations also covers turns sent straight to the fallback model.
        fellBack = (usage?["iterations"]?.arrayValue ?? []).contains { $0["type"]?.stringValue == "fallback_message" }
            || (json["content"]?.arrayValue ?? []).contains { $0["type"]?.stringValue == "fallback" }
    }

    public var summary: String {
        "stop \(stopReason ?? "none"), \(model ?? "unknown model"), \(inputTokens) in, \(cachedTokens) cached, \(outputTokens) out"
            + (fellBack ? ", after a fallback" : "")
            + (blankRetries > 0 ? ", after \(blankRetries) blank" : "")
    }
}

public enum CoachError: Error, Equatable, Sendable {
    case noKey
    case unauthorized
    case rateLimited
    case overloaded
    case refused
    case truncated
    case badReply
    /// Blank twice in a row (`CoachReply.isBlank`). Carries the second one's info for the log.
    case blank(CoachReplyInfo)
    case http(status: Int, message: String)

    public var userMessage: String {
        switch self {
        case .noKey: return "Add your Claude API key in Settings first."
        case .unauthorized: return "Claude didn't accept the API key. Check it in Settings."
        case .rateLimited: return "Claude is rate limiting this key. Try again in a minute."
        case .overloaded: return "Claude is busy right now. Try again in a minute."
        case .refused: return "Claude declined to answer that one. Try putting it another way."
        case .truncated: return "The answer got cut off. Try again."
        case .badReply: return "Couldn't read Claude's answer. Try again."
        case .blank: return "Claude came back with an empty answer. Try again, or put it another way."
        case .http(let status, let message): return "Claude API error \(status): \(message)"
        }
    }
}

/// One back-and-forth with the coach. Append-only: each follow-up adds a user
/// message after Claude's last reply, so earlier turns are sent back unchanged.
/// The turns are the whole state, so a saved conversation (`CoachRecord`)
/// rebuilds the exact same messages.
public struct CoachConversation: Equatable, Sendable {
    public struct Turn: Codable, Equatable, Sendable {
        public var question: String
        public var askedAt: Date
        /// "Thu 1:03 PM" on follow-ups, sent in front of the question. Nil on the first turn.
        public var stamp: String?
        public var reply: CoachReply?
        /// Claude's exact JSON text, replayed on follow-ups.
        public var replyText: String?
        /// Studies from "Look up studies" on this answer. Shown with it, never sent back to Claude.
        public var studies: [Study]?
        /// Steps of this answer you logged with "Did it", and when.
        public var logged: [LoggedStep]?

        public struct LoggedStep: Codable, Equatable, Sendable {
            /// Index into `reply.steps`.
            public var step: Int
            public var at: Date

            public init(step: Int, at: Date) {
                self.step = step
                self.at = at
            }
        }

        /// When step `index` was last logged, if ever.
        public func loggedAt(step index: Int) -> Date? {
            logged?.last { $0.step == index }?.at
        }

        public mutating func markLogged(step index: Int, at date: Date) {
            guard let reply, reply.steps.indices.contains(index) else { return }
            logged = (logged ?? []) + [LoggedStep(step: index, at: date)]
        }

        public init(question: String, askedAt: Date, stamp: String? = nil, reply: CoachReply? = nil, replyText: String? = nil,
                    studies: [Study]? = nil) {
            self.question = question
            self.askedAt = askedAt
            self.stamp = stamp
            self.reply = reply
            self.replyText = replyText
            self.studies = studies
        }
    }

    public let context: String
    public private(set) var turns: [Turn]

    /// The first message carries the context (time, Oura, logs) ahead of the question.
    public init(context: String, question: String, askedAt: Date = Date()) {
        self.context = context
        self.turns = [Turn(question: question, askedAt: askedAt)]
    }

    /// Picks a saved conversation back up. Turns after the first one without an
    /// answer are dropped, since nothing can follow an unanswered question.
    public init?(context: String, turns: [Turn]) {
        guard !turns.isEmpty else { return nil }
        var kept: [Turn] = []
        for turn in turns {
            kept.append(turn)
            if turn.reply == nil || turn.replyText == nil { break }
        }
        self.context = context
        self.turns = kept
    }

    public var awaitingReply: Bool { turns.last?.replyText == nil }

    public var messages: [JSONValue] {
        var messages: [JSONValue] = []
        for (index, turn) in turns.enumerated() {
            let text = index == 0
                ? "<context>\n\(context)\n</context>\n\nWhat's going on:\n\(turn.question)"
                : "[\(turn.stamp ?? "")] \(turn.question)"
            messages.append(["role": "user", "content": .string(text)])
            // Thinking blocks aren't replayed: there are no tools here, so nothing
            // needs them, and leaving all of them out keeps the history valid.
            if let replyText = turn.replyText {
                messages.append(["role": "assistant", "content": [["type": "text", "text": .string(replyText)]]])
            }
        }
        return messages
    }

    /// Records Claude's answer. `text` is the exact JSON text Claude returned.
    public mutating func record(_ reply: CoachReply, text: String) {
        guard awaitingReply else { return }
        turns[turns.count - 1].reply = reply
        turns[turns.count - 1].replyText = text
    }

    public mutating func markLogged(step: Int, turn index: Int, at date: Date) {
        guard turns.indices.contains(index) else { return }
        turns[index].markLogged(step: step, at: date)
    }

    public mutating func attachStudies(_ studies: [Study], toTurn index: Int) {
        guard turns.indices.contains(index) else { return }
        turns[index].studies = studies
    }

    /// What to look up for a turn: a follow-up only makes sense with the first question.
    public func lookupQuestion(forTurn index: Int) -> String {
        guard turns.indices.contains(index) else { return "" }
        return index == 0 ? turns[0].question : turns[0].question + "\n" + turns[index].question
    }

    /// A follow-up like "I can't nap at work". Stamped with the time, since it may come later.
    public mutating func followUp(_ question: String, at stamp: String, askedAt: Date = Date()) {
        guard !awaitingReply else { return }
        turns.append(Turn(question: question, askedAt: askedAt, stamp: stamp))
    }
}

/// A saved coach conversation: your questions, what Claude saw, and its answers.
/// Lives in the synced store and the JSON backup, never in logs.
public struct CoachRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var startedAt: Date
    public var context: String
    public var turns: [CoachConversation.Turn]
    public var deletedAt: Date?

    public init(id: UUID, startedAt: Date, context: String, turns: [CoachConversation.Turn], deletedAt: Date? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.context = context
        self.turns = turns
        self.deletedAt = deletedAt
    }

    public init(id: UUID, conversation: CoachConversation) {
        self.init(id: id, startedAt: conversation.turns.first?.askedAt ?? Date(), context: conversation.context,
                  turns: conversation.turns)
    }

    public var conversation: CoachConversation? { CoachConversation(context: context, turns: turns) }

    public static func encodeTurns(_ turns: [CoachConversation.Turn]) -> Data {
        (try? BackupDocument.encoder().encode(turns)) ?? Data()
    }

    public static func decodeTurns(_ data: Data) -> [CoachConversation.Turn] {
        (try? BackupDocument.decoder().decode([CoachConversation.Turn].self, from: data)) ?? []
    }
}

/// Builds the Messages API request. Pure, so it's unit tested.
public enum CoachRequest {
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let model = "claude-opus-5-5"
    /// Server-side fallback: if a safety classifier declines, Anthropic retries on a
    /// fallback model instead of returning a refusal.
    public static let fallbackBeta = "server-side-fallback-2026-07-01"

    public static func urlRequest(_ conversation: CoachConversation, apiKey: String, fallbacks: Bool = true) throws -> URLRequest {
        try urlRequest(body: body(conversation, fallbacks: fallbacks), apiKey: apiKey, fallbacks: fallbacks, timeout: 120)
    }

    /// Headers and body for any coach call (answers and study lookups).
    public static func urlRequest(body: JSONValue, apiKey: String, fallbacks: Bool, timeout: TimeInterval) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if fallbacks {
            request.setValue(fallbackBeta, forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    public static func body(_ conversation: CoachConversation, fallbacks: Bool = true) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(model),
            "max_tokens": 16000,
            "system": .string(systemPrompt),
            "messages": .array(conversation.messages),
            "output_config": [
                // Opus 5.5 thinks adaptively; medium is plenty for picking 1-3 steps.
                "effort": "medium",
                "format": ["type": "json_schema", "schema": replySchema],
            ],
        ]
        if fallbacks {
            body["fallbacks"] = "default"
        }
        return .object(body)
    }

    public static var replySchema: JSONValue {
        let catalogIDs = Intervention.catalog.map { JSONValue.string($0.id) } + ["none"]
        let kinds = ActivityKind.allCases.map { JSONValue.string($0.rawValue) }
        let step: JSONValue = [
            "type": "object",
            "properties": [
                "title": ["type": "string", "description": "Short imperative, e.g. 'Take a 10-minute nap'."],
                "minutes": ["type": "integer", "description": "Minutes of effort."],
                "how": ["type": "string", "description": "Exactly how to do it, 1-3 sentences."],
                "why": ["type": "string", "description": "The evidence in plain words, tied to their data."],
                "effect": ["type": "string", "description": "Short expected effect, with the study's number only if you're sure of it."],
                "source": ["type": "string", "description": "First author, year, journal. Empty if basic physiology."],
                "catalogID": ["type": "string", "enum": .array(catalogIDs)],
                "logAs": ["type": "string", "enum": .array(kinds)],
            ],
            "required": ["title", "minutes", "how", "why", "effect", "source", "catalogID", "logAs"],
            "additionalProperties": false,
        ]
        return [
            "type": "object",
            "properties": [
                "summary": ["type": "string", "description": "1-3 sentences: what's most likely going on, naming the numbers that explain it."],
                "steps": ["type": "array", "items": step, "description": "1 to 3 steps, best first."],
                "avoid": ["type": "string", "description": "One thing to skip right now, or empty."],
                "seeADoctor": ["type": "string", "description": "When to get this checked, or empty."],
                "crisis": ["type": "boolean"],
            ],
            "required": ["summary", "steps", "avoid", "seeADoctor", "crisis"],
            "additionalProperties": false,
        ]
    }

    public static var systemPrompt: String {
        """
        You're the coach inside 80/20 Health, a personal iPhone app with one user. They tell you what they're dealing with: mood, stress, energy, sleep, aches, focus, motivation, anything. You give them the few highest-leverage things to do about it, backed by research.

        Read the context and use it:
        - It has the local time, their work hours, their target bedtime and coffee cutoff, last night's sleep and recovery from their Oura ring, yesterday's activity, what they've logged, and anything they've rated before.
        - Name the specific numbers that explain what's happening (a short night, a hard workout yesterday, HRV below their usual). Say plainly when the data looks normal and doesn't explain it.
        - Think through the usual causes before choosing steps, and lead with the ones their data and timing support. For low energy or a headache: the early-afternoon dip in alertness, food (what and when they last ate), fluids, caffeine (wearing off, or less than usual), screens and posture, last night's sleep, yesterday's training, getting sick.
        - Don't ask questions. If a fact you don't have would change the advice (whether they've eaten, how much coffee they usually drink), give the advice for the likely case and say in a few words what to do otherwise. When you assume something they didn't say (that they had coffee this morning), make it an "if".

        Fit the plan to right now:
        - During work hours, suggest things they can do at a desk or on a short break, and help them get through the rest of the workday.
        - Protect tonight's sleep. Caffeine only before the coffee cutoff in the context; if it has passed, no caffeine. Naps about 10 minutes and done before about 4 PM. No hard exercise in the last few hours before bed.
        - Give 1 to 3 steps, best first. Each step is one action, and each is a different kind of thing. Prefer cheap, fast moves they can start in the next 15 minutes. Don't put alternatives in one step ("nap or coffee").

        Evidence:
        - Ground every step in evidence. Prefer meta-analyses and randomized trials. Cite only studies you're confident exist (first author, year, journal). Quote a number only if it comes from that study and you're sure of it; otherwise describe the size in words. Never invent a study or a statistic. If a step rests on basic physiology rather than a specific study, say so and leave source empty.
        - The facts and the catalog below were checked against the papers. Prefer them when they fit.
        - When a step is a catalog entry, set catalogID to its id so the app shows the checked figure. Otherwise use "none". Set logAs to the closest activity kind, or "other".
        - If they've rated things they tried before (0-10, before → after, lower is better), favor what worked for them and say so.
        - The context may list studies from their library, found by web search on an earlier question. When one fits, cite it, with source written exactly as listed, so the app can link it.

        How to write it:
        - Talk to them as "you". A smart friend who knows the research: warm, direct, brief. No therapy-speak, no "it sounds like", no lecturing, no padding.
        - It's read on a phone. summary: up to 3 sentences. how and why: 1 or 2 sentences each. effect: a short phrase with the size and how long it lasts when known.

        Safety:
        - You're not their doctor. If symptoms might need medical attention, say when in seeADoctor (for a headache: sudden or worst-ever, with fever or a stiff neck, vision changes, confusion, weakness or numbness, after a head injury, or getting steadily worse). Otherwise leave it empty.
        - If anything suggests they might hurt themselves or someone else, set crisis to true and, in summary, tell them warmly and clearly to call or text 988 (Suicide & Crisis Lifeline, US) or call 911 now.

        Follow-ups continue the conversation. Adjust the plan to what they tell you (for example "I can't nap at work"): drop what doesn't work for them, keep what still fits, and bring in the next-best option instead of repeating the plan.

        Checked facts:
        - The post-lunch dip is a real circadian dip in alertness in the early afternoon. It happens even without lunch, and a high-carbohydrate lunch deepens it (Monk 2005, Clinics in Sports Medicine).
        - Across 24 studies, caffeine cut total sleep by 45 minutes and sleep efficiency by 7%. To avoid losing sleep, a regular coffee (107 mg) needs to be at least 8.8 hours before bed, a 217 mg pre-workout drink at least 13.2 hours (Gardiner 2023, Sleep Medicine Reviews). 400 mg taken 6 hours before bed still disrupted sleep (Drake 2013, Journal of Clinical Sleep Medicine).
        - Losing 1.36% of body weight in fluid worsened mood and concentration and brought on fatigue and headache in young women (Armstrong 2012, Journal of Nutrition).
        - Of 5, 10, 20 and 30-minute afternoon naps after a short night, 10 minutes worked best: improvements right away, some lasting 155 minutes. 30 minutes caused grogginess first (Brooks & Lack 2006, Sleep).
        - 10 minutes of stair walking raised vigor more than 50 mg of caffeine in sleep-deprived young women (Randolph & O'Connor 2017, Physiology & Behavior).

        Checked catalog (id: title, minutes, effect, study):
        \(catalogSummary)
        """
    }

    static var catalogSummary: String {
        Intervention.catalog.map { item in
            "- \(item.id): \(item.title), \(Int(item.minutes)) min, \(item.headline) "
                + "(\(item.timing == .rightAway ? "right after one session" : "after a few weeks of practice")), "
                + "\(item.evidence.citation)"
        }
        .joined(separator: "\n")
    }
}

/// Sends a conversation to Claude and reads the reply.
public struct CoachClient: Sendable {
    private let transport: HTTPTransport
    private let apiKey: @Sendable () async throws -> String

    public init(transport: HTTPTransport, apiKey: @escaping @Sendable () async throws -> String) {
        self.transport = transport
        self.apiKey = apiKey
    }

    /// Returns the reply plus the raw JSON text to record in the conversation.
    /// A blank answer is asked again once; it's never recorded.
    public func reply(to conversation: CoachConversation) async throws -> (reply: CoachReply, text: String, info: CoachReplyInfo) {
        let key = try await apiKey()
        guard !key.isEmpty else { throw CoachError.noKey }
        let first = try await send(conversation, key: key)
        guard first.reply.isBlank else { return first }
        var second = try await send(conversation, key: key)
        second.info.blankRetries = 1
        guard !second.reply.isBlank else { throw CoachError.blank(second.info) }
        return second
    }

    private func send(_ conversation: CoachConversation, key: String) async throws -> (reply: CoachReply, text: String, info: CoachReplyInfo) {
        do {
            return try await send(conversation, key: key, fallbacks: true)
        } catch CoachError.http(400, let message) where message.localizedCaseInsensitiveContains("fallback") {
            // The fallback beta is the newest part of the request. If the API ever
            // rejects it, an answer without it still beats an error.
            return try await send(conversation, key: key, fallbacks: false)
        }
    }

    private func send(_ conversation: CoachConversation, key: String, fallbacks: Bool) async throws -> (reply: CoachReply, text: String, info: CoachReplyInfo) {
        let request = try CoachRequest.urlRequest(conversation, apiKey: key, fallbacks: fallbacks)
        let (data, response) = try await transport.send(request)
        return try Self.parse(data, status: response.statusCode)
    }

    public static func parse(_ data: Data, status: Int) throws -> (reply: CoachReply, text: String, info: CoachReplyInfo) {
        let json = try checked(data, status: status)
        switch json["stop_reason"]?.stringValue {
        case "refusal": throw CoachError.refused
        case "max_tokens": throw CoachError.truncated
        default: break
        }
        guard let reply = try? JSONDecoder().decode(CoachReply.self, from: Data(text(of: json).utf8)) else {
            throw CoachError.badReply
        }
        return (reply, text(of: json), CoachReplyInfo(json))
    }

    /// Structured output arrives as text blocks; thinking, tool and fallback blocks are skipped.
    static func text(of json: JSONValue) -> String {
        (json["content"]?.arrayValue ?? [])
            .filter { $0["type"]?.stringValue == "text" }
            .compactMap { $0["text"]?.stringValue }
            .joined()
    }

    /// The response JSON, or the matching `CoachError` for an HTTP error.
    static func checked(_ data: Data, status: Int) throws -> JSONValue {
        guard (200..<300).contains(status) else { throw error(status: status, body: data) }
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { throw CoachError.badReply }
        return json
    }

    /// The `CoachError` for an HTTP error response.
    public static func error(status: Int, body data: Data) -> CoachError {
        let json = try? JSONDecoder().decode(JSONValue.self, from: data)
        let type = json?["error"]?["type"]?.stringValue
        let message = json?["error"]?["message"]?.stringValue ?? String(decoding: data.prefix(200), as: UTF8.self)
        switch (status, type) {
        case (401, _), (_, "authentication_error"): return .unauthorized
        case (429, _): return .rateLimited
        case (529, _), (_, "overloaded_error"): return .overloaded
        default: return .http(status: status, message: message)
        }
    }

    // MARK: Study lookup

    /// Searches the web for studies on `question`, skipping the ones in `known`.
    /// Only the question is sent, no health data.
    public func lookUpStudies(_ question: String, known: [Study], now: Date = Date()) async throws -> StudyLookupResult {
        let key = try await apiKey()
        guard !key.isEmpty else { throw CoachError.noKey }
        do {
            return try await lookUp(question, known: known, key: key, fallbacks: true, now: now)
        } catch CoachError.http(400, let message) where message.localizedCaseInsensitiveContains("fallback") {
            return try await lookUp(question, known: known, key: key, fallbacks: false, now: now)
        }
    }

    private func lookUp(_ question: String, known: [Study], key: String, fallbacks: Bool, now: Date) async throws -> StudyLookupResult {
        var messages: [JSONValue] = [StudyLookupRequest.userMessage(question, known: known)]
        var seen = StudyLookupRequest.SearchResults()
        // A long search turn can pause; sending the partial turn back resumes it.
        for _ in 0...StudyLookupRequest.maxContinuations {
            let body = StudyLookupRequest.body(messages: messages, fallbacks: fallbacks)
            let request = try CoachRequest.urlRequest(body: body, apiKey: key, fallbacks: fallbacks,
                                                      timeout: StudyLookupRequest.timeout)
            let (data, response) = try await transport.send(request)
            let json = try Self.checked(data, status: response.statusCode)
            seen.add(json)
            switch json["stop_reason"]?.stringValue {
            case "pause_turn":
                messages.append(["role": "assistant", "content": json["content"] ?? []])
            case "refusal":
                throw CoachError.refused
            case "max_tokens":
                throw CoachError.truncated
            default:
                return try StudyLookupRequest.parse(Self.text(of: json), seen: seen, now: now)
            }
        }
        throw CoachError.truncated
    }

}
