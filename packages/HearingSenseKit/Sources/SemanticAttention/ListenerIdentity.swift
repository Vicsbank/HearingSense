import Foundation
import NaturalLanguage

/// Who the listener says they are, as words that can be compared with a sentence (Window 6.3).
///
/// Only what the listener wrote: the names people call them, and the groups they say they are
/// in ("group B", "the red bus", "study room 3", "the six o'clock spin class"). Nothing here is
/// guessed from speech, and nothing identifies a speaker.
public struct ListenerIdentity: Hashable, Sendable, Codable {
    public var names: [String]
    public var groups: [String]

    public init(names: [String] = [], groups: [String] = []) {
        self.names = names
        self.groups = groups
    }

    public static let unknown = ListenerIdentity()

    public var isEmpty: Bool { names.isEmpty && groups.isEmpty }

    /// Names the listener gives themselves in their own text ("my name is Priya", "I'm Nora",
    /// "people call me Dev", "says my name, Marion"). Read by rule: a name is copied, never
    /// inferred.
    public static func names(in text: String) -> [String] {
        var found: [String] = []
        // After these words any next word is taken as the name; after "I'm" only a capitalised one.
        let explicit = #"(?:my name is|my name's|name is|my name,)\s+([\p{L}][\p{L}'-]+)"#
        let loose = #"(?:\bI'm|\bI am|\bIm|[Cc]alls? me|[Cc]alling me|[Cc]alled|[Kk]nown as)\s+(\p{Lu}[\p{L}'-]+)"#
        let patterns: [(String, NSRegularExpression.Options)] = [(explicit, .caseInsensitive), (loose, [])]
        for (pattern, options) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { continue }
            let normalized = text.replacingOccurrences(of: "\u{2019}", with: "'")
            let range = NSRange(normalized.startIndex..., in: normalized)
            for match in regex.matches(in: normalized, range: range) {
                guard let nameRange = Range(match.range(at: 1), in: normalized) else { continue }
                let name = String(normalized[nameRange])
                guard !notNames.contains(name.lowercased()), !found.contains(where: { $0.lowercased() == name.lowercased() })
                else { continue }
                found.append(name.prefix(1).uppercased() + name.dropFirst())
            }
        }
        return found
    }

    /// Words that follow "I'm" or "my name is" without being a name.
    static let notNames: Set<String> = ["a", "an", "the", "in", "on", "at", "with", "not", "here", "there", "also", "always",
                                        "usually", "often", "just", "going", "travelling", "traveling", "sitting", "working",
                                        "studying", "staying", "waiting", "taking", "part", "one", "called", "said", "mentioned", "or",
                                        "and", "when", "if", "is", "that", "by"]

    /// The labels in the listener's "about me" line: its noun phrases that carry something
    /// which tells one group from another ("red bus", "group B", "study room 3"). By rule.
    public static func groups(inAbout about: String, names: [String]) -> [String] {
        let tokens = AudienceAnalyzer.tokens(in: about)
        var found: [String] = []
        for range in AudienceAnalyzer.phrases(in: tokens, keeping: []) {
            let phrase = AudienceAnalyzer.content(Array(tokens[range])).filter { token in
                !names.contains { $0.lowercased() == token.text.lowercased() } && token.text.lowercased() != "name"
            }
            guard isLabel(phrase), phrase.count <= 5 else { continue }
            let text = phrase.map(\.text).joined(separator: " ")
            if !found.contains(where: { $0.lowercased() == text.lowercased() }) { found.append(text) }
        }
        return found
    }

    /// A label needs something that tells it from its neighbours ("red" in "red bus"), or to be
    /// a name of its own ("Otters"): "class" or "team" alone compares with nothing.
    static func isLabel(_ phrase: [AudienceAnalyzer.Token]) -> Bool {
        guard phrase.contains(where: { !$0.isNumber && !$0.isLabel }) else { return false }
        return phrase.count >= 2 || (phrase.count == 1 && phrase[0].isCapitalized && phrase[0].lexical != .verb)
    }

    /// Adds group phrases that a model copied from the goals, keeping only those that can be
    /// trusted: every word stands in one goal, and that goal speaks of the listener in the first
    /// person there ("…, I sing alto", "table six where I am sitting", "my group, the Otters").
    /// A phrase can be dropped here, never added or changed.
    public func adding(copied phrases: [String], from goals: [String]) -> ListenerIdentity {
        var result = self
        for phrase in phrases {
            let tokens = AudienceAnalyzer.content(AudienceAnalyzer.tokens(in: phrase)).filter { token in
                !names.contains { $0.lowercased() == token.text.lowercased() }
            }
            guard ListenerIdentity.isLabel(tokens), tokens.count <= 5 else { continue }
            let text = tokens.map(\.text).joined(separator: " ")
            guard !result.groups.contains(where: { $0.lowercased() == text.lowercased() }) else { continue }
            let isWritten = goals.contains { goal in
                guard ListenerIdentity.speaksOfSelf(goal) else { return false }
                let written = Set(AudienceAnalyzer.tokens(in: goal).map(\.norm))
                return tokens.allSatisfy { written.contains($0.norm) }
            }
            if isWritten { result.groups.append(text) }
        }
        return result
    }

    /// The goal says something about the listener, not only about what they want to hear.
    static func speaksOfSelf(_ goal: String) -> Bool {
        let words = SemanticText.words(in: goal)
        if words.contains(where: { ["i", "i'm", "i've", "im"].contains($0) }) { return true }
        let lowered = " " + words.joined(separator: " ") + " "
        return lowered.range(of: #" my \w+ the "#, options: .regularExpression) != nil
    }

    static let spokenToPattern = #"\b(talk(s|ing)?|speak(s|ing)?) (to|with) me\b|\bspoken to\b|\bmy attention\b|\b(says?|calls?|calling|shouts?) (out )?my name\b|\b(calls?|calling) (for |out to )?me\b|\blooking for me\b|\b(asks?|asking) (for )?me\b|\bwants? (me\b|a word with me|to (talk|speak) to me)|\bneeds? me\b|\baddress(es|ing)? me\b"#

    /// The 1-based index of the first goal about being spoken to, called or looked for; 0 for none.
    public static func spokenToGoal(in goals: [String]) -> Int {
        for (index, goal) in goals.enumerated() {
            let text = goal.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            if text.range(of: spokenToPattern, options: .regularExpression) != nil { return index + 1 }
        }
        return 0
    }
}

/// What a sentence says about whom it is for, compared with who the listener is.
public struct AudienceCue: Hashable, Sendable {
    public enum Kind: String, Sendable, Codable {
        /// Nothing in the sentence can be compared with the listener.
        case none
        /// It calls the listener by name.
        case listenerNamed
        /// It names a group the listener says they are in.
        case listenerGroup
        /// It begins with a group of the same kind as the listener's, but another one
        /// ("blue bus" when the listener is on the red bus).
        case otherGroup
        /// It calls a person by a name that is not the listener's.
        case otherPerson
        /// It calls a person by name, and the listener's name is not known.
        case unknownPerson
    }

    public var kind: Kind
    /// The words of the sentence the cue rests on.
    public var phrase: String

    public init(kind: Kind = .none, phrase: String = "") {
        self.kind = kind
        self.phrase = phrase
    }

    public static let none = AudienceCue()
}

/// Finds the cue. Rules only; a few milliseconds per sentence.
///
/// The language model was asked to make this comparison in five different ways and could not
/// (it said every sentence was for the listener, "Daniel" for a listener called Priya included;
/// see the Window 6.3 report). It is good at the narrower question that follows a cue, and
/// comparing two names or two labels is exact in code.
public enum AudienceAnalyzer {
    struct Token: Hashable {
        var text: String
        var norm: String
        var isCapitalized: Bool
        var isNumber: Bool
        var isLabel: Bool
        var lexical: NLTag?
        var isPersonalName: Bool
        var segment: Int
        /// "Paolo's", "my roommate's": the thing named after it belongs to someone.
        var isPossessive = false
    }

    static let numberWords: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7", "eight": "8",
        "nine": "9", "ten": "10", "eleven": "11", "twelve": "12", "thirteen": "13", "fourteen": "14", "fifteen": "15",
        "sixteen": "16", "seventeen": "17", "eighteen": "18", "nineteen": "19", "twenty": "20", "thirty": "30", "forty": "40",
        "fifty": "50", "first": "1", "second": "2", "third": "3", "fourth": "4", "fifth": "5", "sixth": "6", "seventh": "7",
        "eighth": "8", "ninth": "9", "tenth": "10",
    ]
    /// Words inside a noun phrase that do not tell one group from another.
    static let determiners: Set<String> = ["the", "a", "an", "this", "that", "these", "those", "my", "your", "our", "their",
                                           "his", "her", "its", "some", "another", "other", "o'clock", "oclock", "clock"]
    static let quantifiers: Set<String> = ["all", "both", "every", "each", "any", "everyone", "everybody", "everyone's"]
    static let genericAdjectives: Set<String> = ["new", "old", "next", "last", "same", "whole", "entire", "main", "big", "little",
                                                 "small", "usual", "regular", "own", "tonight", "today", "tomorrow", "morning",
                                                 "evening", "afternoon", "current", "early", "late", "later", "earlier"]
    /// Words a noun phrase does not run across.
    static let boundaries: Set<String> = [
        "i", "you", "we", "they", "he", "she", "it", "there", "me", "us", "them", "him",
        "is", "are", "was", "were", "be", "been", "being", "am", "has", "have", "had", "do", "does", "did", "will", "would",
        "can", "could", "should", "may", "might", "must", "isn't", "aren't", "won't", "can't", "don't", "doesn't", "didn't",
        "in", "on", "at", "to", "from", "for", "with", "by", "of", "into", "onto", "over", "under", "after", "before", "until",
        "past", "through", "about", "and", "or", "but", "so", "because", "if", "when", "while", "than", "as", "please", "now",
        "not", "just", "then", "also", "still", "again", "here", "who", "which", "what", "where", "how", "no", "yes",
    ]
    /// Words before a leading noun phrase that leave it leading.
    static let openers: Set<String> = ["can", "could", "would", "will", "do", "does", "did", "is", "are", "has", "have", "should",
                                       "in", "of", "from", "at", "on", "for", "please", "and", "so", "ok", "okay", "well", "now",
                                       "right", "hey", "hi", "hello", "oh", "attention", "listen", "up", "reminder", "remember"]
    static let leadingPronouns: Set<String> = ["i", "we", "you", "they", "he", "she", "it", "there", "i'm", "we're", "you're",
                                               "they're", "he's", "she's", "it's", "there's", "i've", "we've", "you'll", "i'll"]
    static let interjections: Set<String> = ["hey", "hi", "hello", "oh", "ok", "okay", "yo", "um", "uh", "well", "so", "and", "now",
                                             "right", "sorry", "excuse", "me", "thanks", "thank", "you", "please", "listen", "look",
                                             "psst", "good", "morning", "afternoon", "evening", "nice", "work", "today", "great",
                                             "job", "but", "wait", "no", "yes", "yeah"]
    /// Words set off by a comma at the start of a sentence that are not somebody's name, whatever
    /// a name tagger makes of a capital letter.
    static let notCalls: Set<String> = ["sorry", "careful", "please", "thanks", "well", "right", "okay", "ok", "listen", "look",
                                        "wait", "stop", "quick", "hello", "hey", "hi", "yes", "no", "yeah", "sure", "great", "good",
                                        "fine", "true", "honestly", "actually", "seriously", "remember", "reminder", "attention",
                                        "everyone", "everybody", "folks", "guys", "team", "class", "people", "all", "sir", "madam",
                                        "ma'am", "miss", "mate", "buddy", "dude", "man", "boss", "dear", "honey", "love", "kids",
                                        "children", "ladies", "gentlemen", "today", "tonight", "tomorrow", "now", "first", "also"]
    static let titles: Set<String> = ["mr", "mrs", "ms", "miss", "dr", "doctor", "professor", "prof", "coach", "officer", "nurse",
                                      "chef", "captain", "sergeant", "father", "sister", "brother", "uncle", "aunt", "auntie"]

    static func tokens(in text: String) -> [Token] {
        let source = text.replacingOccurrences(of: "\u{2019}", with: "'")
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .nameType])
        tagger.string = source
        tagger.setLanguage(.english, range: source.startIndex ..< source.endIndex)
        var tokens: [Token] = []
        var segment = 0
        var cursor = source.startIndex
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation]
        tagger.enumerateTags(in: source.startIndex ..< source.endIndex, unit: .word, scheme: .lexicalClass, options: options) {
            tag, range in
            // Commas, semicolons and dashes between this word and the one before start a new segment.
            if source[cursor ..< range.lowerBound].contains(where: { ",;:—–".contains($0) }) { segment += 1 }
            cursor = range.upperBound
            var word = String(source[range])
            var isPossessive = false
            if word.lowercased() == "'s" {
                // The tagger gives the "'s" as a word of its own: a verb in "the heating's broken",
                // something else in "my roommate's group".
                if tag != .verb, !tokens.isEmpty, tokens[tokens.count - 1].lexical == .noun {
                    tokens[tokens.count - 1].isPossessive = true
                }
                return true
            }
            if word.lowercased().hasSuffix("'s") {
                word.removeLast(2)
                isPossessive = tag == .noun
            }
            let lower = word.lowercased()
            guard !lower.isEmpty else { return true }
            let name = tagger.tag(at: range.lowerBound, unit: .word, scheme: .nameType).0
            let previous = tokens.last
            let number = numberWords[lower] ?? (lower.allSatisfy(\.isNumber) ? lower : nil)
            // "Group A", "team B": a single capital letter after a word of the same segment is a label.
            let isLabel = word.count == 1 && word.first?.isUppercase == true && word != "I" && previous?.segment == segment
                && previous?.isNumber == false
            let norm = number ?? (isLabel ? "#" + lower : AudienceAnalyzer.norm(lower))
            tokens.append(Token(text: word, norm: norm, isCapitalized: word.first?.isUppercase == true, isNumber: number != nil,
                                isLabel: isLabel, lexical: tag, isPersonalName: name == .personalName, segment: segment,
                                isPossessive: isPossessive))
            return true
        }
        return tokens
    }

    /// A word without its plural or "-er" ending, so that "spinners" meets "spin" and "buses" "bus".
    static func norm(_ word: String) -> String {
        var word = word
        if word.hasSuffix("sses") || word.hasSuffix("xes") || word.hasSuffix("ches") || word.hasSuffix("shes") || word.hasSuffix("ses") {
            word.removeLast(2)
        } else if word.hasSuffix("ies"), word.count > 4 {
            word.removeLast(3)
            word += "y"
        } else if word.hasSuffix("s"), !word.hasSuffix("ss"), word.count > 3 {
            word.removeLast()
        }
        if word.hasSuffix("er"), word.count > 5 {
            word.removeLast(2)
            let letters = Array(word)
            if letters.count >= 2, letters[letters.count - 1] == letters[letters.count - 2] { word.removeLast() }
        }
        return word
    }

    static let foreignOwners: Set<String> = ["their", "his", "her", "theirs"]

    /// The tokens that can tell one group from another.
    static func content(_ tokens: [Token]) -> [Token] {
        tokens.filter { token in
            let lower = token.text.lowercased()
            if token.isLabel || token.isNumber { return true }
            return !determiners.contains(lower) && !genericAdjectives.contains(lower) && !boundaries.contains(lower)
                && !quantifiers.contains(lower) && lower.count > 1
        }
    }

    enum Relation { case none, same, different }

    /// How a phrase of the sentence stands to one of the listener's groups.
    ///
    /// A group has a head, the last word that is not a number or a letter ("bus" in "red bus",
    /// "group" in "group B"), and marks, the rest, which tell it from its neighbours. A phrase
    /// with the same head and one of the marks is the same group; with the same head and marks
    /// of its own only, another one. "The bus" alone says nothing, and "the bus driver" is not
    /// a bus.
    static func relation(of phrase: [Token], to group: [Token]) -> Relation {
        let groupContent = content(group)
        guard let head = groupContent.last(where: { !$0.isNumber && !$0.isLabel })?.norm else { return .none }
        if phrase.contains(where: { quantifiers.contains($0.text.lowercased()) }) { return .none }
        let own = content(phrase)
        let marks = Set(groupContent.filter { $0.norm != head }.map(\.norm))
        let numbers = Set(groupContent.filter { $0.isNumber || $0.isLabel }.map(\.norm))
        let wordMarks = marks.subtracting(numbers)
        var phraseMarks = own.filter { $0.norm != head }
        var hasHead = false
        if let index = phrase.firstIndex(where: { $0.norm == head }) {
            hasHead = true
            let after = phrase[(index + 1)...]
            // A noun right after the head makes something else of it ("bus driver", "room key").
            let isCompound = after.first.map { !$0.isNumber && !$0.isLabel && $0.lexical == .noun } ?? false
            phraseMarks = content(Array(phrase[..<index])) + after.prefix { $0.isNumber || $0.isLabel }
            if isCompound, Set(phraseMarks.map(\.norm)).isDisjoint(with: marks) { return .none }
        }
        let phraseNorms = Set(phraseMarks.map(\.norm))
        let phraseNumbers = Set(phraseMarks.filter { $0.isNumber || $0.isLabel }.map(\.norm))
        let sharedWords = phraseNorms.intersection(wordMarks)
        guard hasHead || !sharedWords.isEmpty else { return .none }
        if !numbers.isEmpty, !phraseNumbers.isEmpty, numbers.isDisjoint(with: phraseNumbers) { return .different }
        // Someone else's ("my roommate's study group") is not the listener's, whatever it shares.
        if phraseMarks.contains(where: \.isPossessive) || phrase.contains(where: { foreignOwners.contains($0.text.lowercased()) }) {
            return hasHead ? .different : .none
        }
        if !sharedWords.isEmpty { return .same }
        if hasHead, !phraseNumbers.isDisjoint(with: numbers) { return .same }
        if hasHead, marks.isEmpty { return .same }
        if hasHead, !phraseNorms.isEmpty { return .different }
        return .none
    }

    /// Runs of words that can form one noun phrase.
    static func phrases(in tokens: [Token], keeping kept: Set<String>) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start: Int?
        for (index, token) in tokens.enumerated() {
            let lower = token.text.lowercased()
            let isOutside = boundaries.contains(lower) || (token.lexical == .verb && !kept.contains(token.norm) && !token.isNumber)
            // A determiner inside a run starts the next phrase ("yesterday's tour | the bus").
            let breaks = isOutside || (start != nil && tokens[index - 1].segment != token.segment)
                || (start != nil && start != index && determiners.contains(lower) && !token.isLabel && lower != "o'clock"
                    && lower != "clock")
            if breaks {
                if let begin = start, begin < index { ranges.append(begin ..< index) }
                start = isOutside ? nil : index
            } else if start == nil {
                start = index
            }
        }
        if let begin = start, begin < tokens.count { ranges.append(begin ..< tokens.count) }
        return ranges
    }

    /// A person called by name: a short segment set off by commas, at the start, in the middle
    /// or at the end ("Tom, …", "Excuse me, Tom, …", "…, Tom.").
    static func calledName(in tokens: [Token], names: [String]) -> [Token]? {
        guard let last = tokens.last?.segment, last >= 1 else { return nil }
        for segment in 0 ... last {
            var words = tokens.filter { $0.segment == segment }
            if segment == 0 {
                while let first = words.first, interjections.contains(first.text.lowercased()), words.count > 1 { words.removeFirst() }
            }
            var hasTitle = false
            if let first = words.first, titles.contains(first.text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))),
               words.count > 1
            {
                hasTitle = true
                words.removeFirst()
            }
            guard (1 ... 2).contains(words.count), words.allSatisfy(\.isCapitalized),
                  words.allSatisfy({ !$0.isNumber && !$0.isLabel && !notCalls.contains($0.text.lowercased()) }),
                  words.allSatisfy({ $0.lexical == .noun || $0.lexical == nil || $0.lexical == .otherWord })
            else { continue }
            let matchesListener = words.contains { word in names.contains { isSameName(word.text, $0) } }
            if hasTitle || matchesListener || words.contains(where: \.isPersonalName) { return words }
        }
        return nil
    }

    /// The same name, allowing for what a speech recognizer does to names ("Jordon" for "Jordan").
    static func isSameName(_ heard: String, _ name: String) -> Bool {
        let one = heard.lowercased(), other = name.lowercased()
        if one == other { return true }
        guard min(one.count, other.count) >= 4, abs(one.count - other.count) <= 1, one.first == other.first else { return false }
        return editDistance(Array(one), Array(other)) <= 1
    }

    static func editDistance(_ first: [Character], _ second: [Character]) -> Int {
        var row = Array(0 ... second.count)
        for (i, a) in first.enumerated() {
            var previous = row[0]
            row[0] = i + 1
            for (j, b) in second.enumerated() {
                let current = row[j + 1]
                row[j + 1] = a == b ? previous : min(previous, row[j], current) + 1
                previous = current
            }
        }
        return row[second.count]
    }

    public static func cue(in sentence: String, identity: ListenerIdentity) -> AudienceCue {
        let tokens = tokens(in: sentence)
        guard !tokens.isEmpty else { return .none }
        let called = calledName(in: tokens, names: identity.names)
        if let called, called.contains(where: { word in identity.names.contains { isSameName(word.text, $0) } }) {
            return AudienceCue(kind: .listenerNamed, phrase: called.map(\.text).joined(separator: " "))
        }
        let groups = identity.groups.map { AudienceAnalyzer.tokens(in: $0) }
        let kept = Set(groups.flatMap { content($0).map(\.norm) })
        var other: AudienceCue?
        for range in phrases(in: tokens, keeping: kept) {
            let phrase = Array(tokens[range])
            for group in groups {
                switch relation(of: phrase, to: group) {
                case .same:
                    return AudienceCue(kind: .listenerGroup, phrase: phrase.map(\.text).joined(separator: " "))
                case .different where other == nil && isLeading(range, in: tokens):
                    other = AudienceCue(kind: .otherGroup, phrase: phrase.map(\.text).joined(separator: " "))
                case .different, .none:
                    break
                }
            }
        }
        if let other { return other }
        if let called {
            return AudienceCue(kind: identity.names.isEmpty ? .unknownPerson : .otherPerson,
                               phrase: called.map(\.text).joined(separator: " "))
        }
        return .none
    }

    /// The phrase is what the sentence is said to or begins with: nothing but openers and the
    /// words of a noun phrase come before it, and the sentence does not begin with "I", "we", …
    static func isLeading(_ range: Range<Int>, in tokens: [Token]) -> Bool {
        guard let first = tokens.first, !leadingPronouns.contains(first.text.lowercased()) else { return false }
        for token in tokens[..<range.lowerBound] {
            let lower = token.text.lowercased()
            if openers.contains(lower) || determiners.contains(lower) || interjections.contains(lower) { continue }
            if token.lexical == .noun || token.lexical == .adjective || token.isNumber { continue }
            return false
        }
        return true
    }
}

extension SemanticText {
    static let danglingWords: Set<String> = [
        "the", "a", "an", "to", "of", "be", "is", "are", "was", "were", "and", "or", "but", "that", "because", "so", "if",
        "with", "for", "your", "my", "our", "their", "his", "her", "its", "will", "would", "can", "could", "should", "at",
        "in", "on", "by", "from", "about", "than", "as", "have", "has", "had", "going", "gonna",
    ]

    /// The sentence stops before it has said anything: no closing punctuation, and its last word
    /// is one that cannot end a sentence ("… the new time is going to be", "… you all need to").
    static func isCutOff(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last, !".!?".contains(last), let word = words(in: trimmed).last else { return false }
        return danglingWords.contains(word) && words(in: trimmed).count >= 3
    }

    static let leaningStarts: Set<String> = ["it", "it's", "they", "they've", "they're", "he", "he's", "she", "she's", "that",
                                             "that's", "those", "these", "and", "then", "but", "no", "not", "yes", "yeah", "just",
                                             "only", "now", "so", "because", "which", "either", "neither", "both"]

    /// The sentence cannot be understood without the one before it: it begins with a pronoun or a
    /// word that continues ("It got moved …", "No, three …", "And he shouts …").
    static func leansOnContext(_ text: String) -> Bool {
        guard let first = words(in: text).first else { return false }
        return leaningStarts.contains(first)
    }
}
