import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Coach answers read out loud with an ElevenLabs voice. This part decides what
/// gets said, in pieces small enough that the first one plays within a couple of
/// seconds while the rest are fetched behind it.
public enum ReadAloud {
    /// Longest piece sent in one request. Multilingual v2 takes 10,000 characters,
    /// but smaller pieces come back sooner.
    public static let maxPiece = 1200
    /// The first piece is kept shorter still, so playback starts fast.
    public static let firstPiece = 500

    /// A coach answer: crisis line first if needed, then the read, one piece per
    /// step, then what to skip and when to see a doctor. Sources stay on screen.
    public static func pieces(_ reply: CoachReply) -> [String] {
        var parts: [String] = []
        if reply.crisis {
            parts.append("If you're thinking about hurting yourself, you don't have to handle it alone. Call or text 988, any time. In an emergency, call 911.")
        }
        parts.append(sentence(plainText(reply.summary)))
        for (index, step) in reply.steps.enumerated() {
            var words = ["Step \(index + 1): \(sentence(plainText(step.title)))"]
            if step.minutes > 0 { words.append(step.minutes == 1 ? "1 minute." : "\(step.minutes) minutes.") }
            words.append(sentence(plainText(step.how)))
            words.append(sentence(plainText(step.why)))
            parts.append(words.filter { !$0.isEmpty }.joined(separator: " "))
        }
        let after = [reply.avoid, reply.seeADoctor].map { sentence(plainText($0)) }.filter { !$0.isEmpty }
        if !after.isEmpty { parts.append(after.joined(separator: " ")) }
        return pack(parts.filter { !$0.isEmpty }, merge: false)
    }

    /// A chat answer (Markdown): paragraphs, packed into pieces.
    public static func pieces(markdown: String) -> [String] {
        let paragraphs = plainText(markdown)
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return pack(paragraphs, merge: true)
    }

    /// Markdown to something a voice can read: link text without the address, no
    /// bare URLs, no emphasis marks, headings or bullets. List items end in a
    /// full stop so the voice pauses. Paragraphs stay apart on blank lines.
    public static func plainText(_ markdown: String) -> String {
        var text = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        text = replace(#"```[^\n]*\n?"#, in: text, with: "")
        text = replace(#"`([^`]*)`"#, in: text, with: "$1")
        text = replace(#"!?\[([^\]]*)\]\([^)]*\)"#, in: text, with: "$1")
        text = replace(#"<?https?://[^\s>)]+>?"#, in: text, with: "")
        text = replace(#"(\*\*|__)(.+?)\1"#, in: text, with: "$2")
        text = replace(#"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])"#, in: text, with: "$1")
        text = replace(#"(?<!\w)_(?!\s)(.+?)(?<!\s)_(?!\w)"#, in: text, with: "$1")

        var paragraphs: [String] = []
        var lines: [String] = []
        func endParagraph() {
            if !lines.isEmpty { paragraphs.append(lines.joined(separator: " ")) }
            lines = []
        }
        for raw in text.components(separatedBy: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.allSatisfy({ "-*_=".contains($0) }) {
                endParagraph()
                continue
            }
            let heading = line.hasPrefix("#")
            line = replace(#"^#{1,6}\s*"#, in: line, with: "")
            let bullet = line.range(of: #"^([-*•+]|\d+[.)])\s+"#, options: .regularExpression)
            if let bullet { line.removeSubrange(bullet) }
            line = replace(#"\s{2,}"#, in: line, with: " ").trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if heading || bullet != nil {
                // Its own sentence, so "Why" and "- Walk" don't run into the next line.
                lines.append(sentence(line))
                if heading { endParagraph() }
            } else {
                lines.append(line)
            }
        }
        endParagraph()
        return paragraphs.joined(separator: "\n\n")
    }

    /// Same text, voice and format, same audio: the cache's file name.
    public static func cacheKey(_ text: String, voiceID: String, model: String = ElevenLabsRequest.model,
                                format: String = ElevenLabsRequest.outputFormat) -> String {
        hash("\(model)|\(format)|\(voiceID)|\(text)")
    }

    /// One id for a whole answer, so every play button for it shows the same state.
    public static func id(_ pieces: [String]) -> String {
        hash(pieces.joined(separator: "\u{1E}"))
    }

    /// FNV-1a, 64 bit: stable across launches and platforms, unlike `hashValue`.
    static func hash(_ text: String) -> String {
        var value: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            value ^= UInt64(byte)
            value = value &* 0x100000001b3
        }
        let hex = String(value, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }

    /// Ends in a full stop unless it already ends a sentence.
    static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return "" }
        return ".!?:;…".contains(last) ? trimmed : trimmed + "."
    }

    /// Splits anything too long at sentence ends; with `merge`, joins short
    /// paragraphs up to the limit. The first piece gets the smaller limit.
    static func pack(_ parts: [String], merge: Bool) -> [String] {
        var pieces: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty { pieces.append(current) }
            current = ""
        }
        for part in parts {
            if !merge { flush() }
            for (index, unit) in split(part, limit: maxPiece).enumerated() {
                let joiner = index == 0 ? "\n\n" : " "
                let limit = pieces.isEmpty ? firstPiece : maxPiece
                if !current.isEmpty, current.count + joiner.count + unit.count <= limit {
                    current += joiner + unit
                } else {
                    flush()
                    current = unit
                }
            }
        }
        flush()
        // A long opening paragraph: say its first sentences on their own, so they start sooner.
        if let first = pieces.first, first.count > firstPiece {
            let head = split(first, limit: firstPiece)
            if head.count > 1 {
                pieces.replaceSubrange(0...0, with: [head[0], head.dropFirst().joined(separator: " ")])
            }
        }
        return pieces
    }

    /// Sentences, grouped up to `limit` characters. A sentence longer than the limit
    /// is cut at the last space before it.
    static func split(_ text: String, limit: Int) -> [String] {
        guard text.count > limit else { return [text] }
        var sentences: [String] = []
        var start = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            if ".!?".contains(text[index]), next == text.endIndex || text[next] == " " {
                sentences.append(String(text[start..<next]).trimmingCharacters(in: .whitespaces))
                start = next
            }
            index = next
        }
        let rest = String(text[start...]).trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { sentences.append(rest) }

        var groups: [String] = []
        var group = ""
        for var sentence in sentences {
            while sentence.count > limit {
                let cut = sentence.prefix(limit).lastIndex(of: " ") ?? sentence.index(sentence.startIndex, offsetBy: limit)
                if !group.isEmpty { groups.append(group); group = "" }
                groups.append(String(sentence[..<cut]))
                sentence = String(sentence[cut...]).trimmingCharacters(in: .whitespaces)
            }
            if group.isEmpty {
                group = sentence
            } else if group.count + 1 + sentence.count <= limit {
                group += " " + sentence
            } else {
                groups.append(group)
                group = sentence
            }
        }
        if !group.isEmpty { groups.append(group) }
        return groups
    }

    private static func replace(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}

/// How fast an answer plays. ElevenLabs makes it at normal speed once; the
/// phone speeds it up without raising the pitch, so changing speed costs nothing.
public enum PlaybackSpeed: Double, CaseIterable, Sendable {
    case normal = 1
    case faster = 1.5
    case double = 2

    public var label: String {
        switch self {
        case .normal: "1×"
        case .faster: "1.5×"
        case .double: "2×"
        }
    }

    /// The speed button cycles 1×, 1.5×, 2×, back to 1×.
    public var next: PlaybackSpeed {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

// MARK: - ElevenLabs

public struct ElevenLabsVoice: Codable, Equatable, Sendable, Identifiable {
    public var voiceID: String
    public var name: String
    /// premade, cloned, generated or professional.
    public var category: String?

    public var id: String { voiceID }

    public init(voiceID: String, name: String, category: String? = nil) {
        self.voiceID = voiceID
        self.name = name
        self.category = category
    }

    enum CodingKeys: String, CodingKey {
        case voiceID = "voice_id"
        case name
        case category
    }
}

public enum ElevenLabsError: Error, Equatable, Sendable {
    case noKey
    /// `code` is ElevenLabs' own: invalid_api_key, quota_exceeded, voice_not_found...
    case http(status: Int, code: String?, message: String)
    case notAudio

    public var userMessage: String {
        switch self {
        case .noKey:
            return "Add your ElevenLabs API key in Settings to listen."
        case .http(_, "quota_exceeded", _):
            return "Out of ElevenLabs credits for now. They refill with your plan, or add more at elevenlabs.io."
        case .http(_, "missing_permissions", _):
            return "This ElevenLabs key can't make speech. Give it Text to Speech access at elevenlabs.io."
        case .http(_, "voice_not_found", _), .http(404, _, _):
            return "That voice isn't available anymore. Pick another in Settings."
        case .http(401, _, _):
            return "ElevenLabs didn't accept the key. Check it in Settings."
        case .http(429, _, _):
            return "ElevenLabs is busy. Try again in a moment."
        case .http(let status, _, let message):
            return "ElevenLabs error \(status): \(message)"
        case .notAudio:
            return "ElevenLabs sent back something that isn't audio. Try again."
        }
    }
}

/// Raw HTTP for ElevenLabs, unit tested. Text to speech and the voice list only.
public enum ElevenLabsRequest {
    public static let base = URL(string: "https://api.elevenlabs.io")!
    /// The most natural long-form voice model. Flash v2.5 costs half, sounds flatter.
    public static let model = "eleven_multilingual_v2"
    /// MP3, 44.1 kHz, 128 kbps: ElevenLabs' default, plays everywhere.
    public static let outputFormat = "mp3_44100_128"
    /// George, a calm premade voice every account has, until you pick another.
    public static let defaultVoiceID = "JBFqnCBsd6RMkjVDRZzb"
    public static let defaultVoiceName = "George"

    public static func speech(_ text: String, voiceID: String, apiKey: String) throws -> URLRequest {
        var components = URLComponents(url: base.appendingPathComponent("v1/text-to-speech/\(voiceID)"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "output_format", value: outputFormat)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        let body: JSONValue = ["text": .string(text), "model_id": .string(model)]
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    public static func voices(apiKey: String) -> URLRequest {
        var components = URLComponents(url: base.appendingPathComponent("v2/voices"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "page_size", value: "100")]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 30
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        return request
    }

    /// `{"detail": {"status" or "code": ..., "message": ...}}`, `{"detail": "..."}`
    /// or a validation list `{"detail": [{"msg": ...}]}`.
    public static func error(status: Int, data: Data) -> ElevenLabsError {
        let json = try? JSONDecoder().decode(JSONValue.self, from: data)
        let detail = json?["detail"]
        let code = detail?["code"]?.stringValue ?? detail?["status"]?.stringValue
        let message = detail?["message"]?.stringValue
            ?? detail?.stringValue
            ?? detail?.arrayValue?.compactMap { $0["msg"]?.stringValue }.joined(separator: "; ")
            ?? String(decoding: data.prefix(200), as: UTF8.self)
        return .http(status: status, code: code, message: message)
    }

    /// MP3: an ID3 tag or a frame sync at the start.
    public static func isAudio(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(3))
        guard bytes.count == 3 else { return false }
        return bytes == Array("ID3".utf8) || (bytes[0] == 0xFF && bytes[1] & 0xE0 == 0xE0)
    }
}

public struct ElevenLabsClient: Sendable {
    private let transport: HTTPTransport
    private let apiKey: @Sendable () async throws -> String

    public init(transport: HTTPTransport, apiKey: @escaping @Sendable () async throws -> String) {
        self.transport = transport
        self.apiKey = apiKey
    }

    /// MP3 audio of `text`, spoken at normal speed.
    public func speech(_ text: String, voiceID: String) async throws -> Data {
        let request = try ElevenLabsRequest.speech(text, voiceID: voiceID, apiKey: try await key())
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw ElevenLabsRequest.error(status: response.statusCode, data: data)
        }
        guard ElevenLabsRequest.isAudio(data) else { throw ElevenLabsError.notAudio }
        return data
    }

    /// The voices on your account (premade ones included), by name.
    public func voices() async throws -> [ElevenLabsVoice] {
        let (data, response) = try await transport.send(ElevenLabsRequest.voices(apiKey: try await key()))
        guard (200..<300).contains(response.statusCode) else {
            throw ElevenLabsRequest.error(status: response.statusCode, data: data)
        }
        struct Page: Decodable { var voices: [ElevenLabsVoice] }
        return try JSONDecoder().decode(Page.self, from: data).voices
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func key() async throws -> String {
        let key = try await apiKey().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ElevenLabsError.noKey }
        return key
    }
}
