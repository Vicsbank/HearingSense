import Foundation
import HearingSenseDomain

/// Keyword rules that work without any model: the fallback when Apple Foundation Models is
/// unavailable, and the source of the details that must not depend on a model's judgement
/// (negation, question, time).
///
/// It never writes a summary. With rules alone the app shows the real transcript plus a coarse
/// category, which is honest about how little was understood.
public enum RuleBasedInterpreter {
    static let fillerWords: Set<String> = [
        "uh", "um", "er", "ah", "eh", "hmm", "mm", "hm", "the", "a", "an", "and", "so", "it", "like", "you", "know",
        "well", "oh", "i", "mean",
    ]

    static let greetingWords: Set<String> = ["hi", "hello", "hey", "morning", "evening", "afternoon", "bye", "goodbye", "welcome"]
    static let requestStarts = ["can you", "could you", "would you", "will you", "please", "can i", "could i", "may i",
                                "would you mind", "i need you", "help me"]
    static let reminderPhrases = ["don't forget", "do not forget", "remember", "remind", "make sure"]
    static let warningPhrases = ["watch out", "look out", "be careful", "careful", "danger", "warning", "hurry",
                                 "emergency", "fire"]

    /// True if the transcript is too thin to interpret: no words, poor recognition quality, or
    /// nothing but filler words.
    public static func isUnclear(_ request: SemanticRequest) -> Bool {
        let words = UtteranceAnalysis(request.transcript).words
        if words.isEmpty || request.quality.rating == .poor { return true }
        return words.allSatisfy { fillerWords.contains($0) }
    }

    public static func category(of transcript: String) -> SpeechSemanticCategory {
        let analysis = UtteranceAnalysis(transcript)
        let words = analysis.words
        guard !words.isEmpty else { return .unknown }
        let text = words.joined(separator: " ")
        // Skip a leading greeting or attention word: "Hey, can you help me?" is a request.
        let body = words.drop { greetingWords.contains($0) || $0 == "good" || $0 == "excuse" || $0 == "me" }
        let bodyText = body.joined(separator: " ")

        if warningPhrases.contains(where: { Self.contains(phrase: $0, in: text) }) { return .warning }
        if reminderPhrases.contains(where: { Self.contains(phrase: $0, in: text) }) { return .reminder }
        if requestStarts.contains(where: { bodyText.hasPrefix($0) }) { return .request }
        if analysis.isQuestion { return .question }
        if body.isEmpty || (words.count <= 4 && greetingWords.contains(words[0])) { return .greeting }
        return .other
    }

    /// Details that rules can state reliably. `subject` is left to the model.
    public static func details(of transcript: String, source: SpeechSemanticDetails.Source = .rules) -> SpeechSemanticDetails {
        let analysis = UtteranceAnalysis(transcript)
        return SpeechSemanticDetails(source: source, subject: nil,
                                     timeOrNumber: analysis.timeExpressions.first ?? analysis.numbers.first,
                                     isNegated: analysis.isNegated, isQuestion: analysis.isQuestion)
    }

    private static func contains(phrase: String, in text: String) -> Bool {
        (" " + text + " ").contains(" " + phrase + " ")
    }
}
