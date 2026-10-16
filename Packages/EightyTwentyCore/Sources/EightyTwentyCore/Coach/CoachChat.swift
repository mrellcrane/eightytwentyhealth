import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Talking an answer through once it's in: why that step, the research behind it,
/// what if. The answer stays saved in its `CoachLog`; this chat lives only while the
/// Ask screen is open.
///
/// It continues the answer's conversation, so Claude has the same context and its
/// own answer. The chat instructions ride in the first chat message, and turns are
/// append-only, so the prompt cache carries everything before the newest question.
public struct CoachChat: Equatable, Sendable {
    public struct Turn: Equatable, Sendable {
        public var question: String
        /// "Thu 1:03 PM", sent in front of the question.
        public var stamp: String
        /// Grows as the answer streams in.
        public var answer: String
        public var isAnswered: Bool
    }

    public let base: CoachConversation
    /// Studies found for the answer, so Claude can talk about them.
    public let studies: [Study]
    public private(set) var turns: [Turn] = []

    /// Nil until the answer is in: there's nothing to talk about yet.
    public init?(base: CoachConversation, studies: [Study] = []) {
        guard !base.awaitingReply else { return nil }
        self.base = base
        self.studies = studies
    }

    public var awaitingReply: Bool { turns.last.map { !$0.isAnswered } ?? false }

    public mutating func ask(_ question: String, at stamp: String) {
        guard !awaitingReply else { return }
        turns.append(Turn(question: question, stamp: stamp, answer: "", isAnswered: false))
    }

    /// Streamed text, as it arrives.
    public mutating func receive(_ text: String) {
        guard awaitingReply else { return }
        turns[turns.count - 1].answer += text
    }

    /// The whole answer, once the stream ends.
    public mutating func finish(_ answer: String) {
        guard awaitingReply else { return }
        turns[turns.count - 1].answer = answer
        turns[turns.count - 1].isAnswered = true
    }

    /// Takes back a question that got no answer, so the next one can go. Returns it for the draft.
    @discardableResult
    public mutating func withdraw() -> String? {
        guard awaitingReply else { return nil }
        return turns.removeLast().question
    }

    public var messages: [JSONValue] {
        var messages = base.messages
        for (index, turn) in turns.enumerated() {
            let question = "[\(turn.stamp)] \(turn.question)"
            let text = index == 0 ? "<chat>\n\(opening)\n</chat>\n\n\(question)" : question
            messages.append(["role": "user", "content": .string(text)])
            // Text only, like the answer before it: no thinking blocks are replayed.
            if turn.isAnswered {
                messages.append(["role": "assistant", "content": [["type": "text", "text": .string(turn.answer)]]])
            }
        }
        return messages
    }

    var opening: String {
        guard !studies.isEmpty else { return Self.instructions }
        let list = studies.map { "- \($0.citation). \($0.design). \($0.finding) \($0.url)" }.joined(separator: "\n")
        return "\(Self.instructions)\n\nStudies found for your answer. When one fits, cite it as listed:\n\(list)"
    }

    static let instructions = """
    They've read your answer and want to talk it through. From here on it's a conversation, not a new plan.
    - Reply in plain text, not JSON. No headings or tables; it's read on a phone. A few sentences, or a few short lines starting with "- " when you list things. Go longer only when they ask for depth.
    - Answer what they asked, directly. They may ask why you chose something, what the research shows, how it applies to them, or push back.
    - On research: name the study (first author, year, journal), who was in it, what it compared and how big the effect was. Quote a number only if you're sure it comes from that study. Say plainly when the evidence is thin, mixed, observational, or from people unlike them. Never invent a study, a number or a link.
    - Tie it to their numbers in the context when that helps.
    - If what they tell you changes the advice (they can't nap at work), say what to do instead in a sentence or two rather than repeating the plan.
    - The safety rules still hold: if anything suggests they might hurt themselves or someone else, tell them warmly to call or text 988 or call 911 now, and say when something needs a doctor.
    """
}

/// Builds the chat's Messages API request. Same model, system prompt and effort as
/// the answer, without its JSON format, streamed.
public enum CoachChatRequest {
    public static func body(_ chat: CoachChat, fallbacks: Bool = true, stream: Bool = true) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(CoachRequest.model),
            "max_tokens": 16000,
            "stream": .bool(stream),
            "system": .string(CoachRequest.systemPrompt),
            "messages": .array(chat.messages),
            "output_config": ["effort": "medium"],
            // Every turn resends the context and the earlier turns unchanged.
            "cache_control": ["type": "ephemeral"],
        ]
        if fallbacks {
            body["fallbacks"] = "default"
        }
        return .object(body)
    }

    public static func urlRequest(_ chat: CoachChat, apiKey: String, fallbacks: Bool = true) throws -> URLRequest {
        try CoachRequest.urlRequest(body: body(chat, fallbacks: fallbacks), apiKey: apiKey, fallbacks: fallbacks, timeout: 120)
    }
}

/// Reads a streamed Messages API reply one server-sent-event line at a time, keeping
/// the text. Thinking and `fallback` blocks are skipped: after a refusal is retried
/// on another model mid-answer, the stream carries on with the rest of the text.
public struct CoachStream: Sendable {
    public private(set) var text = ""
    public private(set) var stopReason: String?
    public private(set) var inputTokens = 0
    public private(set) var cachedTokens = 0
    public private(set) var outputTokens = 0
    /// Another model finished the answer after the first declined.
    public private(set) var fellBack = false

    private var textBlocks: Set<Int> = []

    public init() {}

    /// Returns the text this line adds, empty for anything else. Throws on an error event.
    @discardableResult
    public mutating func read(_ line: String) throws -> String {
        guard line.hasPrefix("data:") else { return "" }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let event = try? JSONDecoder().decode(JSONValue.self, from: Data(payload.utf8)),
              let type = event["type"]?.stringValue else { return "" }
        switch type {
        case "message_start":
            let usage = event["message"]?["usage"]
            inputTokens = usage?["input_tokens"]?.intValue ?? 0
            cachedTokens = usage?["cache_read_input_tokens"]?.intValue ?? 0
        case "content_block_start":
            guard let index = event["index"]?.intValue else { return "" }
            switch event["content_block"]?["type"]?.stringValue {
            case "text":
                textBlocks.insert(index)
                let initial = event["content_block"]?["text"]?.stringValue ?? ""
                text += initial
                return initial
            case "fallback":
                fellBack = true
            default:
                break
            }
        case "content_block_delta":
            guard let index = event["index"]?.intValue, textBlocks.contains(index),
                  event["delta"]?["type"]?.stringValue == "text_delta",
                  let delta = event["delta"]?["text"]?.stringValue else { return "" }
            text += delta
            return delta
        case "message_delta":
            stopReason = event["delta"]?["stop_reason"]?.stringValue ?? stopReason
            outputTokens = event["usage"]?["output_tokens"]?.intValue ?? outputTokens
        case "error":
            let message = event["error"]?["message"]?.stringValue ?? "no details"
            switch event["error"]?["type"]?.stringValue {
            case "overloaded_error": throw CoachError.overloaded
            case "rate_limit_error": throw CoachError.rateLimited
            default: throw CoachError.http(status: 0, message: message)
            }
        default:
            break
        }
        return ""
    }

    /// The finished answer, or why there isn't one.
    public func answer() throws -> String {
        switch stopReason {
        case "refusal": throw CoachError.refused
        case "max_tokens": throw CoachError.truncated
        case nil: throw CoachError.badReply
        default:
            let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !answer.isEmpty else { throw CoachError.badReply }
            return answer
        }
    }
}
