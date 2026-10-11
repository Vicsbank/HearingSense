import Foundation

/// Deterministic checks between the language model and an alert. The model's answer is
/// untrusted: it can cite words nobody said, call a wish a fact, or drop a "not". The verifier
/// can only make a decision more cautious, never less.
public struct EvidenceVerifier: Hashable, Sendable {
    /// Share of the cited evidence's content words that must occur in the utterance.
    public var minimumEvidenceCoverage: Double
    public var minimumHeadlineCoverage: Double
    public var maximumHeadlineWords: Int
    /// The longest headline made of the utterance's own words (Window 6.1).
    public var maximumExtractiveWords: Int

    public init(minimumEvidenceCoverage: Double = 0.6, minimumHeadlineCoverage: Double = 0.6, maximumHeadlineWords: Int = 8,
                maximumExtractiveWords: Int = 12)
    {
        self.minimumEvidenceCoverage = minimumEvidenceCoverage
        self.minimumHeadlineCoverage = minimumHeadlineCoverage
        self.maximumHeadlineWords = maximumHeadlineWords
        self.maximumExtractiveWords = maximumExtractiveWords
    }

    public static let standard = EvidenceVerifier()

    /// Why a decision was made, in fixed words plus the user's own goal: no model text.
    static func reason(for decision: SemanticAttentionDecision, goal: AttentionGoal) -> String {
        let what = switch decision.statementKind {
        case .question: "Someone may be speaking to you or asking for something"
        case .hypothetical: "Said as a possibility, not as settled"
        case .reported: "Said as a story, a quotation or about the past"
        case .noChange: "Said that nothing changes"
        case .unclear: "Hard to tell what was meant"
        case .statement:
            decision.subject == .someoneElse ? "Seems to be about someone else"
                : decision.urgency == .high ? "Possible warning or something to act on now" : "Something may be different or needed"
        }
        return what + " — your goal: " + goal.text
    }

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

        // The second look says it is not a statement about here and now.
        if decision.verdict == .relevant, let confirmation = judgement.confirmation, confirmation != .hereAndNow {
            switch confirmation {
            case .nothingChanges:
                decision.verdict = .irrelevant
                decision.statementKind = .noChange
            case .someoneElse:
                decision.verdict = .uncertain
                decision.subject = .someoneElse
            case .past, .story:
                decision.verdict = .uncertain
                decision.statementKind = .reported
            case .wish:
                decision.verdict = .uncertain
                decision.statementKind = .hypothetical
            case .hereAndNow:
                break
            }
            corrections.append("second_look")
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

        // The reason is the model's own sentence and is shown in the app: it may not name a
        // number, day or time that was not said ("moved to Friday" for an utterance about Wednesday).
        if !decision.reason.isEmpty,
           !SemanticText.quantities(in: decision.reason).isSubset(of: SemanticText.quantities(in: source))
        {
            decision.reason = ""
            corrections.append("reason_detail")
        }

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

        // No text from the model (Window 6.1): the headline is the utterance's own words and the
        // reason names the goal, so nothing that is shown can say more than was said.
        if judgement.headline.isEmpty {
            decision.headline = SemanticText.extractiveHeadline(from: source, maximumWords: maximumExtractiveWords)
            if decision.headline.isEmpty { corrections.append("headline_not_shortened") }
        }
        if judgement.consequence.isEmpty, let goalID = decision.matchedGoalID,
           let goal = goals.first(where: { $0.id == goalID })
        {
            decision.reason = Self.reason(for: decision, goal: goal)
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
