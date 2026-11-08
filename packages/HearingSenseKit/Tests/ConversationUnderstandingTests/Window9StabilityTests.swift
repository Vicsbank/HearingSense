import Foundation
import Testing
@testable import ConversationUnderstanding

private actor WorkCounter {
    var active = 0
    var peak = 0
    var completed = 0
    func start() { active += 1; peak = max(peak, active) }
    func stop() { active -= 1; completed += 1 }
}

private actor SwitchableEngine: SummarizationEngine {
    nonisolated let identity: SummarizationEngineIdentity
    var available = true
    init(_ identity: SummarizationEngineIdentity) { self.identity = identity }
    func setAvailable(_ value: Bool) { available = value }
    func isAvailable() -> Bool { available }
    func prewarm() {}
    func recap(transcript: String, notes: [String]) -> RecapDraft { RecapDraft(title: "Synthetic", summary: "The bus leaves Friday.") }
    func update(previous: RecapDraft, newTranscript: String) -> RecapDraft { previous }
    func restate(_ statement: String) -> String { identity.kind.rawValue }
}

@Suite("Window 9 request lifecycle and stability")
struct Window9StabilityTests {
    @Test func deadlineReturnsBeforeUncooperativeCleanupButNextWorkCannotOverlap() async throws {
        let gate = SummaryExecutionGate()
        let counter = WorkCounter()
        let started = ContinuousClock.now
        await #expect(throws: CancellationError.self) {
            try await SummaryDeadline.run(seconds: 0.04) {
                try await gate.perform {
                    await counter.start()
                    // Deliberately ignores cancellation, like a native operation finishing cleanup.
                    await Task.detached { try? await Task.sleep(for: .milliseconds(300)) }.value
                    await counter.stop()
                }
            }
        }
        #expect(SummaryRequest.seconds(started.duration(to: .now)) < 0.25)
        try await gate.perform { await counter.start(); await counter.stop() }
        #expect(await counter.peak == 1)
        #expect(await counter.completed == 2)
        #expect(SummaryRequest.seconds(started.duration(to: .now)) >= 0.28)
    }

    @Test func cancelledQueuedOperationNeverStarts() async throws {
        let gate = SummaryExecutionGate()
        let counter = WorkCounter()
        let owner = Task {
            try await gate.perform {
                await counter.start()
                try await Task.sleep(for: .milliseconds(120))
                await counter.stop()
            }
        }
        while await counter.active == 0 { await Task.yield() }
        let queued = Task { try await gate.perform { await counter.start(); await counter.stop() } }
        queued.cancel()
        await #expect(throws: CancellationError.self) { try await queued.value }
        try await owner.value
        #expect(await counter.completed == 1)
    }

    @Test func restatementIsBoundToDraftEvenAfterAnotherRequestUsesFallback() async throws {
        let identity = SummarizationEngineIdentity(kind: .qwen, modelID: "synthetic", revision: "test", quantization: "test", runtime: "test")
        let primary = SwitchableEngine(identity)
        let fallback = SwitchableEngine(.appleFoundationModels)
        let coordinator = SummarizationCoordinator(primary: primary, fallback: fallback)
        let first = try await coordinator.recap(transcript: "Synthetic fixture.", notes: [])
        await primary.setAvailable(false)
        let second = try await coordinator.recap(transcript: "Another fixture.", notes: [])
        #expect(second.engine == .appleFoundationModels)
        #expect(try await coordinator.restate("Synthetic fixture.", using: first.engine) == "qwen")
        #expect(try await coordinator.restate("Another fixture.", using: second.engine) == "appleFoundationModels")
    }

    @Test func requestBudgetReservesChecksAndHasExactlyOneTerminalOutcome() async throws {
        let request = SummaryRequest(operation: .summary, sourceRevision: 7, budget: 66, checkReserve: 10)
        #expect(request.budget(maximum: 100, reservingChecks: true) <= 56)
        #expect(request.budget(maximum: 40, reservingChecks: true) <= 40)
        #expect(request.finish(.deadlineExpired))
        #expect(!request.finish(.completed))
        let finishedElapsed = request.snapshot.elapsed
        try await Task.sleep(for: .milliseconds(10))
        request.record(.cleanup, .completed)
        #expect(request.snapshot.elapsed == finishedElapsed)
        #expect(request.snapshot.outcome == .deadlineExpired)
        #expect(throws: CancellationError.self) { try request.check() }
    }

    @Test func contentFreeTraceRemainsBounded() throws {
        let request = SummaryRequest(operation: .update, sourceRevision: 8)
        for _ in 0..<200 { request.record(.check, .completed, duration: 0.01) }
        #expect(request.snapshot.events.count == 128)
        let encoded = try JSONEncoder().encode(request.snapshot.events)
        let data = String(decoding: encoded, as: UTF8.self)
        #expect(!data.contains("transcript"))
        #expect(!data.contains("summary"))
    }

    private func readyMachine(at now: Date) -> ConversationSessionMachine {
        var machine = ConversationSessionMachine(policy: .product)
        machine.setListening(true)
        machine.setContextAllowed(true)
        machine.process(.summarizeRequested(at: now))
        machine.process(.excerptReady(at: now))
        machine.process(.recapReady(ConversationRecap(title: "Synthetic", summary: "The bus leaves Friday.", source: .languageModel,
                                                       coveredTo: now), at: now))
        return machine
    }

    @Test func exhaustedBudgetDoesNotPutAHealthyEngineIntoCooldown() async throws {
        let identity = SummarizationEngineIdentity(kind: .qwen, modelID: "synthetic", revision: "test", quantization: "test", runtime: "test")
        let coordinator = SummarizationCoordinator(primary: SwitchableEngine(identity), fallback: SwitchableEngine(.appleFoundationModels))
        for _ in 0..<3 {
            let request = SummaryRequest(operation: .summary, sourceRevision: 0, budget: 1, checkReserve: 10)
            await #expect(throws: CancellationError.self) {
                try await SummaryRequest.$current.withValue(request) { try await coordinator.recap(transcript: "Synthetic.", notes: []) }
            }
        }
        #expect(try await coordinator.recap(transcript: "Synthetic.", notes: []).engine == identity)
    }

    @Test func staleLifecycleCallbackCannotDisableForegroundInference() async throws {
        let coordinator = SummarizationCoordinator(primary: nil, fallback: SwitchableEngine(.appleFoundationModels))
        await coordinator.setForeground(true, revision: 3)
        await coordinator.setForeground(false, revision: 2)
        #expect(await coordinator.isAvailable())
    }

    @Test func failedNewAttemptKeepsPreviouslyAcceptedSummary() {
        let now = Date.now
        var machine = readyMachine(at: now)
        let previous = machine.recap
        machine.process(.summarizeRequested(at: now + 1))
        machine.process(.excerptReady(at: now + 1))
        machine.process(.recapReady(ConversationRecap(title: "Unavailable", summary: "Unavailable", source: .unavailable), at: now + 2))
        #expect(machine.recap == previous)
        #expect(machine.phase == .summaryAvailable)
    }

    @Test func backgroundHoldsPendingSpeechAndResumesAnUpdateOnForeground() {
        let now = Date.now
        var machine = readyMachine(at: now)
        machine.process(.continueSelected(at: now))
        machine.setForeground(false, at: now + 1)
        machine.process(.utterance(meaningfulWords: 12, end: now + 3))
        #expect(!machine.process(.tick(at: now + 40)).contains { if case .requestUpdate = $0 { true } else { false } })
        let resumed = machine.setForeground(true, at: now + 41)
        #expect(resumed.contains { if case .requestUpdate = $0 { true } else { false } })
    }

    @Test func backgroundDuringUpdateRestoresItsPendingSpeech() {
        let now = Date.now
        var machine = readyMachine(at: now)
        machine.process(.continueSelected(at: now))
        machine.process(.utterance(meaningfulWords: 12, end: now + 3))
        machine.process(.tick(at: now + 25))
        #expect(machine.isUpdateInFlight)
        machine.setForeground(false, at: now + 26)
        #expect(!machine.isUpdateInFlight)
        #expect(machine.setForeground(true, at: now + 50).contains { if case .requestUpdate = $0 { true } else { false } })
    }

    @Test func noChangeDoesNotContinuouslyRetryButFailureRetriesAtNormalCadence() {
        let now = Date.now
        var ready = readyMachine(at: now)
        ready.process(.continueSelected(at: now))
        ready.process(.utterance(meaningfulWords: 12, end: now + 3))
        ready.process(.tick(at: now + 25))
        var failed = ready
        ready.process(.updateFinished(nil, at: now + 26))
        #expect(!ready.process(.tick(at: now + 100)).contains { if case .requestUpdate = $0 { true } else { false } })
        _ = failed.updateFailed(at: now + 26)
        #expect(!failed.process(.tick(at: now + 27)).contains { if case .requestUpdate = $0 { true } else { false } })
        #expect(failed.process(.tick(at: now + 50)).contains { if case .requestUpdate = $0 { true } else { false } })
    }

    @Test func updateOutcomeDistinguishesNoChangeAndUnavailable() async {
        let model = SwitchableEngine(.appleFoundationModels)
        let engine = ConversationRecapEngine(summarizer: model)
        let previous = ConversationRecap(title: "Synthetic", summary: "The bus leaves Friday.", source: .languageModel)
        let new = [BufferedUtterance(text: "The bus leaves Friday morning.", start: .now, end: .now)]
        let unchanged = await engine.updateResult(previous, earlierTranscript: "The bus leaves Friday.", new: new)
        if case .noChange = unchanged {} else { Issue.record("Expected a no-change result") }
        #expect(!unchanged.shouldRetry)
        await model.setAvailable(false)
        let unavailable = await engine.updateResult(previous, earlierTranscript: "The bus leaves Friday.", new: new)
        if case .unavailable = unavailable {} else { Issue.record("Expected an unavailable result") }
        #expect(unavailable.shouldRetry)
    }
}
