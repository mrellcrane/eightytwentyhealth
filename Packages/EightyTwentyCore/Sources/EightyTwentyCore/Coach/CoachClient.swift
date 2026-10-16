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
}

public enum CoachError: Error, Equatable, Sendable {
    case noKey
    case unauthorized
    case rateLimited
    case overloaded
    case refused
    case truncated
    case badReply
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
        case .http(let status, let message): return "Claude API error \(status): \(message)"
        }
    }
}

/// One back-and-forth with the coach. Append-only: each follow-up adds a user
/// message after Claude's last reply, so earlier turns are sent back unchanged.
public struct CoachConversation: Equatable, Sendable {
    public struct Turn: Equatable, Sendable {
        public let question: String
        public var reply: CoachReply?
    }

    public private(set) var messages: [JSONValue] = []
    public private(set) var turns: [Turn] = []

    /// The first message carries the context (time, Oura, logs) ahead of the question.
    public init(context: String, question: String) {
        let text = "<context>\n\(context)\n</context>\n\nWhat's going on:\n\(question)"
        messages = [["role": "user", "content": .string(text)]]
        turns = [Turn(question: question)]
    }

    public var awaitingReply: Bool { turns.last?.reply == nil }

    /// Records Claude's answer. `text` is the exact JSON text Claude returned; it's
    /// replayed as-is on follow-ups. Thinking blocks aren't replayed (no tools here,
    /// so nothing needs them, and dropping all of them keeps the history valid).
    public mutating func record(_ reply: CoachReply, text: String) {
        guard awaitingReply else { return }
        messages.append(["role": "assistant", "content": [["type": "text", "text": .string(text)]]])
        turns[turns.count - 1].reply = reply
    }

    /// A follow-up like "I can't nap at work". Stamped with the time, since it may come later.
    public mutating func followUp(_ question: String, at time: String) {
        guard !awaitingReply else { return }
        messages.append(["role": "user", "content": .string("[\(time)] \(question)")])
        turns.append(Turn(question: question))
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
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if fallbacks {
            request.setValue(fallbackBeta, forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONEncoder().encode(body(conversation, fallbacks: fallbacks))
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
        You're the coach inside 80/20 Health, a personal iPhone app with one user. They tell you what they're dealing with: mood, stress, energy, sleep, aches, focus, motivation, anything. You tell them the few highest-leverage things to do about it, backed by research.

        How to answer:
        - Read the context first: the local time, their work hours, their target bedtime, last night's sleep and recovery from their Oura ring, yesterday's activity, and what they've logged. Use it. Name the specific numbers that explain what's happening (a short night, a hard workout yesterday, HRV below their usual), and say plainly when the data looks normal and doesn't explain it.
        - Fit the plan to right now. During work hours, suggest things doable at a desk or on a short break, and help them get through the rest of the workday. Protect tonight's sleep: no caffeine within about 8 hours of their bedtime, no hard exercise close to it, no nap long or late enough to hurt it.
        - Give 1 to 3 steps, best first. Prefer cheap, fast, well-evidenced moves they can start in the next hour.
        - Ground every step in evidence. Prefer meta-analyses and randomized trials. Cite only studies you're confident exist (first author, year, journal). Quote a number only if it comes from that study and you're sure of it; otherwise describe the size in words. Never invent a study or a statistic. If a step rests on basic physiology rather than a specific study, say so and leave source empty.
        - The app has a catalog of interventions whose numbers were checked against the papers (below). When a step is one of them, set catalogID to its id so the app shows the checked figure. Otherwise use "none". Set logAs to the closest activity kind, or "other".
        - If they've rated things they tried before (0-10, before and after, lower is better), favor what worked for them and say so.
        - Tone: a smart friend who knows the research. Warm, direct, brief. No therapy-speak, no "it sounds like", no lecturing, no padding.
        - You're not their doctor. If they describe symptoms that need medical attention (a sudden severe or worst-ever headache, chest pain, fainting, confusion, weakness on one side, symptoms that keep getting worse), put that in seeADoctor. Otherwise leave it empty.
        - If anything suggests they might hurt themselves or someone else, set crisis to true and tell them warmly and clearly to call or text 988 (Suicide & Crisis Lifeline, US) or call emergency services now.
        - Follow-up messages continue the conversation. Adjust the plan to what they tell you (for example "I can't nap at work") instead of repeating it.

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
    public func reply(to conversation: CoachConversation) async throws -> (reply: CoachReply, text: String) {
        let key = try await apiKey()
        guard !key.isEmpty else { throw CoachError.noKey }
        do {
            return try await send(conversation, key: key, fallbacks: true)
        } catch CoachError.http(400, let message) where message.localizedCaseInsensitiveContains("fallback") {
            // The fallback beta is the newest part of the request. If the API ever
            // rejects it, an answer without it still beats an error.
            return try await send(conversation, key: key, fallbacks: false)
        }
    }

    private func send(_ conversation: CoachConversation, key: String, fallbacks: Bool) async throws -> (reply: CoachReply, text: String) {
        let request = try CoachRequest.urlRequest(conversation, apiKey: key, fallbacks: fallbacks)
        let (data, response) = try await transport.send(request)
        return try Self.parse(data, status: response.statusCode)
    }

    public static func parse(_ data: Data, status: Int) throws -> (reply: CoachReply, text: String) {
        let json = try? JSONDecoder().decode(JSONValue.self, from: data)
        guard (200..<300).contains(status) else {
            let type = json?["error"]?["type"]?.stringValue
            let message = json?["error"]?["message"]?.stringValue ?? String(decoding: data.prefix(200), as: UTF8.self)
            switch (status, type) {
            case (401, _), (_, "authentication_error"): throw CoachError.unauthorized
            case (429, _): throw CoachError.rateLimited
            case (529, _), (_, "overloaded_error"): throw CoachError.overloaded
            default: throw CoachError.http(status: status, message: message)
            }
        }
        guard let json else { throw CoachError.badReply }
        switch json["stop_reason"]?.stringValue {
        case "refusal": throw CoachError.refused
        case "max_tokens": throw CoachError.truncated
        default: break
        }
        // Structured output arrives as text blocks; thinking and fallback blocks are skipped.
        let text = (json["content"]?.arrayValue ?? [])
            .filter { $0["type"]?.stringValue == "text" }
            .compactMap { $0["text"]?.stringValue }
            .joined()
        guard let reply = try? JSONDecoder().decode(CoachReply.self, from: Data(text.utf8)) else {
            throw CoachError.badReply
        }
        return (reply, text)
    }
}
