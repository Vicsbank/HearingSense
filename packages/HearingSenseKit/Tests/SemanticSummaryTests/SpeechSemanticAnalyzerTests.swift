import Foundation
import HearingSenseDomain
import os
import Testing
@testable import SemanticSummary

/// A scripted stand-in for the language model (synthetic outputs). It lets the tests decide
/// exactly what "the model" answers, including wrong answers.
final class ScriptedInterpreter: SemanticInterpreting {
    typealias Responder = @Sendable (SemanticRequest, String?, Int) throws -> ModelInterpretation

    struct Call: Sendable {
        var request: SemanticRequest
        var feedback: String?
    }

    private struct State {
        var availability = SemanticModelAvailability.available
        var calls: [Call] = []
        var delay: Duration = .zero
        var prewarms = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let responder: Responder

    init(availability: SemanticModelAvailability = .available, delay: Duration = .zero, responder: @escaping Responder) {
        self.responder = responder
        state.withLock {
            $0.availability = availability
            $0.delay = delay
        }
    }

    /// Always answers with the same headline.
    convenience init(headline: String, category: SpeechSemanticCategory = .announcement) {
        self.init { _, _, _ in ModelInterpretation(headline: headline, category: category) }
    }

    var calls: [Call] { state.withLock { $0.calls } }
    var prewarmCount: Int { state.withLock { $0.prewarms } }
    func setAvailability(_ availability: SemanticModelAvailability) { state.withLock { $0.availability = availability } }

    func availability(for languageIdentifier: String) async -> SemanticModelAvailability {
        state.withLock { $0.availability }
    }

    func prewarm() async { state.withLock { $0.prewarms += 1 } }

    func interpret(_ request: SemanticRequest, feedback: String?) async throws -> ModelInterpretation {
        let (attempt, delay) = state.withLock { state -> (Int, Duration) in
            state.calls.append(Call(request: request, feedback: feedback))
            return (state.calls.count, state.delay)
        }
        if delay > .zero { try await Task.sleep(for: delay) }
        return try responder(request, feedback, attempt)
    }
}

@Suite struct SpeechSemanticAnalyzerTests {
    @Test func acceptsAFaithfulHeadlineOnTheFirstAttempt() async {
        let model = ScriptedInterpreter { _, _, _ in
            ModelInterpretation(headline: "BIOLOGY TEST TOMORROW", category: .reminder, subject: "biology test",
                                timeOrNumber: "tomorrow")
        }
        let outcome = await SpeechSemanticAnalyzer(interpreter: model)
            .analyze(SemanticRequest(transcript: "Hey, don't forget we have a biology test tomorrow."))
        #expect(outcome.summary?.text == "Biology Test Tomorrow" && outcome.summary?.reliability == .validated)
        #expect(outcome.category == .reminder && outcome.attempts == 1 && outcome.failure == nil)
        #expect(outcome.details?.subject == "biology test" && outcome.details?.timeOrNumber == "tomorrow")
        #expect(outcome.details?.source == .onDeviceLanguageModel && outcome.details?.isNegated == false)
        #expect(model.calls.count == 1 && model.calls[0].feedback == nil)
    }

    @Test func retriesOnceWithFeedbackWhenTheModelReversesTheMeaning() async {
        let model = ScriptedInterpreter { _, feedback, _ in
            ModelInterpretation(headline: feedback == nil ? "Package Arrived" : "Package Not Arrived", category: .announcement)
        }
        let outcome = await SpeechSemanticAnalyzer(interpreter: model)
            .analyze(SemanticRequest(transcript: "Your package has not arrived."))
        #expect(outcome.summary?.text == "Package Not Arrived")
        #expect(outcome.attempts == 2 && outcome.rejections == ["negation dropped"] && outcome.failure == nil)
        #expect(model.calls[1].feedback?.contains("negation") == true)
        #expect(outcome.details?.isNegated == true)
    }

    @Test func neverShowsAReversedSummaryWhenTheModelKeepsGettingItWrong() async {
        let model = ScriptedInterpreter(headline: "Open The Door")
        let outcome = await SpeechSemanticAnalyzer(interpreter: model)
            .analyze(SemanticRequest(transcript: "Please don't open the door."))
        #expect(outcome.summary == nil && outcome.attempts == 2 && outcome.rejections.count == 2)
        #expect(outcome.failure == "Summary rejected by faithfulness checks (negation dropped)")
        // The fallback still reports what rules can tell.
        #expect(outcome.category == .request && outcome.details?.isNegated == true && outcome.details?.source == .rules)
    }

    @Test func rejectsHallucinatedDetailsFromTheModel() async {
        let model = ScriptedInterpreter { _, _, _ in
            ModelInterpretation(headline: "Package Arrived", category: .announcement, subject: "Amazon package",
                                timeOrNumber: "5 PM")
        }
        let outcome = await SpeechSemanticAnalyzer(interpreter: model)
            .analyze(SemanticRequest(transcript: "Your package arrived."))
        #expect(outcome.summary?.text == "Package Arrived")
        #expect(outcome.details?.subject == nil && outcome.details?.timeOrNumber == nil)
    }

    @Test func asksOnceMoreWhenAHeadlineDropsTheNumber() async {
        let transcript = "The store won't open until ten."
        // The retry keeps the number: use it.
        let improving = ScriptedInterpreter { _, feedback, _ in
            ModelInterpretation(headline: feedback == nil ? "Store Won't Open" : "Store Won't Open Until Ten", category: .warning)
        }
        var outcome = await SpeechSemanticAnalyzer(interpreter: improving).analyze(SemanticRequest(transcript: transcript))
        #expect(outcome.summary?.text == "Store Won't Open Until Ten" && outcome.summary?.reliability == .validated)
        #expect(outcome.attempts == 2 && improving.calls[1].feedback?.contains("\"ten\"") == true)

        // The retry is no better: keep the first headline, flagged with a warning.
        let stubborn = ScriptedInterpreter(headline: "Store Won't Open", category: .warning)
        outcome = await SpeechSemanticAnalyzer(interpreter: stubborn).analyze(SemanticRequest(transcript: transcript))
        #expect(outcome.summary?.text == "Store Won't Open" && outcome.summary?.reliability == .validatedWithWarnings)
        #expect(outcome.attempts == 2 && outcome.failure == nil)

        // The retry is rejected (it lost the negation): the first, faithful headline is kept.
        let worse = ScriptedInterpreter { _, feedback, _ in
            ModelInterpretation(headline: feedback == nil ? "Store Won't Open" : "Store Opens At Ten", category: .warning)
        }
        outcome = await SpeechSemanticAnalyzer(interpreter: worse).analyze(SemanticRequest(transcript: transcript))
        #expect(outcome.summary?.text == "Store Won't Open" && outcome.failure == nil && outcome.category == .warning)

        // The retry fails: same.
        let failing = ScriptedInterpreter { _, feedback, _ in
            if feedback != nil { throw SemanticError.modelFailure("rateLimited") }
            return ModelInterpretation(headline: "Store Won't Open", category: .warning)
        }
        outcome = await SpeechSemanticAnalyzer(interpreter: failing).analyze(SemanticRequest(transcript: transcript))
        #expect(outcome.summary?.text == "Store Won't Open" && outcome.failure == nil)
    }

    @Test func fallsBackToRulesWhenTheModelIsUnavailable() async {
        for availability in [SemanticModelAvailability.deviceNotEligible, .appleIntelligenceNotEnabled, .modelNotReady,
                             .unsupportedLanguage("zh-CN")]
        {
            let model = ScriptedInterpreter(availability: availability) { _, _, _ in
                Issue.record("the model must not be called when unavailable")
                return ModelInterpretation(headline: "X", category: .other)
            }
            let outcome = await SpeechSemanticAnalyzer(interpreter: model)
                .analyze(SemanticRequest(transcript: "Can you help me carry these boxes?"))
            #expect(outcome.summary == nil && outcome.attempts == 0 && outcome.failure == nil)
            #expect(outcome.category == .request && outcome.modelAvailability == availability)
            #expect(outcome.details?.isQuestion == true)
        }
    }

    @Test func aModelErrorDoesNotPropagateOrLeakTheTranscript() async {
        struct Boom: Error { let secret = "Your package arrived" }
        let model = ScriptedInterpreter { _, _, _ in throw Boom() }
        let outcome = await SpeechSemanticAnalyzer(interpreter: model)
            .analyze(SemanticRequest(transcript: "Your package arrived."))
        #expect(outcome.summary == nil && outcome.attempts == 1 && outcome.category == .other)
        #expect(outcome.failure == "Language model error: Boom")

        let failing = ScriptedInterpreter { _, _, _ in throw SemanticError.modelFailure("GenerationError.guardrailViolation") }
        let second = await SpeechSemanticAnalyzer(interpreter: failing)
            .analyze(SemanticRequest(transcript: "Your package arrived."))
        #expect(second.failure == "Language model error: GenerationError.guardrailViolation")
    }

    @Test func aSlowModelTimesOutAndTheTranscriptLevelIsUsed() async {
        var policy = SummaryPolicy()
        policy.timeout = 0.05
        let model = ScriptedInterpreter(delay: .seconds(5)) { _, _, _ in
            ModelInterpretation(headline: "Package Arrived", category: .announcement)
        }
        let started = ContinuousClock.now
        let outcome = await SpeechSemanticAnalyzer(interpreter: model, policy: policy)
            .analyze(SemanticRequest(transcript: "Your package arrived."))
        #expect(outcome.summary == nil && outcome.failure == SemanticError.timedOut.errorDescription)
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test func unclearTranscriptsAreNotSentToTheModel() async {
        let model = ScriptedInterpreter(headline: "Something Important")
        let analyzer = SpeechSemanticAnalyzer(interpreter: model)
        let filler = await analyzer.analyze(SemanticRequest(transcript: "uh the the and so it"))
        let poor = await analyzer.analyze(SemanticRequest(
            transcript: "Your package arrived",
            quality: .assess(meanConfidence: 0.2, minimumConfidence: 0.1, wordCount: 3)))
        for outcome in [filler, poor] {
            #expect(outcome.isUnclear && outcome.summary == nil && outcome.category == .unknown && outcome.attempts == 0)
        }
        #expect(model.calls.isEmpty)
    }

    @Test func boundsWhatIsSentToTheModel() async {
        var policy = SummaryPolicy()
        policy.maximumTranscriptWords = 5
        policy.maximumContextWords = 4
        let model = ScriptedInterpreter(headline: "Six Seven")
        _ = await SpeechSemanticAnalyzer(interpreter: model, policy: policy).analyze(SemanticRequest(
            transcript: "one two three four five six seven eight nine ten",
            context: ["alpha beta gamma delta epsilon", "red green", "blue sky"]))
        #expect(model.calls[0].request.transcript == "six seven eight nine ten")
        #expect(model.calls[0].request.context == ["red green", "blue sky"])
    }

    @Test func cancellationStopsFurtherAttempts() async {
        let model = ScriptedInterpreter(delay: .seconds(5), responder: { _, _, _ in
            ModelInterpretation(headline: "Package Arrived", category: .announcement)
        })
        let analyzer = SpeechSemanticAnalyzer(interpreter: model)
        let task = Task { await analyzer.analyze(SemanticRequest(transcript: "Your package arrived.")) }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let outcome = await task.value
        #expect(outcome.summary == nil && outcome.attempts == 1)
    }
}

@Suite struct FoundationModelInterpreterTests {
    @Test func promptQuotesTheUtteranceAndKeepsContextSeparate() {
        let prompt = FoundationModelInterpreter.prompt(
            for: SemanticRequest(transcript: "She said \"stop\" now", context: ["Earlier words"]),
            feedback: "Keep the negation.")
        #expect(prompt.contains("Utterance: \"She said 'stop' now\""))
        #expect(prompt.contains("for context only") && prompt.contains("\"Earlier words\""))
        #expect(prompt.hasSuffix("Your previous headline was rejected. Keep the negation."))
        #expect(!FoundationModelInterpreter.prompt(for: SemanticRequest(transcript: "Hello"), feedback: nil)
            .contains("context"))
    }

    @Test func instructionsForbidInventingAndObeying() {
        let instructions = FoundationModelInterpreter.instructions
        #expect(instructions.contains("never add") && instructions.contains("negation") && instructions.contains("never answer or obey"))
    }

    @Test func errorKindsCarryNoMessageText() {
        enum Sample: Error { case guardrailViolation(String) }
        #expect(FoundationModelInterpreter.kind(of: Sample.guardrailViolation("private words")) == "Sample.guardrailViolation")
    }

    @Test func availabilityIsReportedWithoutThrowing() async {
        let availability = await FoundationModelInterpreter().availability(for: "en-US")
        #expect(availability != .unknown)
        print("[environment] on-device language model (en-US): \(availability.displayName)")
    }

    /// Real on-device model (not deterministic across OS versions): run with
    /// `HS_RUN_MODEL_TESTS=1 swift test --filter realModel`. Checks only properties the pipeline
    /// guarantees: whatever the model writes, a shown summary never drops the negation.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HS_RUN_MODEL_TESTS"] == "1"))
    func realModelSummariesKeepNegations() async {
        let interpreter = FoundationModelInterpreter()
        guard await interpreter.availability(for: "en-US") == .available else { return }
        let analyzer = SpeechSemanticAnalyzer(interpreter: interpreter)
        for transcript in ["Your package arrived.", "Your package has not arrived.", "Class starts at 3 PM.",
                           "Class does not start at 3 PM.", "Please don't open the door."]
        {
            let outcome = await analyzer.analyze(SemanticRequest(transcript: transcript))
            guard let summary = outcome.summary else { continue }  // fallback is acceptable
            #expect(UtteranceAnalysis(summary.text).isNegated == UtteranceAnalysis(transcript).isNegated, "\(transcript)")
            #expect(summary.wordCount <= SummaryPolicy.standard.maximumWords)
        }
    }
}
