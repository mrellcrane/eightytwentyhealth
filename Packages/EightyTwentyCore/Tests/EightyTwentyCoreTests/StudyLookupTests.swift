import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import EightyTwentyCore

final class StudyLookupTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_792_000_000)

    static func study(_ id: String, citation: String, keywords: [String], topic: String = "Meditation",
                      bySearch: Bool = true, at date: Date = Date(timeIntervalSince1970: 1_792_000_000)) -> Study {
        Study(id: id, citation: citation, title: "T \(id)", url: "https://pubmed.ncbi.nlm.nih.gov/\(id)/", doi: nil,
              design: "Meta-analysis of 47 trials", finding: "Anxiety 0.38", keywords: keywords,
              foundBySearch: bySearch, foundAt: date, topic: topic)
    }

    static let meditation = [
        study("1", citation: "Goyal et al. 2014, JAMA Internal Medicine", keywords: ["meditation", "mindfulness", "anxiety"]),
        study("2", citation: "Galante et al. 2021, PLOS Medicine", keywords: ["meditation", "mindfulness", "stress"]),
    ]
    static let headache = [
        study("3", citation: "Kang et al. 2023, Frontiers in Neurology", keywords: ["headache", "tension", "acupuncture"],
              topic: "Tension-type headache"),
    ]

    // MARK: Request

    func testBodyHasWebSearchAndSchema() throws {
        let body = StudyLookupRequest.body(messages: [StudyLookupRequest.userMessage("Q", known: [])])
        XCTAssertEqual(body["model"], "claude-opus-5-5")
        XCTAssertEqual(body["fallbacks"], "default")
        let tool = try XCTUnwrap(body["tools"]?.arrayValue?.first)
        XCTAssertEqual(tool["type"], "web_search_20260209")
        XCTAssertEqual(tool["name"], "web_search")
        XCTAssertEqual(tool["max_uses"], 5)
        XCTAssertEqual(body["output_config"]?["format"]?["type"], "json_schema")
        XCTAssertEqual(body["output_config"]?["format"]?["schema"]?["additionalProperties"], false)
        XCTAssertNil(StudyLookupRequest.body(messages: [], fallbacks: false)["fallbacks"])
    }

    func testOnlyTheQuestionIsSentPlusWhatsAlreadySaved() throws {
        let fresh = try XCTUnwrap(StudyLookupRequest.userMessage("Afternoon headache", known: [])["content"]?.stringValue)
        XCTAssertEqual(fresh, "What they're dealing with:\nAfternoon headache")
        let known = try XCTUnwrap(StudyLookupRequest.userMessage("Meditation?", known: Self.meditation)["content"]?.stringValue)
        XCTAssertTrue(known.contains("don't look these up again"))
        XCTAssertTrue(known.contains("- Goyal et al. 2014, JAMA Internal Medicine: T 1"))
    }

    // MARK: Parsing and the "found by search" check

    static func searchResponse(stop: String = "end_turn", urls: [String], searches: Int, text: String? = nil) -> String {
        let results = urls.map { #"{"type":"web_search_result","url":"\#($0)","title":"t"}"# }.joined(separator: ",")
        var blocks = [
            #"{"type":"server_tool_use","id":"srv_1","name":"web_search","input":{"query":"q"}}"#,
            #"{"type":"web_search_tool_result","tool_use_id":"srv_1","content":[\#(results)]}"#,
            #"{"type":"web_search_tool_result","tool_use_id":"srv_2","content":{"type":"web_search_tool_result_error","error_code":"max_uses_exceeded"}}"#,
        ]
        if let text {
            let escaped = String(decoding: try! JSONEncoder().encode(text), as: UTF8.self)
            blocks.append(#"{"type":"text","text":\#(escaped)}"#)
        }
        return """
        {"type":"message","stop_reason":"\(stop)","content":[\(blocks.joined(separator: ","))],
         "usage":{"input_tokens":1,"output_tokens":1,"server_tool_use":{"web_search_requests":\(searches)}}}
        """
    }

    static let replyText = """
    {"topic":"Tension-type headache","keywords":["Headache","desk","caffeine"],"studies":[
     {"citation":"Kang et al. 2023, Frontiers in Neurology","title":"Acupuncture for TTH","url":"https://www.ncbi.nlm.nih.gov/pmc/articles/PMC10208222/","doi":"","design":"Meta-analysis of 6 RCTs (927 people)","finding":"SMD -0.23 vs sham"},
     {"citation":"Smith 2020, Some Journal","title":"Remembered","url":"https://example.org/remembered","doi":"","design":"RCT","finding":"from memory"},
     {"citation":"Doe 2021, J","title":"By DOI","url":"https://doi.org/10.1000/xyz","doi":"10.1000/XYZ","design":"RCT","finding":"f"},
     {"citation":"Kang et al. 2023, Frontiers in Neurology","title":"Duplicate","url":"https://ncbi.nlm.nih.gov/pmc/articles/PMC10208222","doi":"","design":"d","finding":"f"},
     {"citation":"Bad","title":"No link","url":"not a url","doi":"","design":"d","finding":"f"}]}
    """

    func testMarksOnlyStudiesSeenInSearchResultsAsFoundBySearch() throws {
        var seen = StudyLookupRequest.SearchResults()
        let response = try JSONDecoder().decode(JSONValue.self, from: Data(Self.searchResponse(
            urls: ["https://pmc.example/x", "https://www.ncbi.nlm.nih.gov/pmc/articles/PMC10208222/",
                   "https://journal.example/doi/10.1000/xyz"],
            searches: 3).utf8))
        seen.add(response)
        XCTAssertEqual(seen.searches, 3)

        let result = try StudyLookupRequest.parse(Self.replyText, seen: seen, now: t0)
        XCTAssertEqual(result.topic, "Tension-type headache")
        XCTAssertEqual(result.keywords, ["headache", "desk", "caffeine"])
        XCTAssertEqual(result.searches, 3)
        XCTAssertEqual(result.studies.map(\.citation), ["Kang et al. 2023, Frontiers in Neurology", "Smith 2020, Some Journal", "Doe 2021, J"],
                       "Duplicate page and the non-URL are dropped")
        XCTAssertEqual(result.studies.map(\.foundBySearch), [true, false, true], "The DOI showed up in a result URL")
        XCTAssertEqual(result.studies[2].id, "10.1000/xyz")
        XCTAssertEqual(result.studies[0].id, "ncbi.nlm.nih.gov/pmc/articles/pmc10208222")
        XCTAssertEqual(result.studies[0].keywords, ["headache", "desk", "caffeine"])
        XCTAssertNil(result.studies[0].doi)
        XCTAssertEqual(result.studies[0].foundAt, t0)

        XCTAssertThrowsError(try StudyLookupRequest.parse("nope", seen: seen, now: t0)) {
            XCTAssertEqual($0 as? CoachError, .badReply)
        }
    }

    func testClientResumesAPausedSearchTurn() async throws {
        let paused = Self.searchResponse(stop: "pause_turn", urls: ["https://www.ncbi.nlm.nih.gov/pmc/articles/PMC10208222/"], searches: 2)
        let done = Self.searchResponse(urls: ["https://journal.example/doi/10.1000/xyz"], searches: 1, text: Self.replyText)
        var calls = 0
        let transport = MockTransport { _ in
            calls += 1
            return (200, calls == 1 ? paused : done, [:])
        }
        let client = CoachClient(transport: transport, apiKey: { "sk-test" })
        let result = try await client.lookUpStudies("Afternoon headache", known: [], now: t0)
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(result.searches, 3)
        XCTAssertEqual(result.studies.map(\.foundBySearch), [true, false, true], "Results from both parts count")

        let second = try JSONDecoder().decode(JSONValue.self, from: try XCTUnwrap(transport.requests[1].httpBody))
        let messages = try XCTUnwrap(second["messages"]?.arrayValue)
        XCTAssertEqual(messages.map { $0["role"] }, ["user", "assistant"], "Resumes with the paused turn, no extra user message")
        XCTAssertEqual(messages[1]["content"]?.arrayValue?.first?["type"], "server_tool_use")
        XCTAssertEqual(transport.requests[1].timeoutInterval, StudyLookupRequest.timeout)
    }

    func testLookupErrors() async {
        let refused = MockTransport { _ in (200, #"{"type":"message","stop_reason":"refusal","content":[]}"#, [:]) }
        do {
            _ = try await CoachClient(transport: refused, apiKey: { "k" }).lookUpStudies("Q", known: [])
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? CoachError, .refused)
        }
        let noKey = MockTransport { _ in (200, "{}", [:]) }
        do {
            _ = try await CoachClient(transport: noKey, apiKey: { "" }).lookUpStudies("Q", known: [])
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? CoachError, .noKey)
        }
        XCTAssertTrue(noKey.requests.isEmpty)
    }

    // MARK: Library

    func testAskingAboutMeditationAgainFindsTheSavedStudies() {
        let library = Self.meditation + Self.headache
        let again = StudyLibrary.matches("Is meditating actually worth it for my stress?", in: library)
        XCTAssertEqual(again.map(\.id), ["2", "1"], "Galante matches meditation and stress, so it leads")
        XCTAssertGreaterThanOrEqual(again.count, StudyLibrary.enoughToSkipSearch)
        XCTAssertEqual(StudyLibrary.matches("headaches every afternoon", in: library).map(\.id), ["3"])
        XCTAssertEqual(StudyLibrary.matches("Tension-type headache at my desk", in: library).map(\.id), ["3"])
        XCTAssertTrue(StudyLibrary.matches("how should I feel about this today", in: library).isEmpty)
        XCTAssertTrue(StudyLibrary.matches("", in: library).isEmpty)

        var deleted = Self.meditation
        deleted[1].deletedAt = t0
        XCTAssertEqual(StudyLibrary.matches("meditation", in: deleted).map(\.id), ["1"])
    }

    func testWordMatchingIsLooseButNotSilly() {
        XCTAssertTrue(StudyLibrary.same("meditating", "meditation"))
        XCTAssertTrue(StudyLibrary.same("headaches", "headache"))
        XCTAssertTrue(StudyLibrary.same("naps", "nap"))
        XCTAssertTrue(StudyLibrary.same("stressed", "stress"))
        XCTAssertFalse(StudyLibrary.same("sleep", "sleeve"))
        XCTAssertFalse(StudyLibrary.same("nap", "napkin"))
        XCTAssertEqual(StudyLibrary.tokens("I'm so tired, and the headache!"), ["tired", "headache"])
    }

    func testMergeKeepsOneCopyPerStudy() {
        var again = Self.meditation[0]
        again.keywords = ["meditation", "sleep"]
        again.finding = "a different summary"
        let merged = StudyLibrary.merge([again] + Self.headache, into: Self.meditation)
        XCTAssertEqual(merged.map(\.id), ["1", "2", "3"])
        XCTAssertEqual(merged[0].keywords, ["meditation", "mindfulness", "anxiety", "sleep"])
        XCTAssertEqual(merged[0].finding, "Anxiety 0.38", "The first saved finding stays")
    }

    func testFindsTheSavedStudyBehindACitation() {
        let library = Self.meditation + Self.headache
        XCTAssertEqual(StudyLibrary.study(citedAs: "Kang 2023, Frontiers in Neurology", in: library)?.id, "3")
        XCTAssertEqual(StudyLibrary.study(citedAs: "Goyal et al. (2014), JAMA Intern Med", in: library)?.id, "1")
        XCTAssertNil(StudyLibrary.study(citedAs: "Goyal 2019, Other", in: library))
        XCTAssertNil(StudyLibrary.study(citedAs: "", in: library))
    }

    // MARK: Where studies go

    func testSavedStudiesReachTheCoachContextButNotTheMessages() throws {
        var context = CoachScenario.context()
        context.studies = Self.meditation + [Self.study("4", citation: "Memory 2020, J", keywords: ["meditation"], bySearch: false)]
        let text = context.render()
        XCTAssertTrue(text.contains("Studies from their library that may fit (found by web search earlier):\n- Goyal et al. 2014, JAMA Internal Medicine: Meta-analysis of 47 trials. Anxiety 0.38"))
        XCTAssertFalse(text.contains("Memory 2020"), "Only studies actually found by search")

        var conversation = CoachConversation(context: "CTX", question: "Meditation?", askedAt: t0)
        conversation.record(CoachRequestTests.sampleReply, text: CoachRequestTests.sampleText)
        let before = conversation.messages
        conversation.attachStudies(Self.meditation, toTurn: 0)
        conversation.attachStudies(Self.meditation, toTurn: 5)
        XCTAssertEqual(conversation.messages, before)
        XCTAssertEqual(conversation.turns[0].studies, Self.meditation)
        conversation.followUp("And for sleep?", at: "Thu 1:00 PM", askedAt: t0)
        XCTAssertEqual(conversation.lookupQuestion(forTurn: 0), "Meditation?")
        XCTAssertEqual(conversation.lookupQuestion(forTurn: 1), "Meditation?\nAnd for sleep?")
        XCTAssertEqual(conversation.lookupQuestion(forTurn: 9), "")

        let turns = CoachRecord.decodeTurns(CoachRecord.encodeTurns(conversation.turns))
        XCTAssertEqual(turns, conversation.turns)
        let old = #"[{"question":"Q","askedAt":"2026-10-14T08:00:00Z"}]"#
        XCTAssertNil(CoachRecord.decodeTurns(Data(old.utf8)).first?.studies, "Turns saved before lookups still load")
    }

    func testDidItIsRememberedOnTheStepButNeverSentToClaude() throws {
        var conversation = CoachConversation(context: "CTX", question: "Tired", askedAt: t0)
        conversation.markLogged(step: 0, turn: 0, at: t0)
        XCTAssertNil(conversation.turns[0].logged, "Nothing to log before there's an answer")
        conversation.record(CoachRequestTests.sampleReply, text: CoachRequestTests.sampleText)
        let before = conversation.messages
        conversation.markLogged(step: 0, turn: 0, at: t0)
        conversation.markLogged(step: 5, turn: 0, at: t0)
        conversation.markLogged(step: 0, turn: 3, at: t0)
        conversation.markLogged(step: 0, turn: 0, at: t0.addingTimeInterval(60))
        XCTAssertEqual(conversation.messages, before)
        XCTAssertEqual(conversation.turns[0].logged?.count, 2)
        XCTAssertEqual(conversation.turns[0].loggedAt(step: 0), t0.addingTimeInterval(60))
        XCTAssertNil(conversation.turns[0].loggedAt(step: 1))

        let turns = CoachRecord.decodeTurns(CoachRecord.encodeTurns(conversation.turns))
        XCTAssertEqual(turns, conversation.turns)
        let old = #"[{"question":"Q","askedAt":"2026-10-14T08:00:00Z"}]"#
        XCTAssertNil(CoachRecord.decodeTurns(Data(old.utf8)).first?.logged)
    }

    func testNatureAndKindnessCountAsPractices() {
        XCTAssertTrue(ActivityKind.nature.isMentalPractice)
        XCTAssertTrue(ActivityKind.kindness.isMentalPractice)
        XCTAssertFalse(ActivityKind.nap.isMentalPractice)
        XCTAssertFalse(ActivityKind.alcohol.isMentalPractice)
        XCTAssertFalse(ActivityKind.other.isMentalPractice, "A coach step only counts through its catalog id")
    }

    func testBackupKeepsStudiesAndOlderBackupsStillLoad() throws {
        var doc = BackupDocument(exportedAt: t0, appVersion: nil, moods: [], gratitude: [], activities: [])
        XCTAssertTrue(doc.isEmpty)
        doc.studies = Self.meditation
        XCTAssertFalse(doc.isEmpty)
        XCTAssertEqual(try BackupDocument.decode(try doc.encoded()), doc)

        let merge = BackupMerge.recordsToInsert(from: doc, existingIDs: [], existingExternalIDs: [], existingStudyIDs: ["1"])
        XCTAssertEqual(merge.studies.map(\.id), ["2"])

        let old = #"{"version":1,"exportedAt":"2026-10-14T00:00:00Z","moods":[],"gratitude":[],"activities":[]}"#
        XCTAssertTrue(try BackupDocument.decode(Data(old.utf8)).studies.isEmpty)
    }
}
