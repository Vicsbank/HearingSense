import Foundation

/// Deterministic checks between the language model and an alert. The model's answer is
/// untrusted: it can cite words nobody said, call a wish a fact, or drop a "not". The verifier
/// can only make a decision more cautious, never less.
public struct EvidenceVerifier: Hashable, Sendable {
    /// Share of the cited evidence's content words that must occur in the utterance.
    public var minimumEvidenceCoverage: Double
    public var minimumHeadlineCoverage: Double
    public var maximumHeadlineWords: Int

    public init(minimumEvidenceCoverage: Double = 0.6, minimumHeadlineCoverage: Double = 0.6, maximumHeadlineWords: Int = 8) {
        self.minimumEvidenceCoverage = minimumEvidenceCoverage
        self.minimumHeadlineCoverage = minimumHeadlineCoverage
        self.maximumHeadlineWords = maximumHeadlineWords
    }

    public static let standard = EvidenceVerifier()

    /// Phrases that mark a statement as imagined, whatever the model said.
    static let hypotheticalMarkers = ["what if", "i wish", "imagine if", "wouldn't it be", "hypothetically",
                                      "i dreamed", "i dreamt", "let's pretend", "suppose they"]

    public func verify(_ judgement: RelevanceJudgement, utterance: SemanticUtterance, goals: [AttentionGoal],
                       stage: SemanticStage = .model) -> SemanticAttentionDecision
    {
        var decision = SemanticAttentionDecision(
            utteranceID: utterance.id, date: utterance.date, verdict: judgement.verdict,
            reason: judgement.consequence.trimmingCharacters(in: .whitespacesAndNewlines),
            evidence: judgement.evidence.trimmingCharacters(in: .whitespacesAndNewlines),
            headline: judgement.headline.trimmingCharacters(in: .whitespacesAndNewlines),
            urgency: judgement.urgency, statementKind: judgement.statementKind, subject: judgement.subject, stage: stage)
        var corrections: [String] = []

        // A verdict needs a goal, and a goal needs a verdict.
        if judgement.goalIndex >= 1, judgement.goalIndex <= goals.count {
            decision.matchedGoalID = goals[judgement.goalIndex - 1].id
        } else if decision.verdict != .irrelevant {
            decision.verdict = .irrelevant
            corrections.append("no_goal")
        }
        guard decision.verdict != .irrelevant else {
            decision.matchedGoalID = nil
            decision.presentation = .none
            decision.corrections = corrections
            return decision
        }

        // Evidence must be words that were said.
        let source = utterance.text
        if decision.evidence.isEmpty || SemanticText.contentWords(in: decision.evidence).isEmpty {
            // No span cited: the utterance as a whole is what the verdict rests on.
            decision.evidence = source
        } else if SemanticText.coverage(of: decision.evidence, in: source) < minimumEvidenceCoverage {
            decision.evidence = ""
            if decision.verdict == .relevant {
                decision.verdict = .uncertain
                corrections.append("evidence_not_in_utterance")
            }
        }

        // Not asserted: a hypothesis, a quotation or a joke is not an event. A question is left to
        // the model: "Can you cover Saturday?" and "Excuse me, can you hear me?" are questions
        // that the listener wants to know about.
        if decision.verdict == .relevant {
            switch decision.statementKind {
            case .hypothetical, .reported, .unclear:
                decision.verdict = .uncertain
                corrections.append("not_asserted")
            case .noChange:
                decision.verdict = .irrelevant
                corrections.append("nothing_changes")
            case .statement, .question:
                break
            }
        }
        if decision.verdict == .relevant {
            let lowered = " " + SemanticText.words(in: source).joined(separator: " ") + " "
            if Self.hypotheticalMarkers.contains(where: { lowered.contains(" " + $0 + " ") }) {
                decision.verdict = .uncertain
                decision.statementKind = .hypothetical
                corrections.append("hypothetical_marker")
            }
        }

        // About someone else: worth keeping in the list at most.
        if decision.verdict == .relevant, decision.subject == .someoneElse {
            decision.verdict = .uncertain
            corrections.append("about_someone_else")
        }
        if utterance.isLowQuality, decision.verdict == .relevant {
            decision.verdict = .uncertain
            corrections.append("low_recognition_quality")
        }
        decision.isPersonalRelevanceUncertain = decision.subject != .listenerOrGroup || utterance.isLowQuality

        // The headline is shown to the user: it may not add words or lose a negation or a number.
        if !decision.headline.isEmpty {
            let words = decision.headline.split(whereSeparator: \.isWhitespace)
            if words.count > maximumHeadlineWords {
                decision.headline = ""
                corrections.append("headline_too_long")
            } else if SemanticText.coverage(of: decision.headline, in: source) < minimumHeadlineCoverage {
                decision.headline = ""
                corrections.append("headline_not_in_utterance")
            } else if SemanticText.isNegated(source) != SemanticText.isNegated(decision.headline) {
                decision.headline = ""
                corrections.append("headline_negation")
            } else if !SemanticText.quantities(in: decision.headline).isSubset(of: SemanticText.quantities(in: source)) {
                decision.headline = ""
                corrections.append("headline_detail")
            }
        }

        switch decision.verdict {
        case .relevant:
            decision.presentation = decision.urgency == .high && !decision.isPersonalRelevanceUncertain ? .alert : .notify
        case .uncertain:
            decision.presentation = .listOnly
        case .irrelevant:
            decision.matchedGoalID = nil
            decision.presentation = .none
        }
        decision.corrections = corrections
        return decision
    }
}
