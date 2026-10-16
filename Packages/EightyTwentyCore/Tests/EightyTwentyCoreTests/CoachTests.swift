import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import EightyTwentyCore

// MARK: - Catalog

final class InterventionCatalogTests: XCTestCase {
    func testIDsAreUniqueAndLookupWorks() {
        let ids = Intervention.catalog.map(\.id)
        XCTAssertFalse(ids.isEmpty)
        XCTAssertEqual(Set(ids).count, ids.count, "Duplicate intervention id")
        XCTAssertFalse(ids.contains("none"), "'none' is the schema's no-match value")
        for item in Intervention.catalog {
            XCTAssertEqual(Intervention.find(item.id), item)
        }
        XCTAssertNil(Intervention.find("none"))
        XCTAssertNil(Intervention.find(nil))
    }

    func testEveryEntryIsComplete() throws {
        let doi = try NSRegularExpression(pattern: #"^10\.\d{4,9}/\S+$"#)
        for item in Intervention.catalog {
            let e = item.evidence
            XCTAssertEqual(doi.numberOfMatches(in: e.doi, range: NSRange(e.doi.startIndex..., in: e.doi)), 1,
                           "\(item.id): DOI \(e.doi)")
            XCTAssertNotNil(e.url, item.id)
            XCTAssertGreaterThan(e.effectSize, 0, item.id)
            XCTAssertLessThan(e.effectSize, 1.5, "\(item.id): implausibly large effect")
            XCTAssertFalse(e.citation.isEmpty, item.id)
            XCTAssertFalse(e.outcome.isEmpty, item.id)
            XCTAssertFalse(e.finding.isEmpty, item.id)
            XCTAssertFalse(item.title.isEmpty, item.id)
            XCTAssertFalse(item.summary.isEmpty, item.id)
            XCTAssertFalse(item.steps.isEmpty, item.id)
            XCTAssertFalse(item.steps.contains { $0.isEmpty }, item.id)
            XCTAssertFalse(item.targets.isEmpty, item.id)
            XCTAssertTrue(item.targets.isSubset(of: [.mood, .stressBalance, .mentalSleep, .practice]),
                          "\(item.id) targets a Physical component")
            XCTAssertGreaterThan(item.minutes, 0, item.id)
            if let hours = item.hours {
                XCTAssertTrue((0...23).contains(hours.lowerBound) && (0...23).contains(hours.upperBound), item.id)
            }
            XCTAssertTrue(item.headline.hasPrefix("≈\(item.researchPercent)% "), item.headline)
        }
    }

    func testBothListsHaveEntries() {
        XCTAssertTrue(Intervention.catalog.contains { $0.timing == .rightAway })
        XCTAssertTrue(Intervention.catalog.contains { $0.timing == .overWeeks })
    }
}

// MARK: - Numbers

final class EffectEstimateTests: XCTestCase {
    func testPercentIsEffectSizeTimes33() {
        XCTAssertEqual(EffectEstimate.percent(effectSize: 0.36), 12)
        XCTAssertEqual(EffectEstimate.percent(effectSize: 0.5), 17)
        XCTAssertEqual(EffectEstimate.percent(effectSize: 0), 0)
    }

    func testBlendStartsAtResearchAndMovesTowardYours() {
        XCTAssertEqual(EffectEstimate.blended(researchPercent: 12, personal: nil), 12)
        let five = PersonalEffect(count: 5, averageBefore: 10, averageAfter: 6) // 40%
        XCTAssertEqual(EffectEstimate.blended(researchPercent: 12, personal: five), 26, accuracy: 0.001)
        let fifty = PersonalEffect(count: 50, averageBefore: 10, averageAfter: 6)
        XCTAssertGreaterThan(EffectEstimate.blended(researchPercent: 12, personal: fifty), 37)
    }

    func testPersonalEffectUsesOnlyRatedLogsWithAnID() throws {
        let t = Date(timeIntervalSince1970: 1_792_000_000)
        let logs = [
            InterventionLog(interventionID: "a", title: "A", timestamp: t, intensityBefore: 8, intensityAfter: 4),
            InterventionLog(interventionID: "a", title: "A", timestamp: t, intensityBefore: 6, intensityAfter: 3),
            InterventionLog(interventionID: "a", title: "A", timestamp: t, intensityBefore: 7, intensityAfter: 7),
            InterventionLog(interventionID: "a", title: "A", timestamp: t, intensityBefore: 9, intensityAfter: nil),
            InterventionLog(interventionID: nil, title: "Other", timestamp: t, intensityBefore: 9, intensityAfter: 1),
        ]
        let effects = PersonalEffect.compute(logs)
        XCTAssertEqual(effects.count, 1)
        let a = try XCTUnwrap(effects["a"])
        XCTAssertEqual(a.count, 3)
        XCTAssertEqual(a.averageBefore, 7, accuracy: 0.001)
        XCTAssertEqual(a.averageAfter, 14.0 / 3, accuracy: 0.001)
        XCTAssertEqual(a.percentChange, 100.0 / 3, accuracy: 0.01)
        XCTAssertEqual(PersonalEffect(count: 1, averageBefore: 0, averageAfter: 0).percentChange, 0)
    }
}

final class InterventionRankerTests: XCTestCase {
    func item(_ id: String, effect: Double, minutes: Double = 5, targets: Set<ComponentID>,
              hours: ClosedRange<Int>? = nil) -> Intervention {
        Intervention(
            id: id, title: id, minutes: minutes, timing: .rightAway, summary: "s", steps: ["do it"],
            evidence: .init(citation: "c", doi: "10.1000/x", grade: .a, effectSize: effect, outcome: "less stress", finding: "f"),
            targets: targets, logsAs: .other, hours: hours
        )
    }

    func mental(_ scores: [ComponentID: Double]) -> BarReading {
        BarReading(
            kind: .mental, day: DayKey("2026-10-15")!, value: 70,
            components: scores.map { ComponentScore(id: $0.key, score: $0.value, weight: 0.25, detail: "") },
            missing: [], coverage: 1
        )
    }

    func testBoostsWhatTargetsTheWeakestComponent() {
        let catalog = [item("mood", effect: 0.4, targets: [.mood]), item("stress", effect: 0.4, targets: [.stressBalance])]
        let ranked = InterventionRanker.rank(catalog, mental: mental([.mood: 80, .stressBalance: 40]), personal: [:], hour: 13)
        XCTAssertEqual(ranked.map(\.intervention.id), ["stress", "mood"])
        XCTAssertEqual(ranked[0].reason, "Aimed at your stress vs recovery, the lowest part of your Mental bar today")
        XCTAssertNil(ranked[1].reason)
        XCTAssertEqual(ranked[0].score / ranked[1].score, InterventionRanker.targetBoost, accuracy: 0.001)
    }

    func testNoBoostWhenNothingIsLow() {
        let catalog = [item("mood", effect: 0.4, targets: [.mood]), item("stress", effect: 0.3, targets: [.stressBalance])]
        let ranked = InterventionRanker.rank(catalog, mental: mental([.mood: 80, .stressBalance: 70]), personal: [:], hour: 13)
        XCTAssertEqual(ranked.map(\.intervention.id), ["mood", "stress"])
        XCTAssertTrue(ranked.allSatisfy { $0.reason == nil })
    }

    func testOffHoursSinks() {
        let catalog = [item("nap", effect: 0.6, targets: [.mood], hours: 12...16), item("walk", effect: 0.4, targets: [.mood])]
        XCTAssertEqual(InterventionRanker.rank(catalog, mental: nil, personal: [:], hour: 14).first?.intervention.id, "nap")
        XCTAssertEqual(InterventionRanker.rank(catalog, mental: nil, personal: [:], hour: 21).first?.intervention.id, "walk")
    }

    func testPerMinuteAndPersonalResultsCount() {
        let catalog = [item("long", effect: 0.5, minutes: 15, targets: [.mood]), item("short", effect: 0.3, minutes: 5, targets: [.mood])]
        XCTAssertEqual(InterventionRanker.rank(catalog, mental: nil, personal: [:], hour: 9).first?.intervention.id, "short")

        let bad = PersonalEffect(count: 10, averageBefore: 6, averageAfter: 6)
        let ranked = InterventionRanker.rank(catalog, mental: nil, personal: ["short": bad], hour: 9)
        XCTAssertEqual(ranked.first?.intervention.id, "long", "Ten tries that did nothing outweigh the research")
        XCTAssertEqual(ranked.first { $0.intervention.id == "short" }?.personal, bad)
    }
}

// MARK: - Request

final class CoachRequestTests: XCTestCase {
    func conversationWithFollowUp() -> CoachConversation {
        // Whole seconds: the backup's ISO 8601 dates drop fractions.
        let t = Date(timeIntervalSince1970: 1_792_000_000)
        var conversation = CoachConversation(context: "CTX", question: "Tired at 1pm", askedAt: t)
        conversation.record(Self.sampleReply, text: Self.sampleText)
        conversation.followUp("I can't nap at work", at: "Thu 1:04 PM", askedAt: t.addingTimeInterval(240))
        return conversation
    }

    func testBodyShape() throws {
        let body = CoachRequest.body(CoachConversation(context: "CTX", question: "Q"))
        XCTAssertEqual(body["model"], "claude-opus-5-5")
        XCTAssertEqual(body["max_tokens"], 16000)
        XCTAssertEqual(body["fallbacks"], "default")
        XCTAssertEqual(body["output_config"]?["effort"], "medium")
        XCTAssertEqual(body["output_config"]?["format"]?["type"], "json_schema")
        XCTAssertNotNil(body["output_config"]?["format"]?["schema"])
        XCTAssertNil(body["thinking"], "Opus 5.5 thinks adaptively by default; no thinking config is sent")
        XCTAssertNil(body["temperature"])
        XCTAssertEqual(body["system"]?.stringValue, CoachRequest.systemPrompt)

        let noFallback = CoachRequest.body(CoachConversation(context: "CTX", question: "Q"), fallbacks: false)
        XCTAssertNil(noFallback["fallbacks"])
    }

    func testEncodesWholeNumbersAsIntegers() throws {
        let data = try JSONEncoder().encode(CoachRequest.body(CoachConversation(context: "CTX", question: "Q")))
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains(#""max_tokens":16000"#), json.prefix(300).description)
    }

    func testHeaders() throws {
        let conversation = CoachConversation(context: "CTX", question: "Q")
        let request = try CoachRequest.urlRequest(conversation, apiKey: "sk-test")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url, CoachRequest.endpoint)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "server-side-fallback-2026-07-01")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 120)

        let plain = try CoachRequest.urlRequest(conversation, apiKey: "sk-test", fallbacks: false)
        XCTAssertNil(plain.value(forHTTPHeaderField: "anthropic-beta"))
    }

    func testSchemaEnumsComeFromCatalogAndKinds() throws {
        let step = try XCTUnwrap(CoachRequest.replySchema["properties"]?["steps"]?["items"]?["properties"])
        let catalogIDs = try XCTUnwrap(step["catalogID"]?["enum"]?.arrayValue).compactMap(\.stringValue)
        XCTAssertEqual(catalogIDs, Intervention.catalog.map(\.id) + ["none"])
        let kinds = try XCTUnwrap(step["logAs"]?["enum"]?.arrayValue).compactMap(\.stringValue)
        XCTAssertEqual(Set(kinds), Set(ActivityKind.allCases.map(\.rawValue)))
        XCTAssertEqual(CoachRequest.replySchema["additionalProperties"], false)
        XCTAssertEqual(CoachRequest.replySchema["properties"]?["steps"]?["items"]?["additionalProperties"], false)
    }

    func testSystemPromptListsTheCatalog() {
        for item in Intervention.catalog {
            XCTAssertTrue(CoachRequest.systemPrompt.contains("- \(item.id): \(item.title)"), item.id)
        }
    }

    func testFirstMessageCarriesContextThenQuestion() throws {
        let conversation = CoachConversation(context: "CTX", question: "Tired at 1pm")
        XCTAssertEqual(conversation.messages.count, 1)
        let text = try XCTUnwrap(conversation.messages[0]["content"]?.stringValue)
        XCTAssertEqual(text, "<context>\nCTX\n</context>\n\nWhat's going on:\nTired at 1pm")
        XCTAssertTrue(conversation.awaitingReply)
    }

    func testFollowUpsAreAppendOnlyAndReplayOnlyText() throws {
        let first = CoachConversation(context: "CTX", question: "Tired at 1pm")
        let conversation = conversationWithFollowUp()
        XCTAssertEqual(conversation.messages.count, 3)
        XCTAssertEqual(conversation.messages[0], first.messages[0], "Earlier turns go back byte-for-byte")
        XCTAssertEqual(conversation.messages.map { $0["role"] }, ["user", "assistant", "user"])
        let assistant = try XCTUnwrap(conversation.messages[1]["content"]?.arrayValue)
        XCTAssertEqual(assistant, [["type": "text", "text": .string(Self.sampleText)]])
        XCTAssertEqual(conversation.messages[2]["content"], "[Thu 1:04 PM] I can't nap at work")
        XCTAssertEqual(conversation.turns.map(\.question), ["Tired at 1pm", "I can't nap at work"])
        XCTAssertEqual(conversation.turns[0].reply, Self.sampleReply)
        XCTAssertTrue(conversation.awaitingReply)

        // The JSON that goes out has no thinking blocks anywhere.
        let json = String(decoding: try JSONEncoder().encode(CoachRequest.body(conversation)), as: UTF8.self)
        XCTAssertFalse(json.contains("\"thinking\""))
    }

    func testSavedConversationRebuildsTheSameMessages() throws {
        let conversation = conversationWithFollowUp()
        let record = CoachRecord(id: UUID(), conversation: conversation)
        let restored = try XCTUnwrap(record.conversation)
        XCTAssertEqual(restored.messages, conversation.messages)
        XCTAssertTrue(restored.awaitingReply)

        let turns = CoachRecord.decodeTurns(CoachRecord.encodeTurns(conversation.turns))
        XCTAssertEqual(turns, conversation.turns)
        XCTAssertTrue(CoachRecord.decodeTurns(Data("junk".utf8)).isEmpty)
        XCTAssertNil(CoachConversation(context: "CTX", turns: []))
    }

    func testSavedConversationStopsAtTheFirstUnansweredTurn() throws {
        let t = Date(timeIntervalSince1970: 1_792_000_000)
        let turns = [
            CoachConversation.Turn(question: "first", askedAt: t),
            CoachConversation.Turn(question: "orphan", askedAt: t, stamp: "now",
                                   reply: Self.sampleReply, replyText: Self.sampleText),
        ]
        let restored = try XCTUnwrap(CoachConversation(context: "CTX", turns: turns))
        XCTAssertEqual(restored.turns.map(\.question), ["first"])
        XCTAssertTrue(restored.awaitingReply)
    }

    func testOutOfOrderCallsAreIgnored() {
        var conversation = CoachConversation(context: "CTX", question: "Q")
        conversation.followUp("too early", at: "now")
        XCTAssertEqual(conversation.messages.count, 1)
        conversation.record(Self.sampleReply, text: Self.sampleText)
        conversation.record(Self.sampleReply, text: "twice")
        XCTAssertEqual(conversation.messages.count, 2)
    }

    static let sampleReply = CoachReply(
        summary: "Post-lunch dip.",
        steps: [.init(title: "Walk", minutes: 10, how: "Outside.", why: "Energy.", effect: "More energy",
                      source: "", catalogID: "none", logAs: "walk")],
        avoid: "", seeADoctor: "", crisis: false
    )

    /// Fixed once: dictionary key order isn't stable across encodes on Linux.
    static let sampleText = String(decoding: try! JSONEncoder().encode(sampleReply), as: UTF8.self)
}

// MARK: - Response

final class CoachClientTests: XCTestCase {
    func response(stop: String = "end_turn", text: String = CoachRequestTests.sampleText, extraBlocks: String = "") -> String {
        let escaped = String(decoding: try! JSONEncoder().encode(text), as: UTF8.self)
        return """
        {"id":"msg_1","type":"message","role":"assistant","model":"claude-opus-5-5","stop_reason":"\(stop)",
         "content":[\(extraBlocks){"type":"thinking","thinking":"","signature":"sig"},{"type":"text","text":\(escaped)}]}
        """
    }

    func testParsesStructuredReply() throws {
        let (reply, text) = try CoachClient.parse(Data(response().utf8), status: 200)
        XCTAssertEqual(reply, CoachRequestTests.sampleReply)
        XCTAssertEqual(text, CoachRequestTests.sampleText)
        XCTAssertEqual(reply.steps[0].activityKind, .walk)
        XCTAssertNil(reply.steps[0].intervention)
    }

    func testSkipsFallbackBlocks() throws {
        let body = response(extraBlocks: #"{"type":"fallback","from":{"model":"claude-opus-5-5"},"to":{"model":"claude-opus-5"}},"#)
        XCTAssertEqual(try CoachClient.parse(Data(body.utf8), status: 200).reply, CoachRequestTests.sampleReply)
    }

    func testStopReasonsAndStatuses() {
        func error(_ body: String, _ status: Int) -> CoachError? {
            do {
                _ = try CoachClient.parse(Data(body.utf8), status: status)
                return nil
            } catch {
                return error as? CoachError
            }
        }
        XCTAssertEqual(error(response(stop: "refusal", text: ""), 200), .refused)
        XCTAssertEqual(error(response(stop: "max_tokens", text: "{\"summ"), 200), .truncated)
        XCTAssertEqual(error(response(text: "not json"), 200), .badReply)
        XCTAssertEqual(error("<html>", 200), .badReply)
        XCTAssertEqual(error(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#, 401), .unauthorized)
        XCTAssertEqual(error(#"{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}"#, 429), .rateLimited)
        XCTAssertEqual(error(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#, 529), .overloaded)
        XCTAssertEqual(error(#"{"type":"error","error":{"type":"api_error","message":"boom"}}"#, 500), .http(status: 500, message: "boom"))
    }

    func testRetriesWithoutFallbackWhenTheAPIRejectsIt() async throws {
        let ok = response()
        let transport = MockTransport { request in
            if request.value(forHTTPHeaderField: "anthropic-beta") != nil {
                return (400, #"{"type":"error","error":{"type":"invalid_request_error","message":"fallbacks: Extra inputs are not permitted"}}"#, [:])
            }
            return (200, ok, [:])
        }
        let client = CoachClient(transport: transport, apiKey: { "sk-test" })
        let result = try await client.reply(to: CoachConversation(context: "CTX", question: "Q"))
        XCTAssertEqual(result.reply, CoachRequestTests.sampleReply)
        XCTAssertEqual(transport.requests.count, 2)
        let retryBody = try JSONDecoder().decode(JSONValue.self, from: try XCTUnwrap(transport.requests[1].httpBody))
        XCTAssertNil(retryBody["fallbacks"])
    }

    func testOtherBadRequestsAreNotRetried() async {
        let transport = MockTransport { _ in
            (400, #"{"type":"error","error":{"type":"invalid_request_error","message":"messages: too long"}}"#, [:])
        }
        let client = CoachClient(transport: transport, apiKey: { "sk-test" })
        do {
            _ = try await client.reply(to: CoachConversation(context: "CTX", question: "Q"))
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? CoachError, .http(status: 400, message: "messages: too long"))
        }
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testMissingKeyNeverHitsTheNetwork() async {
        let transport = MockTransport { _ in (200, "{}", [:]) }
        let client = CoachClient(transport: transport, apiKey: { "" })
        do {
            _ = try await client.reply(to: CoachConversation(context: "CTX", question: "Q"))
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? CoachError, .noKey)
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testCatalogStepResolvesItsIntervention() throws {
        let item = try XCTUnwrap(Intervention.catalog.first)
        let step = CoachReply.Step(title: "x", minutes: 5, how: "", why: "", effect: "", source: "",
                                   catalogID: item.id, logAs: "nope")
        XCTAssertEqual(step.intervention, item)
        XCTAssertEqual(step.activityKind, .other)
    }
}

// MARK: - Context

final class CoachContextTests: XCTestCase {
    func testOnePMScenario() {
        let text = CoachScenario.context().render()
        let expected = [
            "Now: Thursday, October 15, 2026, 1:00 PM (America/Los_Angeles)",
            "Work: 6:00 AM to 4:00 PM on weekdays. At work now, about 3 h left.",
            "Target bedtime: 10:15 PM, in 9 h 15 min.",
            "Coffee cutoff for that bedtime (8.8 h before): 1:27 PM, in 27 min.",
            "Physical bar: ",
            "- HRV: 63 ms vs your usual 58 ms",
            "- Sleep: Oura sleep score 86, 7.3 h (score 86)",
            "Mental bar: ",
            "- Mood: Pleasant (today)",
            "Last night (Oura): in bed 9:52 PM to 5:24 AM, 7.3 h asleep, efficiency 91%, temperature +0.1 °C vs usual, SpO2 97%.",
            "Yesterday: 780 active calories, 41 min of workouts, 13,800 steps.",
            "Steps so far today: 3,900.",
            "- Wed 5:40 PM: Run, 38 min, 4.5 mi",
            "- Wed 6:50 PM: Very pleasant, energy 4 of 5, proud, happy",
            "- Thu 6:45 AM: Pleasant, energy 4 of 5, calm, hopeful",
        ]
        for line in expected {
            XCTAssertTrue(text.contains(line), "Missing: \(line)\n\n\(text)")
        }
        XCTAssertFalse(text.contains("Walk"), "Older than 48 hours")
        XCTAssertFalse(text.contains("Right now they report"))
        XCTAssertFalse(text.contains("Tried in the last 30 days"))
    }

    func testWorkStatus() {
        var context = CoachScenario.context()
        let today = CoachScenario.today
        context.now = CoachScenario.at(today, 5, 0)
        XCTAssertTrue(context.render().contains("Work starts in 1 h."))
        context.now = CoachScenario.at(today, 15, 4)
        XCTAssertTrue(context.render().contains("At work now, about 56 min left."))
        context.now = CoachScenario.at(today, 17, 0)
        XCTAssertTrue(context.render().contains("Done with work for today."))
        context.now = CoachScenario.at(today.adding(days: 2), 13, 0) // Saturday
        XCTAssertTrue(context.render().contains("Today is a day off."))
        context.work?.weekdaysOnly = false
        XCTAssertTrue(context.render().contains("6:00 AM to 4:00 PM every day. At work now"))
    }

    func testBedtimeStatus() {
        var context = CoachScenario.context()
        let today = CoachScenario.today
        context.now = CoachScenario.at(today, 23, 0)
        XCTAssertTrue(context.render().contains("Target bedtime: 10:15 PM, 45 min ago."))
        XCTAssertTrue(context.render().contains("1:27 PM, already passed."))
        context.now = CoachScenario.at(today, 1, 0)
        XCTAssertTrue(context.render().contains("Target bedtime: 10:15 PM, 2 h 45 min ago."))
        context.now = CoachScenario.at(today, 7, 0)
        XCTAssertTrue(context.render().contains("Target bedtime: 10:15 PM, in 15 h 15 min."))
        XCTAssertTrue(context.render().contains("1:27 PM, in 6 h 27 min."))
        context.now = CoachScenario.at(today, 14, 0)
        XCTAssertTrue(context.render().contains("1:27 PM, already passed."))
        context.bedtimeMinutes = 30 // 12:30 AM
        context.now = CoachScenario.at(today, 23, 0)
        XCTAssertTrue(context.render().contains("Target bedtime: 12:30 AM, in 1 h 30 min."))
    }

    func testCheckInAndTries() {
        var context = CoachScenario.context()
        context.checkIn = CoachContext.CheckIn(valence: -1.0 / 3, energy: 1, emotions: ["drained"])
        let now = CoachScenario.now
        context.tried = [
            InterventionLog(interventionID: "x", title: "Cyclic sighing", timestamp: now.addingTimeInterval(-2 * 86400),
                            intensityBefore: 7, intensityAfter: 4),
            InterventionLog(interventionID: nil, title: "Splash cold water", timestamp: now.addingTimeInterval(-86400),
                            intensityBefore: nil, intensityAfter: nil),
            InterventionLog(interventionID: "x", title: "Too old", timestamp: now.addingTimeInterval(-40 * 86400),
                            intensityBefore: 7, intensityAfter: 4),
        ]
        let text = context.render()
        XCTAssertTrue(text.contains("Right now they report: Slightly unpleasant, energy 1 of 5, drained"), text)
        XCTAssertTrue(text.contains("- Oct 13: Cyclic sighing, 7 → 4"), text)
        XCTAssertTrue(text.contains("- Oct 14: Splash cold water, not rated"), text)
        XCTAssertFalse(text.contains("Too old"))
    }

    func testMissingDataSaysSo() {
        let context = CoachContext(now: CoachScenario.now, timeZone: CoachScenario.timeZone, work: nil,
                                   bedtimeMinutes: nil, physical: nil, mental: nil, today: nil, yesterday: nil)
        let text = context.render()
        XCTAssertTrue(text.contains("Last night (Oura): no data"))
        XCTAssertTrue(text.contains("Yesterday: no activity data"))
        XCTAssertTrue(text.contains("Logged in the last 48 hours:\n- Nothing"))
        XCTAssertFalse(text.contains("Work:"))
        XCTAssertFalse(text.contains("Health bars"))
    }

    func testKilometers() {
        var context = CoachScenario.context()
        context.usesMiles = false
        XCTAssertTrue(context.render().contains("Run, 38 min, 7.2 km"))
    }
}
