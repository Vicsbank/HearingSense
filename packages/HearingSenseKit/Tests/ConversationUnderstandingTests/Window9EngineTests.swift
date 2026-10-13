@testable import ConversationUnderstanding
import Foundation
import Testing

/// Window 9: engine routing (Qwen first, Apple as the fallback) and the text protocol of open
/// models. MOCK engines: these tests prove the routing, not any model.
private struct MockEngine: SummarizationEngine {
    enum Behavior: Sendable { case succeed(String), fail, hang, unavailable }
    let identity: SummarizationEngineIdentity
    let behavior: Behavior

    func isAvailable() async -> Bool { if case .unavailable = behavior { false } else { true } }
    func unavailabilityReason() async -> String? { if case .unavailable = behavior { "mock_unavailable" } else { nil } }
    func prewarm() async {}
    func recap(transcript: String, notes: [String]) async throws -> RecapDraft { try await run() }
    func update(previous: RecapDraft, newTranscript: String) async throws -> RecapDraft { try await run() }
    func restate(_ statement: String) async throws -> String { identity.label + ": " + statement }

    private func run() async throws -> RecapDraft {
        switch behavior {
        case .succeed(let text): return RecapDraft(title: "T", summary: text)
        case .fail: throw RecapError.modelFailure("mock")
        case .hang:
            try await Task.sleep(for: .seconds(30))
            return RecapDraft(title: "T", summary: "late")
        case .unavailable: throw RecapError.modelFailure("unavailable")
        }
    }
}

private let qwenIdentity = SummarizationEngineIdentity(kind: .qwen, modelID: "mlx-community/Qwen3.5-4B-MLX-4bit",
                                                       revision: "32f3e8ecf65426fc3306969496342d504bfa13f3",
                                                       quantization: "4-bit affine, group 64", runtime: "mock")

private func coordinator(_ primary: MockEngine.Behavior?, _ fallback: MockEngine.Behavior = .succeed("apple text"),
                         timeout: TimeInterval = 0.4) -> SummarizationCoordinator
{
    var policy = SummarizationCoordinator.Policy()
    policy.primaryTimeout = timeout
    policy.cooldown = 60
    return SummarizationCoordinator(
        primary: primary.map { MockEngine(identity: qwenIdentity, behavior: $0) },
        fallback: MockEngine(identity: .appleFoundationModels, behavior: fallback), policy: policy)
}

@Suite("Window 9 engine routing (mock engines)")
struct Window9EngineRoutingTests {
    @Test func qwenIsPreferredAndNamed() async throws {
        let engines = coordinator(.succeed("qwen text"))
        let draft = try await engines.recap(transcript: "a b c", notes: [])
        #expect(draft.summary == "qwen text")
        #expect(draft.engine?.kind == .qwen)
        #expect(draft.fallbackReason == nil)
    }

    @Test func unavailableQwenFallsBackAndSaysWhy() async throws {
        let engines = coordinator(.unavailable)
        let draft = try await engines.recap(transcript: "a b c", notes: [])
        #expect(draft.summary == "apple text")
        #expect(draft.engine?.kind == .appleFoundationModels)
        #expect(draft.fallbackReason == "mock_unavailable")
    }

    @Test func noQwenAtAll() async throws {
        let draft = try await coordinator(nil).recap(transcript: "a", notes: [])
        #expect(draft.engine?.kind == .appleFoundationModels)
    }

    @Test func failingQwenFallsBack() async throws {
        let draft = try await coordinator(.fail).recap(transcript: "a", notes: [])
        #expect(draft.engine?.kind == .appleFoundationModels)
        #expect(draft.fallbackReason == "failure_mock")
    }

    @Test func restatementUsesTheEngineThatWroteTheFallbackDraft() async throws {
        let engines = coordinator(.fail)
        _ = try await engines.recap(transcript: "a", notes: [])
        let restated = try await engines.restate("The lot reopens on Friday.")
        #expect(restated.hasPrefix("Apple on-device model:"))
    }

    @Test func anAlreadyCancelledRequestNeverStartsEitherEngine() async {
        let engines = coordinator(.succeed("qwen text"))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await engines.recap(transcript: "a", notes: [])
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await engines.lastAttempts.isEmpty)
    }

    @Test func slowQwenTimesOutAndFallsBack() async throws {
        let started = Date()
        let draft = try await coordinator(.hang, timeout: 0.3).recap(transcript: "a", notes: [])
        #expect(draft.engine?.kind == .appleFoundationModels)
        #expect(draft.fallbackReason == "timeout")
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func repeatedFailuresLeaveQwenAloneForTheCooldown() async throws {
        let engines = coordinator(.fail)
        _ = try await engines.recap(transcript: "a", notes: [])
        _ = try await engines.recap(transcript: "a", notes: [])
        _ = try await engines.recap(transcript: "a", notes: [])
        let attempts = await engines.lastAttempts
        // The third request did not even try Qwen.
        #expect(attempts.first?.failure == "mock_unavailable" || attempts.first?.failure == "skipped_after_failures")
        #expect(attempts.count == 2)
    }

    @Test func bothEnginesFailing() async {
        let engines = coordinator(.fail, .fail)
        await #expect(throws: (any Error).self) { _ = try await engines.recap(transcript: "a", notes: []) }
    }

    @Test func noEngineAvailable() async {
        let engines = coordinator(.unavailable, .unavailable)
        #expect(await engines.isAvailable() == false)
        await #expect(throws: (any Error).self) { _ = try await engines.recap(transcript: "a", notes: []) }
    }

    @Test func cancellationIsNotAFallback() async {
        let engines = coordinator(.hang, timeout: 20)
        let task = Task { try await engines.recap(transcript: "a", notes: []) }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let result = await task.result
        if case .success(let draft) = result { #expect(draft.engine == nil, "an Apple result must not appear after the user cancelled") }
    }

    @Test func identityLabelsNameTheModel() {
        #expect(qwenIdentity.label == "Qwen (Qwen3.5-4B-MLX-4bit)")
        #expect(qwenIdentity.detail.contains("32f3e8ecf654"))
        #expect(SummarizationEngineIdentity.appleFoundationModels.label == "Apple on-device model")
    }
}

@Suite("Window 9 open-model text protocol")
struct OpenModelProtocolTests {
    @Test func readsPlainJSON() throws {
        let parsed = try #require(OpenModelRecapProtocol.parseRecap(
            #"{"title": "Lunch plans", "summary": "They meet at 12:30.", "key_points": ["Lunch at 12:30."]}"#))
        #expect(parsed.wasStructured)
        #expect(parsed.draft.title == "Lunch plans")
        #expect(parsed.draft.keyPoints == ["Lunch at 12:30."])
    }

    @Test func readsFencedJSONWithChatter() throws {
        let answer = "Sure! Here you go:\n```json\n{\"title\": \"A\", \"summary\": \"B {not a brace} done.\", \"key_points\": []}\n```"
        let parsed = try #require(OpenModelRecapProtocol.parseRecap(answer))
        #expect(parsed.draft.summary == "B {not a brace} done.")
    }

    @Test func thinkingBlockIsRemoved() throws {
        let parsed = try #require(OpenModelRecapProtocol.parseRecap(#"<think>hmm {"x": 1}</think>{"summary": "S"}"#))
        #expect(parsed.draft.summary == "S")
    }

    @Test func plainTextBecomesTheSummary() throws {
        let parsed = try #require(OpenModelRecapProtocol.parseRecap("They agreed to meet on Friday."))
        #expect(!parsed.wasStructured)
        #expect(parsed.draft.summary == "They agreed to meet on Friday.")
    }

    @Test func brokenJSONIsRefused() {
        #expect(OpenModelRecapProtocol.parseRecap(#"{"title": "A", "summary": "unfinished"#) == nil)
    }

    @Test func updateReadsOutdated() throws {
        let parsed = try #require(OpenModelRecapProtocol.parseRecap(
            #"{"summary": "The meeting moved to Friday.", "key_points": [], "outdated": ["The meeting is on Thursday."]}"#))
        #expect(parsed.outdated == ["The meeting is on Thursday."])
    }

    @Test func verdicts() throws {
        let items = try #require(OpenModelRecapProtocol.parseVerdicts(
            #"{"items": [{"statement": 1, "line": 3, "verdict": "supported"}, {"statement": 2, "line": 0, "verdict": "unsupported"}]}"#,
            count: 2))
        #expect(items[0].isSupported && items[0].lines == [2])
        #expect(!items[1].isSupported && items[1].lines.isEmpty)
        #expect(OpenModelRecapProtocol.parseVerdicts(#"{"items": [{"statement": 1, "line": 1, "verdict": "supported"}]}"#, count: 2) == nil)
        #expect(OpenModelRecapProtocol.parseVerdicts(#"{"items": [{"statement": 1, "line": 0, "verdict": "uncertain"}]}"#, count: 1) == nil)
        #expect(OpenModelRecapProtocol.parseVerdicts(#"{"items": [{"statement": 1, "line": 1, "verdict": "supported"}, {"statement": 1, "line": 0, "verdict": "unsupported"}]}"#, count: 1) == nil)
    }

    @Test func promptsHaveNoExampleValues() {
        // The Window 7 lesson: a day, time or number inside the instructions leaks into recaps.
        // The examples in these instructions use placeholders (X, Y) or the digits-style hint only.
        for text in [OpenModelRecapProtocol.recapInstructions, OpenModelRecapProtocol.updateInstructions] {
            for day in ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"] {
                #expect(!text.contains(day))
            }
        }
    }
}
