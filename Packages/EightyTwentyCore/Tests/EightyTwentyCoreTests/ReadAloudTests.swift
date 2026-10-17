import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import EightyTwentyCore

final class ReadAloudTests: XCTestCase {
    private func step(_ title: String, minutes: Int = 10) -> CoachReply.Step {
        CoachReply.Step(title: title, minutes: minutes, how: "Walk outside at an easy pace", why: "Light and movement lift alertness.",
                        effect: "≈20% more alert", source: "Smith 2020, Journal", catalogID: "none", logAs: "walk")
    }

    // MARK: What gets said

    func testReplyReadsSummaryThenEachStepThenCaveats() {
        let reply = CoachReply(summary: "Your HRV is **below** your normal", steps: [step("Take a walk"), step("Drink water", minutes: 1)],
                               avoid: "Skip coffee after 1:30 PM", seeADoctor: "", crisis: false)
        let pieces = ReadAloud.pieces(reply)
        XCTAssertEqual(pieces, [
            "Your HRV is below your normal.",
            "Step 1: Take a walk. 10 minutes. Walk outside at an easy pace. Light and movement lift alertness.",
            "Step 2: Drink water. 1 minute. Walk outside at an easy pace. Light and movement lift alertness.",
            "Skip coffee after 1:30 PM.",
        ])
        XCTAssertFalse(pieces.joined().contains("Smith 2020"), "Sources stay on screen")
        XCTAssertFalse(pieces.joined().contains("≈"))
    }

    func testCrisisLineComesFirst() {
        let reply = CoachReply(summary: "Please reach out now.", steps: [], avoid: "", seeADoctor: "", crisis: true)
        let pieces = ReadAloud.pieces(reply)
        XCTAssertEqual(pieces.count, 2)
        XCTAssertTrue(pieces[0].contains("988"))
        XCTAssertEqual(pieces[1], "Please reach out now.")
    }

    func testMarkdownBecomesPlainSpeech() {
        let markdown = """
        ## Why it helps

        Caffeine has a **half-life** of about _five hours_ ([Drake 2013](https://doi.org/10.5664/jcsm.3170)).
        See https://example.com/paper for more, or [your plan](eightytwenty://running).

        - Walk 10 minutes
        - Drink water
        1. Breathe out slowly
        """
        let text = ReadAloud.plainText(markdown)
        XCTAssertEqual(text, """
        Why it helps.

        Caffeine has a half-life of about five hours (Drake 2013). See for more, or your plan.

        Walk 10 minutes. Drink water. Breathe out slowly.
        """)
    }

    func testAsterisksInsideWordsAndMathStay() {
        XCTAssertEqual(ReadAloud.plainText("3 * 4 = 12 and snake_case_name"), "3 * 4 = 12 and snake_case_name")
        XCTAssertEqual(ReadAloud.plainText("an *easy* pace"), "an easy pace")
    }

    func testChatPiecesMergeShortParagraphsAndSplitLongOnes() {
        let short = ReadAloud.pieces(markdown: "One.\n\nTwo.\n\nThree.")
        XCTAssertEqual(short, ["One.\n\nTwo.\n\nThree."])

        let sentence = "This sentence is about forty characters. "
        let long = String(repeating: sentence, count: 60)   // ~2,460 characters, one paragraph
        let pieces = ReadAloud.pieces(markdown: long)
        XCTAssertGreaterThan(pieces.count, 2)
        XCTAssertLessThanOrEqual(pieces[0].count, ReadAloud.firstPiece, "First piece is short so it starts fast")
        XCTAssertTrue(pieces.allSatisfy { $0.count <= ReadAloud.maxPiece })
        XCTAssertTrue(pieces.allSatisfy { $0.hasSuffix(".") }, "Cut at sentence ends")
        XCTAssertEqual(pieces.joined(separator: " "), long.trimmingCharacters(in: .whitespaces))
    }

    func testOverlongSentenceIsCutAtASpace() {
        let words = String(repeating: "word ", count: 400).trimmingCharacters(in: .whitespaces)   // 1,999 chars, no full stop
        let groups = ReadAloud.split(words, limit: ReadAloud.maxPiece)
        XCTAssertEqual(groups.count, 2)
        XCTAssertTrue(groups.allSatisfy { $0.count <= ReadAloud.maxPiece && !$0.hasPrefix(" ") && !$0.hasSuffix(" ") })
        XCTAssertEqual(groups.joined(separator: " "), words)
    }

    func testCacheKeyIsStableAndDependsOnVoice() {
        let a = ReadAloud.cacheKey("Hello.", voiceID: "v1")
        XCTAssertEqual(a, ReadAloud.cacheKey("Hello.", voiceID: "v1"))
        XCTAssertNotEqual(a, ReadAloud.cacheKey("Hello.", voiceID: "v2"))
        XCTAssertNotEqual(a, ReadAloud.cacheKey("Hello!", voiceID: "v1"))
        XCTAssertEqual(a.count, 16)
        // FNV-1a of the empty string, so the hash can't drift between platforms.
        XCTAssertEqual(ReadAloud.hash(""), "cbf29ce484222325")
        XCTAssertEqual(ReadAloud.hash("a"), "af63dc4c8601ec8c")
    }

    func testSpeedsCycle() {
        XCTAssertEqual(PlaybackSpeed.allCases.map(\.label), ["1×", "1.5×", "2×"])
        XCTAssertEqual(PlaybackSpeed.normal.next, .faster)
        XCTAssertEqual(PlaybackSpeed.faster.next, .double)
        XCTAssertEqual(PlaybackSpeed.double.next, .normal)
    }

    // MARK: ElevenLabs

    final class DataTransport: HTTPTransport, @unchecked Sendable {
        let status: Int
        let body: Data
        private(set) var requests: [URLRequest] = []

        init(status: Int, body: Data) {
            self.status = status
            self.body = body
        }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            requests.append(request)
            return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    private static let mp3 = Data([0x49, 0x44, 0x33, 0x04, 0x00, 0x00]) + Data(repeating: 0, count: 64)

    func testSpeechRequest() async throws {
        let transport = DataTransport(status: 200, body: Self.mp3)
        let client = ElevenLabsClient(transport: transport, apiKey: { " key123\n" })
        let audio = try await client.speech("Take a walk.", voiceID: "abc")

        XCTAssertEqual(audio, Self.mp3)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://api.elevenlabs.io/v1/text-to-speech/abc?output_format=mp3_44100_128")
        XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "key123")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(request.httpBody))
        XCTAssertEqual(body, ["text": "Take a walk.", "model_id": "eleven_multilingual_v2"])
    }

    func testNoKeyNeverCallsOut() async {
        let transport = DataTransport(status: 200, body: Self.mp3)
        let client = ElevenLabsClient(transport: transport, apiKey: { "" })
        do {
            _ = try await client.speech("Hi.", voiceID: "abc")
            XCTFail("Expected noKey")
        } catch {
            XCTAssertEqual(error as? ElevenLabsError, .noKey)
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testErrorShapes() {
        let quota = ElevenLabsRequest.error(status: 401, data: Data(#"{"detail":{"status":"quota_exceeded","message":"This request exceeds your quota of 10000."}}"#.utf8))
        XCTAssertEqual(quota, .http(status: 401, code: "quota_exceeded", message: "This request exceeds your quota of 10000."))
        XCTAssertTrue(quota.userMessage.contains("credits"))

        let invalid = ElevenLabsRequest.error(status: 401, data: Data(#"{"detail":{"type":"authentication_error","code":"invalid_api_key","message":"Invalid API key"}}"#.utf8))
        XCTAssertEqual(invalid, .http(status: 401, code: "invalid_api_key", message: "Invalid API key"))
        XCTAssertTrue(invalid.userMessage.contains("key"))

        let voice = ElevenLabsRequest.error(status: 404, data: Data(#"{"detail":{"status":"voice_not_found","message":"A voice with that ID was not found."}}"#.utf8))
        XCTAssertTrue(voice.userMessage.contains("Pick another"))

        let validation = ElevenLabsRequest.error(status: 422, data: Data(#"{"detail":[{"loc":["body","text"],"msg":"field required"}]}"#.utf8))
        XCTAssertEqual(validation, .http(status: 422, code: nil, message: "field required"))

        let plain = ElevenLabsRequest.error(status: 500, data: Data("Internal Server Error".utf8))
        XCTAssertEqual(plain.userMessage, "ElevenLabs error 500: Internal Server Error")
    }

    func testSuccessThatIsntAudioIsAnError() async {
        let transport = DataTransport(status: 200, body: Data(#"{"detail":"nope"}"#.utf8))
        let client = ElevenLabsClient(transport: transport, apiKey: { "k" })
        do {
            _ = try await client.speech("Hi.", voiceID: "abc")
            XCTFail("Expected notAudio")
        } catch {
            XCTAssertEqual(error as? ElevenLabsError, .notAudio)
        }
        XCTAssertTrue(ElevenLabsRequest.isAudio(Data([0xFF, 0xFB, 0x90, 0x00])))
        XCTAssertFalse(ElevenLabsRequest.isAudio(Data([0xFF])))
    }

    func testVoicesAreSortedByName() async throws {
        let json = #"{"voices":[{"voice_id":"2","name":"sarah","category":"premade","labels":{}},{"voice_id":"1","name":"George","category":"premade"}],"has_more":false}"#
        let transport = DataTransport(status: 200, body: Data(json.utf8))
        let voices = try await ElevenLabsClient(transport: transport, apiKey: { "k" }).voices()
        XCTAssertEqual(voices.map(\.name), ["George", "sarah"])
        XCTAssertEqual(transport.requests.first?.url?.absoluteString, "https://api.elevenlabs.io/v2/voices?page_size=100")
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "xi-api-key"), "k")
    }
}

/// Calls the real ElevenLabs API: checks the default voice is on the account and
/// that the first piece of a coach answer comes back as MP3 (saved to the temp
/// folder to listen to). Skipped unless ELEVENLABS_API_KEY is set; CI doesn't have it.
final class ElevenLabsLiveTests: XCTestCase {
    func testDefaultVoiceSpeaksACoachAnswer() async throws {
        let key = ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"] ?? ""
        try XCTSkipIf(key.isEmpty, "Set ELEVENLABS_API_KEY to run the live read-aloud test")
        let client = ElevenLabsClient(transport: CoachLiveTests.SessionTransport(), apiKey: { key })

        do {
            let voices = try await client.voices()
            print("Voices: \(voices.map { "\($0.name) (\($0.category ?? "?"))" }.joined(separator: ", "))")
            XCTAssertTrue(voices.contains { $0.voiceID == ElevenLabsRequest.defaultVoiceID },
                          "\(ElevenLabsRequest.defaultVoiceName) isn't on this account")
        } catch let error as ElevenLabsError {
            // A key limited to text to speech can't list voices; the app still plays with the default.
            print("Voice list unavailable: \(error)")
        }

        let reply = CoachReply(summary: "Your readiness is 71 and HRV is a bit under your normal, so the 1 PM dip is hitting harder than usual.",
                               steps: [CoachReply.Step(title: "Walk outside", minutes: 10, how: "Walk at an easy pace, outdoors if you can.",
                                                       why: "Daylight and light movement raise alertness within minutes.", effect: "",
                                                       source: "", catalogID: "none", logAs: "walk")],
                               avoid: "Skip coffee after 1:30 PM.", seeADoctor: "", crisis: false)
        let pieces = ReadAloud.pieces(reply)
        let started = Date()
        let audio = try await client.speech(pieces[0], voiceID: ElevenLabsRequest.defaultVoiceID)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("read-aloud-test.mp3")
        try audio.write(to: file)
        print("First piece: \(pieces[0].count) characters -> \(audio.count / 1024) KB in \(String(format: "%.1f", Date().timeIntervalSince(started))) s, saved to \(file.path)")
        XCTAssertTrue(ElevenLabsRequest.isAudio(audio))
        XCTAssertGreaterThan(audio.count, 10_000)
    }
}
