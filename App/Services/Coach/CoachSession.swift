import Foundation
import EightyTwentyCore

enum CoachError: Error {
    case http(status: Int, message: String?)
    case refused

    var message: String {
        switch self {
        case .http(401, _): return "Claude didn't accept the API key. Change it in Settings > Coach."
        case .http(429, _): return "Too many requests for now. Try again in a minute."
        case .http(let status, let message): return "Claude error \(status): \(message ?? "no details")."
        case .refused: return "Claude declined that one. Try asking another way."
        }
    }
}

/// One conversation with the coach (Claude Haiku over the Messages API, streamed).
/// Lives on AppModel so it survives leaving the screen. What's said is never logged.
@MainActor
@Observable
final class CoachSession {
    struct Message: Identifiable {
        enum Role { case user, assistant }
        let id = UUID()
        let role: Role
        var text: String
    }

    private(set) var messages: [Message] = []
    private(set) var isReplying = false
    var error: String?

    /// What the API sees: a system prompt frozen at the first message, and every turn
    /// with assistant turns as their full content blocks (thinking included). Append-only,
    /// so the prompt cache holds and replayed thinking stays valid.
    private var system: String?
    private var history: [[String: Any]] = []

    // MARK: API key (Keychain, this device only)

    nonisolated private static let keyAccount = "anthropic-api-key"

    nonisolated static var hasKey: Bool { apiKey != nil }

    nonisolated private static var apiKey: String? {
        guard let data = Keychain.data(for: keyAccount) else { return nil }
        let key = String(decoding: data, as: UTF8.self)
        return key.isEmpty ? nil : key
    }

    nonisolated static func saveKey(_ key: String) {
        Keychain.set(Data(key.trimmingCharacters(in: .whitespacesAndNewlines).utf8), for: keyAccount)
    }

    nonisolated static func deleteKey() {
        Keychain.delete(keyAccount)
    }

    // MARK: Conversation

    func reset() {
        messages = []
        history = []
        system = nil
        error = nil
    }

    /// Sends `text`. Returns false if it didn't go through, so the view can restore the draft.
    func send(_ text: String, briefing: () -> String) async -> Bool {
        guard !isReplying, let key = Self.apiKey else { return false }
        if system == nil { system = briefing() }
        error = nil
        isReplying = true
        defer { isReplying = false }

        messages.append(Message(role: .user, text: text))
        messages.append(Message(role: .assistant, text: ""))
        history.append(["role": "user", "content": text])
        do {
            let content = try await stream(key: key)
            history.append(["role": "assistant", "content": content])
            return true
        } catch {
            // Undo the turn so the history stays valid for the next try.
            history.removeLast()
            messages.removeLast(2)
            self.error = (error as? CoachError)?.message ?? "Couldn't reach Claude: \(error.localizedDescription)"
            return false
        }
    }

    private func stream(key: String) async throws -> [[String: Any]] {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let body: [String: Any] = [
            "model": CoachBriefing.model,
            "max_tokens": 16000,
            "stream": true,
            "system": system ?? "",
            "messages": history,
            "output_config": ["effort": "medium"],
            // The system prompt and earlier turns never change, so the cache can carry them.
            "cache_control": ["type": "ephemeral"],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var raw = ""
            for try await line in bytes.lines {
                raw += line
                if raw.count > 4000 { break }
            }
            let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
            let apiError = json?["error"] as? [String: Any]
            Log.app.warning("Coach: HTTP \(status) \(apiError?["type"] as? String ?? "")")
            throw CoachError.http(status: status, message: apiError?["message"] as? String)
        }

        // Rebuild the content blocks from the stream: thinking blocks too, since they
        // go back to the API unchanged on the next turn.
        var blocks: [[String: Any]] = []
        var stopReason: String?
        var inputTokens = 0, cachedTokens = 0, outputTokens = 0
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let event = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                  let type = event["type"] as? String else { continue }
            switch type {
            case "message_start":
                let usage = (event["message"] as? [String: Any])?["usage"] as? [String: Any]
                inputTokens = usage?["input_tokens"] as? Int ?? 0
                cachedTokens = usage?["cache_read_input_tokens"] as? Int ?? 0
            case "content_block_start":
                if let block = event["content_block"] as? [String: Any] { blocks.append(block) }
            case "content_block_delta":
                guard let index = event["index"] as? Int, blocks.indices.contains(index),
                      let delta = event["delta"] as? [String: Any] else { continue }
                apply(delta, to: &blocks[index])
            case "message_delta":
                stopReason = (event["delta"] as? [String: Any])?["stop_reason"] as? String
                outputTokens = (event["usage"] as? [String: Any])?["output_tokens"] as? Int ?? outputTokens
            case "error":
                let message = (event["error"] as? [String: Any])?["message"] as? String
                throw CoachError.http(status: 0, message: message)
            default:
                continue
            }
        }
        Log.app.info("Coach reply: stop \(stopReason ?? "none"), \(inputTokens) in, \(cachedTokens) cached, \(outputTokens) out")
        if stopReason == "refusal" { throw CoachError.refused }
        return blocks
    }

    private func apply(_ delta: [String: Any], to block: inout [String: Any]) {
        switch delta["type"] as? String {
        case "text_delta":
            let text = delta["text"] as? String ?? ""
            block["text"] = (block["text"] as? String ?? "") + text
            if let last = messages.indices.last { messages[last].text += text }
        case "thinking_delta":
            block["thinking"] = (block["thinking"] as? String ?? "") + (delta["thinking"] as? String ?? "")
        case "signature_delta":
            block["signature"] = (block["signature"] as? String ?? "") + (delta["signature"] as? String ?? "")
        default:
            break
        }
    }
}
