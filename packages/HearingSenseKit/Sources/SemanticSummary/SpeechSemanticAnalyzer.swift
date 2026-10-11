import Foundation
import HearingSenseDomain

/// Turns a transcript into a `SemanticOutcome`: unclear check → on-device language model →
/// deterministic validation → one corrective retry → transcript-level fallback.
///
/// ```
/// transcript ─▶ unclear? ──yes──▶ "Speech Unclear" (no model call)
///                  │ no
///                  ▼
///           model available? ──no──▶ rules: category + details, no summary   (Level 2)
///                  │ yes
///                  ▼
///        model headline ─▶ SummaryValidator ─▶ accepted ─▶ summary           (Level 3)
///                              │ rejected, or accepted without the transcript's number:
///                              │ retry once with feedback
///                              ▼ still rejected / error / timeout
///                         rules: category + details, no summary              (Level 2)
/// ```
///
/// The analyzer never throws and never invents a summary: when nothing faithful can be
/// produced, `summary` is nil and `failure` says why (without transcript text).
public struct SpeechSemanticAnalyzer: Sendable {
    public let interpreter: any SemanticInterpreting
    public let policy: SummaryPolicy
    private let validator: SummaryValidator

    public init(interpreter: any SemanticInterpreting, policy: SummaryPolicy = .standard) {
        self.interpreter = interpreter
        self.policy = policy
        validator = SummaryValidator(policy: policy)
    }

    public func availability(for languageIdentifier: String) async -> SemanticModelAvailability {
        await interpreter.availability(for: languageIdentifier)
    }

    public func prewarm() async {
        await interpreter.prewarm()
    }

    public func analyze(_ original: SemanticRequest) async -> SemanticOutcome {
        let started = ContinuousClock.now
        let request = trimmed(original)
        var outcome = SemanticOutcome(category: RuleBasedInterpreter.category(of: request.transcript),
                                      details: RuleBasedInterpreter.details(of: request.transcript))

        if RuleBasedInterpreter.isUnclear(request) {
            outcome.isUnclear = true
            outcome.category = .unknown
            outcome.details = nil
            outcome.duration = Self.seconds(since: started)
            return outcome
        }

        outcome.modelAvailability = await interpreter.availability(for: request.languageIdentifier)
        guard outcome.modelAvailability.isUsable, policy.writesHeadlines else {
            outcome.duration = Self.seconds(since: started)
            return outcome
        }

        var feedback: String?
        // A headline that passed but dropped every number: kept in case the retry is no better.
        var acceptedWithDroppedNumber: (summary: SpeechSummary, interpretation: ModelInterpretation)?
        for _ in 0 ..< max(policy.maximumAttempts, 1) {
            if Task.isCancelled { break }
            outcome.attempts += 1
            let interpretation: ModelInterpretation
            do {
                interpretation = try await Self.withTimeout(policy.timeout) { [interpreter, feedback] in
                    try await interpreter.interpret(request, feedback: feedback)
                }
            } catch let error as SemanticError {
                outcome.failure = error.errorDescription
                break
            } catch is CancellationError {
                outcome.failure = "Interpretation was cancelled"
                break
            } catch {
                outcome.failure = "Language model error: \(type(of: error))"
                break
            }

            switch validator.validate(headline: interpretation.headline, transcript: request.transcript) {
            case .accepted(let summary):
                if acceptedWithDroppedNumber == nil, outcome.attempts < policy.maximumAttempts,
                   let numberFeedback = SummaryValidator.numberFeedback(for: summary.text, transcript: request.transcript)
                {
                    // Faithful as far as it goes, but "Store Won't Open" for "won't open until ten"
                    // misleads: ask once for a headline that keeps the number.
                    acceptedWithDroppedNumber = (summary, interpretation)
                    feedback = numberFeedback
                    continue
                }
                var chosen = (summary: summary, interpretation: interpretation)
                if let earlier = acceptedWithDroppedNumber,
                   SummaryValidator.numberFeedback(for: summary.text, transcript: request.transcript) != nil
                {
                    chosen = earlier  // the retry did not keep the number either
                }
                outcome.summary = chosen.summary
                outcome.category = chosen.interpretation.category
                outcome.details = details(from: chosen.interpretation, transcript: request.transcript)
                outcome.failure = nil
                outcome.duration = Self.seconds(since: started)
                return outcome
            case .rejected(let issues):
                outcome.rejections.append(issues.map(\.name).joined(separator: "; "))
                feedback = issues.map(\.feedback).joined(separator: " ")
                outcome.failure = "Summary rejected by faithfulness checks (\(issues.map(\.name).joined(separator: ", ")))"
            }
        }
        if let earlier = acceptedWithDroppedNumber {
            // The retry failed or was rejected: the first headline passed every critical check.
            outcome.summary = earlier.summary
            outcome.category = earlier.interpretation.category
            outcome.details = details(from: earlier.interpretation, transcript: request.transcript)
            outcome.failure = nil
        }
        outcome.duration = Self.seconds(since: started)
        return outcome
    }

    /// Keeps the newest words of an over-long transcript and bounds the context.
    private func trimmed(_ request: SemanticRequest) -> SemanticRequest {
        var result = request
        result.transcript = Self.suffix(of: request.transcript, words: policy.maximumTranscriptWords)
        var budget = policy.maximumContextWords
        var context: [String] = []
        for entry in request.context.reversed() {
            let count = entry.split(whereSeparator: \.isWhitespace).count
            guard count <= budget else { break }
            budget -= count
            context.insert(entry, at: 0)
        }
        result.context = context
        return result
    }

    /// Model-extracted details are kept only when their words occur in the transcript; negation
    /// and question flags always come from rules.
    private func details(from interpretation: ModelInterpretation, transcript: String) -> SpeechSemanticDetails {
        let source = UtteranceAnalysis(transcript)
        func grounded(_ text: String) -> String? {
            let words = UtteranceAnalysis(text).words
            guard !words.isEmpty, words.count <= 6, words.allSatisfy({ source.supports($0) }) else { return nil }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var details = RuleBasedInterpreter.details(of: transcript, source: .onDeviceLanguageModel)
        details.subject = grounded(interpretation.subject)
        details.timeOrNumber = grounded(interpretation.timeOrNumber) ?? details.timeOrNumber
        return details
    }

    private static func suffix(of text: String, words limit: Int) -> String {
        let words = text.split(whereSeparator: \.isWhitespace)
        return words.count > limit ? words.suffix(limit).joined(separator: " ") : text
    }

    private static func seconds(since start: ContinuousClock.Instant) -> TimeInterval {
        let elapsed = (ContinuousClock.now - start).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }

    private static func withTimeout<T: Sendable>(_ seconds: TimeInterval,
                                                 _ operation: @escaping @Sendable () async throws -> T) async throws -> T
    {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw SemanticError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw SemanticError.timedOut }
            return first
        }
    }
}
