import Foundation
import HearingSenseDomain

/// Deterministic faithfulness checks for a model-written headline.
///
/// A language model can silently reverse a sentence ("has not arrived" → "Package Arrived"),
/// drop the one detail that matters ("at 3 PM") or add something nobody said. A headline is
/// only shown when it passes these checks against the transcript it was made from:
///
/// | Check | Rule | Outcome |
/// |---|---|---|
/// | Negation kept | transcript negated ⇒ headline contains a negation word | reject |
/// | Negation not invented | transcript not negated ⇒ headline has no negation word | reject |
/// | Grounded | every content word of the headline is a word (or inflection) of the transcript, or one of a few generic label words | reject |
/// | Time kept | transcript has time expressions ⇒ headline keeps at least one, and a clock time if there is one | repair by appending it, else reject |
/// | Time not invented | headline time expressions occur in the transcript | reject |
/// | Length | at most `SummaryPolicy.maximumWords` words | reject |
/// | Number kept | a number in the transcript is missing | warning (`SpeechSemanticAnalyzer` retries once) |
///
/// Passing means "no rule was violated", not "proven correct": paraphrases can still shift
/// meaning in ways keyword rules cannot see.
public struct SummaryValidator: Sendable {
    public enum Issue: Hashable, Sendable {
        case empty
        case tooLong(words: Int, limit: Int)
        case negationDropped
        case negationInvented
        case unsupportedWords([String])
        case unsupportedTime([String])
        case timeDropped([String])
        case numberDropped([String])

        /// Issue kind without any text from the transcript (safe for logs and diagnostics).
        public var name: String {
            switch self {
            case .empty: "empty headline"
            case .tooLong: "too long"
            case .negationDropped: "negation dropped"
            case .negationInvented: "negation invented"
            case .unsupportedWords: "words not in the transcript"
            case .unsupportedTime: "time not in the transcript"
            case .timeDropped: "time dropped"
            case .numberDropped: "number dropped"
            }
        }

        /// Correction request for the model's next attempt. Stays on the device.
        var feedback: String {
            switch self {
            case .empty:
                "The headline was empty. Write a headline."
            case .tooLong(_, let limit):
                "The headline was too long. Use at most \(limit) words."
            case .negationDropped:
                "The headline dropped the negation. The utterance says something is NOT the case; "
                    + "the headline must contain the word \"not\", \"no\", \"don't\" or \"never\"."
            case .negationInvented:
                "The headline added a negation that the utterance does not contain. Do not negate."
            case .unsupportedWords(let words):
                "The headline used words that are not in the utterance (\(words.joined(separator: ", "))). "
                    + "Use only words from the utterance."
            case .unsupportedTime(let times):
                "The headline mentioned a time that is not in the utterance (\(times.joined(separator: ", ")))."
            case .timeDropped(let times):
                "The headline dropped the time. Keep \"\(times.first ?? "the time")\" in the headline."
            case .numberDropped(let numbers):
                "The headline dropped the number. Keep \"\(numbers.joined(separator: "\" and \""))\" in the headline, "
                    + "together with the words around it."
            }
        }
    }

    public enum Verdict: Hashable, Sendable {
        case accepted(SpeechSummary)
        case rejected([Issue])
    }

    /// Words a headline may use although the transcript does not contain them: labels for the
    /// act of speaking. Kept deliberately short, because every entry is a claim the transcript
    /// does not literally support.
    public static let genericWords: Set<String> = [
        "request", "requested", "asked", "question", "reminder", "warning", "alert", "announcement",
        "greeting", "needed", "soon",
    ]

    static let functionWords: Set<String> = [
        "a", "an", "the", "to", "at", "in", "on", "for", "of", "by", "is", "are", "was", "be", "and", "or", "your",
        "you", "my", "me", "we", "us", "our", "it", "its", "do", "does", "did", "has", "have", "had", "will", "with",
        "from", "this", "that", "there", "here", "please", "i", "he", "she", "they", "them", "his", "her", "their",
        "am", "pm",
    ]

    public var policy: SummaryPolicy

    public init(policy: SummaryPolicy = .standard) {
        self.policy = policy
    }

    public func validate(headline rawHeadline: String, transcript: String) -> Verdict {
        var headline = Self.format(rawHeadline, transcript: transcript)
        guard !headline.isEmpty else { return .rejected([.empty]) }

        let source = UtteranceAnalysis(transcript)
        var summary = UtteranceAnalysis(headline)
        var critical: [Issue] = []
        var notes: [String] = []
        var reliability = SummaryReliability.validated

        if source.isNegated, !summary.isNegated { critical.append(.negationDropped) }
        if !source.isNegated, summary.isNegated { critical.append(.negationInvented) }

        let unsupported = summary.words.filter { word in
            !Self.functionWords.contains(word) && !Self.genericWords.contains(word)
                && !UtteranceAnalysis.negationWords.contains(word) && !word.hasSuffix("n't")
                && !source.supports(word)
        }
        if !unsupported.isEmpty { critical.append(.unsupportedWords(unsupported)) }

        let inventedTimes = summary.timeExpressions.filter { !source.timeExpressions.contains($0) }
        if !inventedTimes.isEmpty { critical.append(.unsupportedTime(inventedTimes)) }

        // A clock time is the most specific part of a sentence: keeping "tomorrow" does not
        // excuse dropping "7:30".
        let missingTime = summary.timeExpressions.isEmpty ? source.timeExpressions.first
            : summary.clockTimes.isEmpty ? source.clockTimes.first : nil
        if let missingTime {
            // Deterministic repair: append the time expression exactly as transcribed.
            let addition = Self.format(missingTime, transcript: transcript)
            let repaired = headline + " " + addition
            if Self.wordCount(repaired) <= policy.maximumWords {
                headline = repaired
                summary = UtteranceAnalysis(headline)
                reliability = .repaired
                notes.append("time appended from the transcript")
            } else {
                critical.append(.timeDropped(source.timeExpressions))
            }
        }

        let words = Self.wordCount(headline)
        if words > policy.maximumWords { critical.append(.tooLong(words: words, limit: policy.maximumWords)) }
        guard critical.isEmpty else { return .rejected(critical) }

        if !Self.missingNumbers(in: headline, transcript: transcript).isEmpty {
            notes.append(Self.numberDroppedNote)
            if reliability == .validated { reliability = .validatedWithWarnings }
        }
        if words > policy.targetWords.upperBound { notes.append("longer than \(policy.targetWords.upperBound) words") }

        return .accepted(SpeechSummary(text: headline, wordCount: words, source: .onDeviceLanguageModel,
                                       reliability: reliability, notes: notes))
    }

    static let numberDroppedNote = Issue.numberDropped([]).name

    /// The transcript's numbers when the headline keeps none of them (empty otherwise).
    static func missingNumbers(in headline: String, transcript: String) -> [String] {
        let numbers = UtteranceAnalysis(transcript).numbers
        let kept = Set(UtteranceAnalysis(headline).words)
        return numbers.contains(where: kept.contains) ? [] : numbers
    }

    /// Correction request for a headline that passed but dropped every number.
    static func numberFeedback(for headline: String, transcript: String) -> String? {
        let missing = missingNumbers(in: headline, transcript: transcript)
        return missing.isEmpty ? nil : Issue.numberDropped(missing).feedback
    }

    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    /// Title Case without surrounding quotes or sentence punctuation. Short words the transcript
    /// writes in capitals ("TV") keep them; "AM"/"PM" are always capitalized.
    public static func format(_ headline: String, transcript: String) -> String {
        let acronyms = Set(transcript.split { !($0.isLetter || $0.isNumber) }
            .map(String.init)
            .filter { word in
                // Short all-capital words such as "TV"; not emphasis ("NOT") or ordinary words.
                (2 ... 4).contains(word.count) && word == word.uppercased() && word.contains(where: \.isLetter)
                    && !UtteranceAnalysis.negationWords.contains(word.lowercased())
                    && !functionWords.contains(word.lowercased())
            })
        let strip = CharacterSet.punctuationCharacters.union(.symbols).union(.whitespacesAndNewlines)
        return headline
            .replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: \.isWhitespace)
            .compactMap { token -> String? in
                let word = token.trimmingCharacters(in: strip)
                guard !word.isEmpty else { return nil }
                let lowered = word.lowercased().replacingOccurrences(of: ".", with: "")
                if lowered == "am" || lowered == "pm" { return lowered.uppercased() }
                if acronyms.contains(word.uppercased()) { return word.uppercased() }
                return word.prefix(1).uppercased() + word.dropFirst().lowercased()
            }
            .joined(separator: " ")
    }
}
