import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import EightyTwentyCore

final class CoachChatTests: XCTestCase {
    func answered() -> CoachConversation {
        var conversation = CoachConversation(context: "CTX", question: "Tired at 1pm")
        conversation.record(CoachRequestTests.sampleReply, text: CoachRequestTests.sampleText)
        return conversation
    }

    func testNeedsAnAnswerFirst() {
        XCTAssertNil(CoachChat(base: CoachConversation(context: "CTX", question: "Q")))
        XCTAssertNotNil(CoachChat(base: answered()))
    }

    func testFirstQuestionCarriesTheInstructionsAfterTheAnswer() throws {
        var chat = try XCTUnwrap(CoachChat(base: answered()))
        XCTAssertEqual(chat.messages, answered().messages, "Nothing asked yet")
        chat.ask("Why the walk?", at: "Thu 1:10 PM")

        let messages = chat.messages
        XCTAssertEqual(messages.map { $0["role"] }, ["user", "assistant", "user"])
        XCTAssertEqual(Array(messages.prefix(2)), answered().messages, "The answer's turns go back unchanged")
        let text = try XCTUnwrap(messages[2]["content"]?.stringValue)
        XCTAssertTrue(text.hasPrefix("<chat>\n\(CoachChat.instructions)\n</chat>\n\n"))
        XCTAssertTrue(text.hasSuffix("\n\n[Thu 1:10 PM] Why the walk?"))
        XCTAssertTrue(chat.awaitingReply)
    }

    func testTurnsAreAppendOnly() throws {
        var chat = try XCTUnwrap(CoachChat(base: answered()))
        chat.ask("Why the walk?", at: "Thu 1:10 PM")
        let asked = chat.messages
        chat.receive("Because ")
        chat.receive("light.")
        XCTAssertEqual(chat.turns[0].answer, "Because light.")
        XCTAssertEqual(chat.messages, asked, "A half-streamed answer isn't sent")

        chat.ask("too early", at: "now")
        XCTAssertEqual(chat.turns.count, 1)

        chat.finish("Because light helps.")
        chat.ask("What's the study?", at: "Thu 1:12 PM")
        let messages = chat.messages
        XCTAssertEqual(Array(messages.prefix(3)), asked, "Earlier turns go back byte for byte")
        XCTAssertEqual(messages.map { $0["role"] }, ["user", "assistant", "user", "assistant", "user"])
        XCTAssertEqual(messages[3]["content"], [["type": "text", "text": "Because light helps."]])
        XCTAssertEqual(messages[4]["content"], "[Thu 1:12 PM] What's the study?")
    }

    func testWithdrawGivesTheQuestionBack() throws {
        var chat = try XCTUnwrap(CoachChat(base: answered()))
        XCTAssertNil(chat.withdraw())
        chat.ask("Why?", at: "now")
        chat.receive("Part")
        XCTAssertEqual(chat.withdraw(), "Why?")
        XCTAssertTrue(chat.turns.isEmpty)
        XCTAssertFalse(chat.awaitingReply)
        XCTAssertEqual(chat.messages, answered().messages)
    }

    func testStudiesFoundForTheAnswerAreListed() throws {
        let study = Study(id: "10.1/x", citation: "White et al. 2019, Scientific Reports", title: "Nature", url: "https://doi.org/10.1/x",
                          doi: "10.1/x", design: "Survey of 19,806 people", finding: "120 min a week in nature linked to better health.",
                          keywords: ["nature"], foundBySearch: true, foundAt: Date(), topic: "Nature")
        var chat = try XCTUnwrap(CoachChat(base: answered(), studies: [study]))
        chat.ask("What's the research?", at: "now")
        let text = try XCTUnwrap(chat.messages[2]["content"]?.stringValue)
        XCTAssertTrue(text.contains("- White et al. 2019, Scientific Reports. Survey of 19,806 people. 120 min a week in nature linked to better health. https://doi.org/10.1/x"), text)
    }

    func testBody() throws {
        var chat = try XCTUnwrap(CoachChat(base: answered()))
        chat.ask("Why?", at: "now")
        let body = CoachChatRequest.body(chat)
        XCTAssertEqual(body["model"], .string(CoachRequest.model))
        XCTAssertEqual(body["stream"], true)
        XCTAssertEqual(body["system"]?.stringValue, CoachRequest.systemPrompt, "Same prompt as the answer")
        XCTAssertEqual(body["output_config"]?["effort"], "medium")
        XCTAssertNil(body["output_config"]?["format"], "Plain text, not the answer's JSON")
        XCTAssertNil(body["thinking"])
        XCTAssertEqual(body["fallbacks"], "default")
        XCTAssertEqual(body["cache_control"]?["type"], "ephemeral")
        XCTAssertEqual(body["messages"]?.arrayValue, chat.messages)
        XCTAssertNil(CoachChatRequest.body(chat, fallbacks: false)["fallbacks"])
        XCTAssertEqual(CoachChatRequest.body(chat, stream: false)["stream"], false)

        let request = try CoachChatRequest.urlRequest(chat, apiKey: "sk-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "server-side-fallback-2026-07-01")
        XCTAssertNil(try CoachChatRequest.urlRequest(chat, apiKey: "sk-test", fallbacks: false).value(forHTTPHeaderField: "anthropic-beta"))
    }
}

final class CoachStreamTests: XCTestCase {
    func read(_ lines: [String]) throws -> (CoachStream, [String]) {
        var stream = CoachStream()
        var deltas: [String] = []
        for line in lines {
            let delta = try stream.read(line)
            if !delta.isEmpty { deltas.append(delta) }
        }
        return (stream, deltas)
    }

    static let start = #"data: {"type":"message_start","message":{"id":"msg_1","model":"claude-opus-5-5","usage":{"input_tokens":120,"cache_read_input_tokens":3400,"output_tokens":1}}}"#
    static let thinking = [
        #"data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}"#,
        #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}"#,
        #"data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig"}}"#,
        #"data: {"type":"content_block_stop","index":0}"#,
    ]
    static func text(_ index: Int, _ parts: [String]) -> [String] {
        [#"data: {"type":"content_block_start","index":\#(index),"content_block":{"type":"text","text":""}}"#]
            + parts.map { #"data: {"type":"content_block_delta","index":\#(index),"delta":{"type":"text_delta","text":"\#($0)"}}"# }
            + [#"data: {"type":"content_block_stop","index":\#(index)}"#]
    }
    static func end(_ stop: String) -> [String] {
        [#"data: {"type":"message_delta","delta":{"stop_reason":"\#(stop)"},"usage":{"output_tokens":250}}"#,
         #"data: {"type":"message_stop"}"#]
    }

    func testKeepsTheTextAndSkipsThinking() throws {
        let lines = [Self.start, "", "event: ping", #"data: {"type":"ping"}"#] + Self.thinking
            + Self.text(1, ["Light ", "in the ", "morning."]) + Self.end("end_turn")
        let (stream, deltas) = try read(lines)
        XCTAssertEqual(deltas, ["Light ", "in the ", "morning."])
        XCTAssertEqual(try stream.answer(), "Light in the morning.")
        XCTAssertEqual(stream.stopReason, "end_turn")
        XCTAssertEqual(stream.inputTokens, 120)
        XCTAssertEqual(stream.cachedTokens, 3400)
        XCTAssertEqual(stream.outputTokens, 250)
        XCTAssertFalse(stream.fellBack)
    }

    func testCarriesOnAcrossAFallback() throws {
        let fallback = #"data: {"type":"content_block_start","index":2,"content_block":{"type":"fallback","from":{"model":"claude-opus-5-5"},"to":{"model":"claude-opus-5"}}}"#
        let lines = [Self.start] + Self.thinking + Self.text(1, ["Half "]) + [fallback, #"data: {"type":"content_block_stop","index":2}"#]
            + Self.text(3, ["and the rest."]) + Self.end("end_turn")
        let (stream, _) = try read(lines)
        XCTAssertTrue(stream.fellBack)
        XCTAssertEqual(try stream.answer(), "Half and the rest.")
    }

    func testEndings() throws {
        func answer(_ lines: [String]) -> Result<String, CoachError> {
            do {
                return .success(try read(lines).0.answer())
            } catch {
                return .failure(error as! CoachError)
            }
        }
        XCTAssertEqual(answer([Self.start] + Self.end("refusal")), .failure(.refused))
        XCTAssertEqual(answer([Self.start] + Self.text(0, ["Cut"]) + Self.end("max_tokens")), .failure(.truncated))
        XCTAssertEqual(answer([Self.start] + Self.text(0, ["Cut off"])), .failure(.badReply), "The stream ended early")
        XCTAssertEqual(answer([Self.start] + Self.text(0, ["  "]) + Self.end("end_turn")), .failure(.badReply))
    }

    func testErrorEvents() {
        func error(_ type: String) -> CoachError? {
            var stream = CoachStream()
            do {
                try stream.read(#"data: {"type":"error","error":{"type":"\#(type)","message":"boom"}}"#)
                return nil
            } catch {
                return error as? CoachError
            }
        }
        XCTAssertEqual(error("overloaded_error"), .overloaded)
        XCTAssertEqual(error("rate_limit_error"), .rateLimited)
        XCTAssertEqual(error("api_error"), .http(status: 0, message: "boom"))
    }

    func testHTTPErrorsMapLikeTheAnswer() {
        XCTAssertEqual(CoachClient.error(status: 401, body: Data()), .unauthorized)
        XCTAssertEqual(CoachClient.error(status: 429, body: Data()), .rateLimited)
        XCTAssertEqual(CoachClient.error(status: 529, body: Data()), .overloaded)
        let body = Data(#"{"type":"error","error":{"type":"invalid_request_error","message":"fallbacks: Extra inputs are not permitted"}}"#.utf8)
        XCTAssertEqual(CoachClient.error(status: 400, body: body), .http(status: 400, message: "fallbacks: Extra inputs are not permitted"))
    }
}
