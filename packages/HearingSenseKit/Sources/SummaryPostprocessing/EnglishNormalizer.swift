import Foundation

public enum Meridiem: String, Hashable, Sendable {
    case am
    case pm
}

public enum DayQualifier: String, Hashable, Sendable {
    case this
    case next
    case last
}

public enum ValueKind: String, Hashable, Sendable, CaseIterable {
    case number, ordinal, time, date, weekday, month, money, percent, duration, relativeDay, digits, place
}

/// One way to read a value that was said or written. A spoken value can have several readings
/// ("two twelve": the time 2:12 or the number 212); a written one usually has one.
public enum ValueReading: Hashable, Sendable {
    /// A cardinal in hundredths: 18 → 1800, 3.5 → 350.
    case number(Int)
    /// "the sixteenth", "16th".
    case ordinal(Int)
    /// Hour 1...12, minute 0...59, and the half of the day when it was said.
    case time(Int, Int, Meridiem?)
    /// Month 1...12 when it was said, and the day of the month.
    case date(Int?, Int)
    /// 1 = Monday … 7 = Sunday, with "next" / "this" / "last" when it was said.
    case weekday(Int, DayQualifier?)
    case month(Int)
    /// Cents, and the currency when it was said ("USD").
    case money(Int, String?)
    /// Hundredths of a percent.
    case percent(Int)
    /// Length in seconds, and the count as said in hundredths ("two days" → 172800, 200).
    case duration(Int, Int)
    /// "today", "tomorrow", "tonight", "yesterday", "day after tomorrow".
    case relativeDay(String)
    /// A string of digits said one by one or written as a code ("five five five oh one" → "55501").
    case digits(String)
    /// A conservative named venue phrase ("north gate", "school auditorium").
    case place(String)

    public var kind: ValueKind {
        switch self {
        case .number: return .number
        case .ordinal: return .ordinal
        case .time: return .time
        case .date: return .date
        case .weekday: return .weekday
        case .month: return .month
        case .money: return .money
        case .percent: return .percent
        case .duration: return .duration
        case .relativeDay: return .relativeDay
        case .digits: return .digits
        case .place: return .place
        }
    }

    /// Whether two readings can be the same value. Exact on type and value; a reading that says
    /// less (a time without a.m./p.m., a date without a month, a day without "next") is compatible
    /// with one that says more. A cardinal is never an ordinal ("ten" is not "tenth") and never a
    /// percent. A whole number from 1 to 12 can be that hour on the clock ("we close at five" —
    /// "5:00 PM"): in speech an hour is usually said as a bare number, so that reading is kept.
    public static func isCompatible(_ a: ValueReading, _ b: ValueReading) -> Bool {
        switch (a, b) {
        case let (.number(x), .number(y)):
            return x == y
        case let (.number(x), .time(h, m, _)), let (.time(h, m, _), .number(x)):
            return m == 0 && x == h * 100 && (1 ... 12).contains(h)
        case let (.number(x), .money(c, _)), let (.money(c, _), .number(x)):
            return x == c
        case let (.number(x), .duration(_, count)), let (.duration(_, count), .number(x)):
            return x == count
        case let (.number(x), .digits(s)), let (.digits(s), .number(x)):
            return x >= 0 && x % 100 == 0 && strippedZeros(String(x / 100)) == strippedZeros(s)
        case let (.digits(s), .digits(t)):
            return s == t
        case let (.ordinal(x), .ordinal(y)):
            return x == y
        case let (.ordinal(x), .date(_, d)), let (.date(_, d), .ordinal(x)):
            return x == d
        case let (.date(m1, d1), .date(m2, d2)):
            return d1 == d2 && (m1 == nil || m2 == nil || m1 == m2)
        case let (.time(h1, n1, p1), .time(h2, n2, p2)):
            return h1 == h2 && n1 == n2 && (p1 == nil || p2 == nil || p1 == p2)
        case let (.weekday(d1, q1), .weekday(d2, q2)):
            return d1 == d2 && (q1 == nil || q2 == nil || q1 == q2)
        case let (.month(x), .month(y)):
            return x == y
        case let (.month(x), .date(m, _)), let (.date(m, _), .month(x)):
            return m == x
        case let (.money(c1, k1), .money(c2, k2)):
            return c1 == c2 && (k1 == nil || k2 == nil || k1 == k2)
        case let (.percent(x), .percent(y)):
            return x == y
        case let (.duration(s1, _), .duration(s2, _)):
            return s1 == s2
        case let (.relativeDay(x), .relativeDay(y)):
            return x == y
        case let (.place(x), .place(y)):
            // A recap may omit an optional modifier, but two different modifiers do not agree.
            return x == y || x.hasSuffix(" " + y) || y.hasSuffix(" " + x)
        default:
            return false
        }
    }

    private static func strippedZeros(_ text: String) -> String {
        let stripped = text.drop(while: { $0 == "0" })
        return stripped.isEmpty ? "0" : String(stripped)
    }
}

/// A word, number or punctuation mark of a text, lower-cased and with abbreviations written out
/// one way ("p.m." → "pm", "St." → "st", "can't" → "can" "not").
public struct NormalizedToken: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case word
        case number
        case symbol
        case punctuation
    }

    public var text: String
    /// The token as it was written (case kept), for telling names apart.
    public var original: String
    public var kind: Kind
    /// The first word of a sentence, or of a part after a colon or semicolon.
    public var startsSentence: Bool

    public var isCapitalized: Bool { original.first?.isUppercase ?? false }
    public var isWord: Bool { kind == .word }

    public init(text: String, original: String, kind: Kind, startsSentence: Bool) {
        self.text = text
        self.original = original
        self.kind = kind
        self.startsSentence = startsSentence
    }
}

/// One value found in a text, with every reading it allows.
public struct NormalizedValue: Hashable, Sendable {
    public var readings: [ValueReading]
    /// The tokens it was read from (indices into the token array it came from).
    public var tokenRange: Range<Int>
    /// Said with "around", "about", "maybe", "or so" …
    public var isHedged: Bool
    /// Said with "exactly", "sharp", "on the dot" …
    public var isCertain: Bool

    public init(readings: [ValueReading], tokenRange: Range<Int>, isHedged: Bool = false, isCertain: Bool = false) {
        var unique: [ValueReading] = []
        for reading in readings where !unique.contains(reading) { unique.append(reading) }
        self.readings = unique
        self.tokenRange = tokenRange
        self.isHedged = isHedged
        self.isCertain = isCertain
    }

    public var kinds: Set<ValueKind> { Set(readings.map(\.kind)) }

    /// Some reading of one is compatible with some reading of the other.
    public func isCompatible(with other: NormalizedValue) -> Bool {
        readings.contains { mine in other.readings.contains { ValueReading.isCompatible(mine, $0) } }
    }

    /// Both can be a value of the same type (two days, two times …), whatever the value.
    public func sharesKind(with other: NormalizedValue) -> Bool {
        let comparable: Set<ValueKind> = [.time, .date, .ordinal, .weekday, .month, .money, .percent, .duration, .relativeDay, .place]
        let mine = kinds.intersection(comparable), theirs = other.kinds.intersection(comparable)
        if !mine.isDisjoint(with: theirs) { return true }
        // A date and a day of the month are the same type.
        let days: Set<ValueKind> = [.date, .ordinal]
        if !mine.isDisjoint(with: days), !theirs.isDisjoint(with: days) { return true }
        // Plain numbers only when neither has a more specific type.
        return mine.isEmpty && theirs.isEmpty && kinds.contains(.number) && other.kinds.contains(.number)
    }
}

/// Canonical forms of English values in speech and in writing, and when two of them are the same.
///
/// Spoken forms come from the speech recognizer ("seven forty five", "eighteen dollars", "the
/// twelfth of October"); written forms from the summarizer ("7:45", "$18", "October 12"). A value
/// that can be read more than one way keeps every reading, and two values are equal when some
/// reading of each agrees exactly on type and value. Genuinely ambiguous forms are never forced
/// into one reading ("two twelve" stays 2:12 or 212), and nothing is guessed from outside the text
/// ("next Friday" stays a weekday, never a date).
public struct EnglishNormalizer: Hashable, Sendable {
    public init() {}

    // MARK: Tokens

    static let tokenPattern =
        #"[$€£]?\d+(?:[.,:-]\d+)*(?:%|st|nd|rd|th|am|pm|s)?|\p{L}+(?:'\p{L}+)*|[$€£%]|[.!?;:,()"\[\]]"#

    private static let rewrittenWords: [String: String] = [
        "street": "st", "saint": "st", "avenue": "ave", "road": "rd", "apartment": "apt", "department": "dept",
        "mister": "mr", "missus": "mrs", "mins": "minutes", "hrs": "hours", "secs": "seconds", "wks": "weeks", "yrs": "years",
        "tues": "tuesday", "tue": "tuesday", "thurs": "thursday", "thur": "thursday", "thu": "thursday",
        "weds": "wednesday", "sept": "september", "approx": "approximately", "cannot": "can",
    ]

    /// The tokens of a text. Punctuation stays as tokens of its own (it bounds number words and
    /// clauses); hyphens and dashes do not ("twenty-eight" → "twenty" "eight").
    public func tokens(in text: String) -> [NormalizedToken] {
        var source = text.replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "\u{2018}", with: "'")
        source = source.replacingOccurrences(of: "\u{201C}", with: "\"").replacingOccurrences(of: "\u{201D}", with: "\"")
        source = source.replacingOccurrences(of: "\u{2014}", with: " ; ").replacingOccurrences(of: "\u{2013}", with: " ; ")
        // "p.m." → "pm"; its last period still ends a sentence when a capital follows.
        source = source.replacingOccurrences(of: #"(?<![A-Za-z])([AaPp])\.\s?[Mm]\.(?=\s+\p{Lu})"#, with: "$1m.", options: .regularExpression)
        source = source.replacingOccurrences(of: #"(?i)(?<![a-z])([ap])\.\s?m\.?(?![a-z])"#, with: "$1m", options: .regularExpression)
        source = source.replacingOccurrences(of: #"(?i)\bo'\s?clock\b"#, with: "oclock", options: .regularExpression)
        source = source.replacingOccurrences(of: #"(?i)\bno\.\s*(?=\d)"#, with: "number ", options: .regularExpression)
        // A hyphen between digits stays ("room 1-14", "4-7-1-9", "October 21-25"); any other is a space.
        source = source.replacingOccurrences(of: #"(?<!\d)-|-(?!\d)"#, with: " ", options: .regularExpression)
        source = source.replacingOccurrences(of: "/", with: " ")
        source = source.replacingOccurrences(of: "&", with: " and ")

        guard let expression = try? NSRegularExpression(pattern: Self.tokenPattern, options: [.caseInsensitive]) else { return [] }
        var tokens: [NormalizedToken] = []
        var sentenceStart = true
        let whole = NSRange(source.startIndex..., in: source)
        for match in expression.matches(in: source, range: whole) {
            guard let range = Range(match.range, in: source) else { continue }
            let original = String(source[range])
            let lowered = original.lowercased()
            if lowered.count == 1, let character = lowered.first, ".!?;:,()\"[]".contains(character) {
                if ".!?;:".contains(character) {
                    // A period after a title ("Ms.") or an initial does not end the sentence.
                    let previous = tokens.last
                    let isAbbreviation = character == "." && previous.map { Lexicon.titles.contains($0.text) || ($0.kind == .word && $0.text.count == 1) } == true
                    if !isAbbreviation { sentenceStart = true }
                }
                tokens.append(NormalizedToken(text: lowered, original: original, kind: .punctuation, startsSentence: false))
                continue
            }
            if lowered.count == 1, let character = lowered.first, "$€£%".contains(character) {
                tokens.append(NormalizedToken(text: lowered, original: original, kind: .symbol, startsSentence: false))
                continue
            }
            let isNumber = lowered.first.map { $0.isNumber || "$€£".contains($0) } ?? false
            if isNumber {
                tokens.append(NormalizedToken(text: lowered, original: original, kind: .number, startsSentence: sentenceStart))
                sentenceStart = false
                continue
            }
            for (index, part) in Self.expandedContraction(lowered).enumerated() {
                let text = Self.rewrittenWords[part] ?? Self.numberWordBase(part) ?? part
                tokens.append(NormalizedToken(text: text, original: index == 0 ? original : part, kind: .word,
                                              startsSentence: index == 0 && sentenceStart))
            }
            sentenceStart = false
        }
        return tokens
    }

    /// A number word with a plural or verb ending ("fives", "sixes", "eighty sixed") is the number
    /// word; nil for anything else.
    static func numberWordBase(_ word: String) -> String? {
        guard units[word] == nil, teens[word] == nil, tensWords[word] == nil else { return nil }
        for suffix in ["ed", "es", "s"] where word.hasSuffix(suffix) && word.count > suffix.count + 2 {
            let base = String(word.dropLast(suffix.count))
            if units[base] != nil || teens[base] != nil || tensWords[base] != nil { return base }
        }
        return nil
    }

    /// "can't" → "can" "not", "won't" → "will" "not", "don't" → "do" "not", "cannot" → "can" "not".
    static func expandedContraction(_ word: String) -> [String] {
        if word == "cannot" { return ["can", "not"] }
        if word == "can't" { return ["can", "not"] }
        if word == "won't" { return ["will", "not"] }
        if word == "shan't" { return ["shall", "not"] }
        if word.hasSuffix("n't"), word.count > 3 { return [String(word.dropLast(3)), "not"] }
        return [word]
    }

    // MARK: Values

    /// The values of a text.
    public func values(in text: String) -> [NormalizedValue] { values(in: tokens(in: text)) }

    /// Whether the values of two texts are the same: every value of each has a compatible value
    /// in the other. Two texts without values are not equivalent (there is nothing to compare).
    public func areEquivalent(_ first: String, _ second: String) -> Bool {
        let a = values(in: first), b = values(in: second)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a.allSatisfy { value in b.contains { value.isCompatible(with: $0) } }
            && b.allSatisfy { value in a.contains { value.isCompatible(with: $0) } }
    }
}
