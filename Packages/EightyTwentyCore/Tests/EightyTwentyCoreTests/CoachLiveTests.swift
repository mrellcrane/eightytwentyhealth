import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import EightyTwentyCore

/// Calls the real Claude API with the owner's 1 PM scenario and prints what
/// Claude says. Skipped unless CLAUDE_COACH_API_KEY is set (cloud sessions
/// have it; CI doesn't). Use it to read the advice when tuning the system prompt.
final class CoachLiveTests: XCTestCase {
    struct SessionTransport: HTTPTransport {
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            try await withCheckedThrowingContinuation { continuation in
                URLSession.shared.dataTask(with: request) { data, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let http = response as? HTTPURLResponse {
                        continuation.resume(returning: (data ?? Data(), http))
                    } else {
                        continuation.resume(throwing: URLError(.badServerResponse))
                    }
                }.resume()
            }
        }
    }

    func testOnePMWallThenNoNap() async throws {
        let key = ProcessInfo.processInfo.environment["CLAUDE_COACH_API_KEY"] ?? ""
        try XCTSkipIf(key.isEmpty, "Set CLAUDE_COACH_API_KEY to run the live coach test")
        let client = CoachClient(transport: SessionTransport(), apiKey: { key })

        let context = CoachScenario.context().render()
        print("\n===== CONTEXT =====\n\(context)\n")
        var conversation = CoachConversation(context: context, question: CoachScenario.question)

        var started = Date()
        let first = try await client.reply(to: conversation)
        print("===== FIRST ANSWER (\(Int(Date().timeIntervalSince(started))) s) =====\n\(Self.pretty(first.reply))\n")
        XCTAssertTrue((1...3).contains(first.reply.steps.count), "\(first.reply.steps.count) steps")
        XCTAssertFalse(first.reply.crisis)
        conversation.record(first.reply, text: first.text)

        conversation.followUp("I can't nap at work", at: "Thu 1:03 PM")
        started = Date()
        let second = try await client.reply(to: conversation)
        print("===== FOLLOW-UP: I can't nap at work (\(Int(Date().timeIntervalSince(started))) s) =====\n\(Self.pretty(second.reply))\n")
        XCTAssertTrue((1...3).contains(second.reply.steps.count))
        XCTAssertFalse(second.reply.crisis)
        // The first plan may already skip the nap (it's a workday), so the check is
        // that no nap survives the follow-up, not that every step changed.
        XCTAssertFalse(second.reply.steps.contains { $0.activityKind == .nap || $0.catalogID == "power-nap" },
                       "Still suggesting a nap")
    }

    static func pretty(_ reply: CoachReply) -> String {
        var lines = ["Summary: \(reply.summary)"]
        for (index, step) in reply.steps.enumerated() {
            lines.append("")
            lines.append("\(index + 1). \(step.title) (\(step.minutes) min) [catalog: \(step.catalogID), log as: \(step.logAs)]")
            lines.append("   How: \(step.how)")
            lines.append("   Why: \(step.why)")
            lines.append("   Effect: \(step.effect)")
            lines.append("   Source: \(step.source.isEmpty ? "(basic physiology)" : step.source)")
        }
        if !reply.avoid.isEmpty { lines.append("\nAvoid: \(reply.avoid)") }
        if !reply.seeADoctor.isEmpty { lines.append("See a doctor: \(reply.seeADoctor)") }
        lines.append("Crisis: \(reply.crisis)")
        return lines.joined(separator: "\n")
    }
}
