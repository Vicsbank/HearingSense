import Foundation
import HearingSenseDomain

/// What a headline says, reduced to what a deterministic comparison can check: its content
/// words, whether it negates, and the numbers and times it mentions.
///
/// Used to decide whether a new summary revision means something different. It cannot recognize
/// synonyms; two wordings it cannot match are treated as different statements, never merged.
struct SemanticSignature: Hashable, Sendable {
    var contentWords: Set<String>
    var isNegative: Bool
    var quantities: Set<String>

    enum Change: Hashable {
        /// Same statement, different wording. Not worth an update.
        case cosmetic
        /// Different content words. Worth a quiet update.
        case refined
        /// The polarity, or a number or time, changed. Must be shown.
        case critical(negation: Bool)
    }

    init(text: String, isNegated: Bool) {
        let words = Self.words(in: text)
        isNegative = isNegated || words.contains { Self.negations.contains($0) || $0.hasSuffix("n't") }
        quantities = Set(words.filter { Self.quantityWords.contains($0) || $0.contains(where: \.isNumber) })
        contentWords = Set(words.filter {
            !Self.stopWords.contains($0) && !Self.negations.contains($0) && !$0.hasSuffix("n't")
        })
    }

    func change(to other: SemanticSignature, sameMeaningSimilarity: Double) -> Change {
        if isNegative != other.isNegative { return .critical(negation: true) }
        if quantities != other.quantities { return .critical(negation: false) }
        if contentWords == other.contentWords { return .cosmetic }
        let union = contentWords.union(other.contentWords).count
        let similarity = union == 0 ? 1 : Double(contentWords.intersection(other.contentWords).count) / Double(union)
        return similarity >= sameMeaningSimilarity ? .cosmetic : .refined
    }

    /// Lower-cased words; apostrophes are kept so contractions ("hasn't") stay recognizable.
    static func words(in text: String) -> [String] {
        let normalized = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        return normalized.split { !($0.isLetter || $0.isNumber || $0 == "'") }
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
    }

    static let negations: Set<String> = ["not", "no", "never", "none", "nothing", "nobody", "cannot", "without",
                                         "neither", "nor"]
    static let stopWords: Set<String> = [
        "a", "an", "the", "is", "are", "was", "were", "be", "been", "being", "has", "have", "had", "will", "would",
        "do", "does", "did", "to", "of", "in", "on", "at", "for", "and", "or", "it", "its", "it's", "this", "that",
        "there", "here", "i", "you", "he", "she", "we", "they", "my", "your", "our", "their", "please", "just", "so",
        "um", "uh", "s",
    ]
    static let quantityWords: Set<String> = [
        "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve", "twenty",
        "thirty", "forty", "fifty", "hundred", "half", "today", "tonight", "tomorrow", "yesterday", "morning",
        "afternoon", "evening", "noon", "midnight", "monday", "tuesday", "wednesday", "thursday", "friday",
        "saturday", "sunday",
    ]
}

/// What the engine keeps of a `SpeechSemanticResult`: the facts its rules use and the validated
/// headline. The transcript itself is read once (for the phrase rule) and not kept.
struct SpeechFacts: Hashable, Sendable {
    var state: SpeechProcessingState
    var level: SpeechOutputLevel
    var utteranceCount: Int
    var category: SpeechSemanticCategory
    var relevance: SpeechRelevance?
    var isUnclear: Bool
    var quality: TranscriptQuality.Rating
    var hasUrgentPhrase: Bool
    var summaryText: String?
    var summaryReliability: SummaryReliability?
    var summaryRevision: Int
    var isNegated: Bool
    var isQuestion: Bool
    var mentionsTimeOrNumber: Bool
    var transcription: TranscriptionAvailability
    var model: SemanticModelAvailability

    init(_ result: SpeechSemanticResult, policy: SpeechAttentionPolicy) {
        state = result.state
        level = result.level
        utteranceCount = result.utteranceCount
        category = result.category
        relevance = result.acousticContext?.relevance
        isUnclear = result.isUnclear
        quality = result.transcript?.quality.rating ?? .unknown
        hasUrgentPhrase = result.utteranceCount > 0 && result.level >= .transcript && !result.isUnclear
            && SpeechAssessment.containsUrgentPhrase(result.transcript?.text ?? "", policy: policy)
        summaryText = result.summary?.text
        summaryReliability = result.summary?.reliability
        summaryRevision = result.summaryRevision
        isNegated = result.details?.isNegated ?? false
        isQuestion = result.details?.isQuestion ?? false
        mentionsTimeOrNumber = result.details?.timeOrNumber != nil
        transcription = result.transcriptionAvailability
        model = result.modelAvailability
    }

    /// Speech known only from the sound classifier (no speech pipeline result).
    static let soundOnly = SpeechFacts()

    private init() {
        state = .detected
        level = .detection
        utteranceCount = 0
        category = .unknown
        relevance = nil
        isUnclear = false
        quality = .unknown
        hasUrgentPhrase = false
        summaryText = nil
        summaryReliability = nil
        summaryRevision = 0
        isNegated = false
        isQuestion = false
        mentionsTimeOrNumber = false
        transcription = .unknown
        model = .unknown
    }
}

/// The engine's reading of one speech event.
struct SpeechAssessment: Hashable, Sendable {
    enum Tier: Int, Hashable, Comparable, Sendable {
        /// Probably lyrics, or speech attention is off.
        case irrelevant
        /// Speech with nothing that marks it as relevant. Without a summary it is never presented.
        case ordinary
        /// A validated summary of a question, request, reminder or announcement.
        case informative
        /// A possible warning.
        case important

        static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    var tier: Tier
    var priority: AttentionPriority
    /// True when the priority should rise to `normal` once the speech is sustained.
    var isConditional: Bool
    var reasons: [AttentionReason]
    var title: String
    var isUncertain: Bool
    var privateContent: AttentionPrivateContent?
    var signature: SemanticSignature?

    static let ordinaryTitle = SpeechSemanticResult.detectionHeadline
    static let warningTitle = "Possible Spoken Warning"

    static func assess(_ facts: SpeechFacts, preferences: AttentionPreferences) -> SpeechAssessment {
        let mode = preferences.mode
        let isMuted = preferences.speech == .off || preferences.setting(for: .speech) == .muted
        if isMuted {
            return SpeechAssessment(tier: .irrelevant, priority: .ambient, isConditional: false,
                                    reasons: [preferences.speech == .off ? .speechAttentionOff : .userMuted],
                                    title: ordinaryTitle, isUncertain: false, privateContent: nil, signature: nil)
        }
        // Probable lyrics never become an alert, whatever the words are.
        if facts.relevance == .possiblyMusic {
            return SpeechAssessment(tier: .irrelevant, priority: .ambient, isConditional: false,
                                    reasons: [.musicContext, .possiblyLyrics, .lowRelevance],
                                    title: SpeechSemanticResult.possiblyMusicHeadline, isUncertain: true,
                                    privateContent: nil, signature: nil)
        }

        var reasons: [AttentionReason] = []
        let hasFinalWords = facts.utteranceCount > 0 && facts.level >= .transcript && !facts.isUnclear
        let warning = hasFinalWords && facts.category == .warning
        let informativeCategories: Set<SpeechSemanticCategory> = [.question, .request, .reminder, .announcement]

        var privateContent: AttentionPrivateContent?
        var signature: SemanticSignature?
        if let text = facts.summaryText {
            privateContent = AttentionPrivateContent(text: text, summaryRevision: facts.summaryRevision,
                                                     isNegated: facts.isNegated, isQuestion: facts.isQuestion)
            signature = SemanticSignature(text: text, isNegated: facts.isNegated)
        }

        let tier: Tier
        var priority: AttentionPriority
        var isConditional = false
        if facts.hasUrgentPhrase || warning {
            tier = .important
            priority = .high
            reasons.append(.importantSpeech)
            if facts.hasUrgentPhrase { reasons.append(.urgentPhrase) }
            // "Don't worry, there is no fire": a negated statement is not treated as a warning on
            // the strength of a keyword alone.
            if facts.isNegated, !warning { priority = .normal }
            if facts.quality == .poor {
                priority = min(priority, .normal)
                reasons.append(.lowRecognitionQuality)
            }
        } else if facts.summaryText != nil, informativeCategories.contains(facts.category) {
            tier = .informative
            reasons.append(.relevantSpeech)
            switch preferences.speech {
            case .importantOnly:
                priority = .low
                reasons.append(.speechImportantOnly)
            case .everything:
                priority = .normal
            default:
                priority = mode == .quiet ? .low : .normal
            }
        } else if facts.summaryText == nil {
            // Nearby speech with nothing to read is an ordinary sound in every mode and under
            // every speech preference: the sound itself is shown as an icon (Window 5's ambient
            // channel) and never becomes an episode. Decided by the student after the device
            // session of Window 5, where "Nearby Speech" without text was presented 12 times in
            // 17 minutes; the rule first lived in the island's presentation only, so the app's
            // Attention card showed episodes the island did not.
            tier = .ordinary
            priority = .ambient
            reasons += [.ordinarySpeech, .speechWithoutSummary]
        } else {
            tier = .ordinary
            reasons.append(.ordinarySpeech)
            switch preferences.speech {
            case .importantOnly:
                priority = .ambient
                reasons.append(.speechImportantOnly)
            case .everything:
                priority = .normal
            default:
                switch mode {
                case .quiet: priority = .ambient
                case .balanced:
                    priority = .low
                    isConditional = true
                case .sensitive: priority = .normal
                }
            }
        }

        if facts.summaryText != nil || tier == .important {
            if facts.mentionsTimeOrNumber { reasons.append(.mentionsTimeOrNumber) }
            if facts.isNegated { reasons.append(.negatedStatement) }
            if facts.isQuestion { reasons.append(.question) }
        }
        if facts.relevance == .speechOverMusic {
            // Less certain than plain nearby speech: at most normal, but still visible.
            if priority > .normal { priority = .normal }
            reasons.append(.musicAmbiguity)
        }
        if facts.level == .detection {
            if facts.transcription == .disabledByUser {
                reasons.append(.transcriptionOff)
            } else if !facts.transcription.isUsable, facts.transcription != .unknown {
                reasons.append(.modelUnavailable)
            }
        } else if facts.summaryText == nil, !facts.model.isUsable, facts.model != .unknown {
            reasons.append(.modelUnavailable)
        }

        let isUncertain = facts.relevance == .speechOverMusic || facts.isUnclear || facts.quality == .poor
            || facts.summaryReliability == .validatedWithWarnings
            || (tier == .important && !warning) // a keyword match alone
        return SpeechAssessment(tier: tier, priority: priority, isConditional: isConditional, reasons: reasons,
                                title: tier == .important ? warningTitle : ordinaryTitle, isUncertain: isUncertain,
                                privateContent: privateContent, signature: signature)
    }

    static func containsUrgentPhrase(_ text: String, policy: SpeechAttentionPolicy) -> Bool {
        let words = SemanticSignature.words(in: text)
        guard !words.isEmpty else { return false }
        let padded = " " + words.joined(separator: " ") + " "
        if policy.urgentPhrases.contains(where: { padded.contains(" " + $0 + " ") }) { return true }
        return words.count <= policy.shortUtteranceMaximumWords
            && words.contains { policy.urgentShortUtteranceWords.contains($0) }
    }
}
