import Foundation

/// A study the coach found. Saved in your library, so asking about the same
/// thing again cites it back instead of searching again.
public struct Study: Codable, Equatable, Identifiable, Sendable {
    /// The DOI if known, else the URL without its scheme. Dedupes across lookups.
    public var id: String
    /// "Kang et al. 2023, Frontiers in Neurology".
    public var citation: String
    public var title: String
    public var url: String
    public var doi: String?
    /// "Meta-analysis of 6 RCTs (927 people)".
    public var design: String
    /// The key result with its numbers, as the source states it.
    public var finding: String
    /// Words a future question would use: "meditation", "anxiety".
    public var keywords: [String]
    /// True only when its link (or DOI) appeared in that lookup's search results.
    public var foundBySearch: Bool
    public var foundAt: Date
    /// The topic of the lookup that found it.
    public var topic: String
    public var deletedAt: Date?

    public init(id: String, citation: String, title: String, url: String, doi: String?, design: String, finding: String,
                keywords: [String], foundBySearch: Bool, foundAt: Date, topic: String, deletedAt: Date? = nil) {
        self.id = id
        self.citation = citation
        self.title = title
        self.url = url
        self.doi = doi
        self.design = design
        self.finding = finding
        self.keywords = keywords
        self.foundBySearch = foundBySearch
        self.foundAt = foundAt
        self.topic = topic
        self.deletedAt = deletedAt
    }

    public static func key(doi: String?, url: String) -> String {
        if let doi = doi?.trimmingCharacters(in: .whitespaces).lowercased(), doi.hasPrefix("10.") { return doi }
        return StudyLookupRequest.normalized(url)
    }

    public var link: URL? { URL(string: url) }
}

public struct StudyLookupResult: Equatable, Sendable {
    public var topic: String
    public var keywords: [String]
    public var studies: [Study]
    public var searches: Int
}

/// The study lookup: a separate Claude call with the web search tool, run only
/// when you ask for it. Pure request building and parsing, so it's unit tested.
public enum StudyLookupRequest {
    public static let maxSearches = 5
    public static let maxContinuations = 3
    /// Searching takes about a minute.
    public static let timeout: TimeInterval = 180

    public static func userMessage(_ question: String, known: [Study]) -> JSONValue {
        var text = "What they're dealing with:\n\(question)"
        if !known.isEmpty {
            text += "\n\nAlready in their library, so don't look these up again; find other studies:\n"
                + known.map { "- \($0.citation): \($0.title)" }.joined(separator: "\n")
        }
        return ["role": "user", "content": .string(text)]
    }

    public static func body(messages: [JSONValue], fallbacks: Bool = true) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(CoachRequest.model),
            "max_tokens": 16000,
            "system": .string(systemPrompt),
            "messages": .array(messages),
            "tools": [["type": "web_search_20260209", "name": "web_search", "max_uses": .number(Double(maxSearches))]],
            "output_config": [
                "effort": "medium",
                "format": ["type": "json_schema", "schema": schema],
            ],
        ]
        if fallbacks {
            body["fallbacks"] = "default"
        }
        return .object(body)
    }

    public static var systemPrompt: String {
        """
        You find research for the coach in 80/20 Health, a personal health app with one user. Given what they're dealing with, search the web for the best evidence on what helps.

        - Prefer meta-analyses and randomized trials, recent where possible. PubMed, PMC, DOI and journal pages are the best sources.
        - Use up to \(maxSearches) searches. Plan them so they cover the main angles of the question.
        - Return 2 to 5 studies. Only include a study you saw in this turn's search results, never one from memory. For url, copy the exact URL of the search result where you saw it.
        - finding: the key result with its numbers (effect size, confidence interval, sample) and what it was compared with, as the source states it. Never write a number you didn't see. If the source gives no numbers, describe the result in words.
        - design: the type of study and its size, e.g. "Meta-analysis of 6 RCTs (927 people)".
        - topic: a short name for what the question is about. keywords: 3 to 8 lowercase single words someone would use when asking about this again (e.g. "headache", "caffeine", "meditation").
        - If the message lists studies already in their library, don't return those; look for what they don't cover yet.
        """
    }

    public static var schema: JSONValue {
        let study: JSONValue = [
            "type": "object",
            "properties": [
                "citation": ["type": "string", "description": "First author et al. year, journal."],
                "title": ["type": "string"],
                "url": ["type": "string", "description": "Exact URL from the search result."],
                "doi": ["type": "string", "description": "DOI like 10.1001/..., or empty if not shown."],
                "design": ["type": "string"],
                "finding": ["type": "string"],
            ],
            "required": ["citation", "title", "url", "doi", "design", "finding"],
            "additionalProperties": false,
        ]
        return [
            "type": "object",
            "properties": [
                "topic": ["type": "string"],
                "keywords": ["type": "array", "items": ["type": "string"]],
                "studies": ["type": "array", "items": study],
            ],
            "required": ["topic", "keywords", "studies"],
            "additionalProperties": false,
        ]
    }

    /// What the searches actually returned, to check each study against.
    public struct SearchResults: Equatable, Sendable {
        public private(set) var urls: Set<String> = []
        public private(set) var searches = 0

        public init() {}

        public mutating func add(_ response: JSONValue) {
            for block in response["content"]?.arrayValue ?? [] where block["type"]?.stringValue == "web_search_tool_result" {
                // Results are a list; an error is a single object.
                for result in block["content"]?.arrayValue ?? [] {
                    if let url = result["url"]?.stringValue { urls.insert(normalized(url)) }
                }
            }
            if case .number(let count)? = response["usage"]?["server_tool_use"]?["web_search_requests"] {
                searches += Int(count)
            }
        }

        func contains(url: String, doi: String?) -> Bool {
            if urls.contains(normalized(url)) { return true }
            guard let doi = doi?.lowercased(), doi.hasPrefix("10.") else { return false }
            return urls.contains { $0.contains(doi) }
        }
    }

    private struct Reply: Decodable {
        struct Item: Decodable {
            var citation: String
            var title: String
            var url: String
            var doi: String
            var design: String
            var finding: String
        }

        var topic: String
        var keywords: [String]
        var studies: [Item]
    }

    public static func parse(_ text: String, seen: SearchResults, now: Date) throws -> StudyLookupResult {
        guard let reply = try? JSONDecoder().decode(Reply.self, from: Data(text.utf8)) else { throw CoachError.badReply }
        let keywords = reply.keywords.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var studies: [Study] = []
        for item in reply.studies where URL(string: item.url)?.scheme?.hasPrefix("http") == true {
            let doi = item.doi.trimmingCharacters(in: .whitespaces).nilIfEmpty
            let study = Study(
                id: Study.key(doi: doi, url: item.url),
                citation: item.citation,
                title: item.title,
                url: item.url,
                doi: doi,
                design: item.design,
                finding: item.finding,
                keywords: keywords,
                foundBySearch: seen.contains(url: item.url, doi: doi),
                foundAt: now,
                topic: reply.topic
            )
            if !studies.contains(where: { $0.id == study.id }) { studies.append(study) }
        }
        return StudyLookupResult(topic: reply.topic, keywords: keywords, studies: studies, searches: seen.searches)
    }

    /// "https://www.Example.org/a/" and "example.org/a" are the same page.
    public static func normalized(_ url: String) -> String {
        var value = url.trimmingCharacters(in: .whitespaces).lowercased()
        for prefix in ["https://", "http://"] where value.hasPrefix(prefix) { value.removeFirst(prefix.count) }
        if value.hasPrefix("www.") { value.removeFirst(4) }
        if let hash = value.firstIndex(of: "#") { value = String(value[..<hash]) }
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }
}

/// Your saved studies: matched against a new question before any search runs.
public enum StudyLibrary {
    /// This many saved studies matching a question means no new search is needed.
    public static let enoughToSkipSearch = 2

    /// Saved studies whose keywords or topic appear in the question, best match first.
    public static func matches(_ question: String, in library: [Study], limit: Int = 6) -> [Study] {
        let asked = tokens(question)
        guard !asked.isEmpty else { return [] }
        let scored: [(study: Study, score: Int)] = library.filter { $0.deletedAt == nil }.compactMap { study in
            let phrases = study.keywords + [study.topic]
            let score = phrases.filter { phrase in
                let words = tokens(phrase)
                return !words.isEmpty && words.allSatisfy { word in asked.contains { same($0, word) } }
            }.count
            return score > 0 ? (study, score) : nil
        }
        return scored
            .sorted { ($0.score, $0.study.foundBySearch ? 1 : 0, $0.study.foundAt) > ($1.score, $1.study.foundBySearch ? 1 : 0, $1.study.foundAt) }
            .prefix(limit)
            .map(\.study)
    }

    /// Adds new studies; one already saved (same DOI or page) keeps its first
    /// finding and gains the new keywords, and counts as found by search if either was.
    public static func merge(_ new: [Study], into library: [Study]) -> [Study] {
        var result = library
        for study in new {
            if let index = result.firstIndex(where: { $0.id == study.id }) {
                let words = result[index].keywords + study.keywords.filter { !result[index].keywords.contains($0) }
                result[index].keywords = words
                result[index].foundBySearch = result[index].foundBySearch || study.foundBySearch
            } else {
                result.append(study)
            }
        }
        return result
    }

    /// The saved study a citation like "Kang 2023, Frontiers in Neurology" refers to:
    /// same first-author surname and year.
    public static func study(citedAs source: String, in library: [Study]) -> Study? {
        let cited = source.lowercased()
        return library.first { study in
            guard let surname = study.citation.split(whereSeparator: { $0 == " " || $0 == "," }).first?.lowercased(),
                  surname.count >= 3,
                  let year = study.citation.range(of: #"(19|20)\d{2}"#, options: .regularExpression) else { return false }
            return cited.contains(surname) && cited.contains(study.citation[year])
        }
    }

    static let stopwords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "have", "has", "had", "what", "should", "how", "can", "could",
        "would", "about", "from", "into", "just", "like", "feel", "feeling", "felt", "really", "very", "some", "more",
        "most", "after", "before", "today", "yesterday", "tonight", "now", "still", "been", "being", "get", "got",
        "does", "did", "doing", "you", "your", "are", "was", "were", "not", "but", "bit", "little", "lot", "help",
        "helps", "work", "day", "time", "much", "any", "all", "also", "want", "need", "know", "think", "make", "then",
        "than", "when", "why", "who", "which", "there", "their", "they", "them", "its", "i'm", "im", "ive", "i've",
        "kind", "sort", "thing", "things", "good", "best", "better", "way", "ways", "people", "study", "studies",
        "research", "evidence", "effect", "effects",
    ]

    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") })
            .map { String($0).replacingOccurrences(of: "'", with: "") }
            .filter { $0.count >= 3 && !stopwords.contains($0) }
    }

    /// Loose word match: "meditating" ~ "meditation", "headaches" ~ "headache", "naps" ~ "nap".
    static func same(_ a: String, _ b: String) -> Bool {
        let a = singular(a), b = singular(b)
        if a == b { return true }
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        if short.count >= 4 && long.hasPrefix(short) { return true }
        return a.commonPrefix(with: b).count >= 6
    }

    private static func singular(_ word: String) -> String {
        word.count >= 4 && word.hasSuffix("s") && !word.hasSuffix("ss") ? String(word.dropLast()) : word
    }
}
