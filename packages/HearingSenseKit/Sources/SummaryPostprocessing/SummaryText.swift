import Foundation
import NaturalLanguage

/// Splitting a recap into statements and words, as the Window 7/8 checks did (`RecapText`), so
/// that the privacy limits keep meaning exactly what they meant before.
public enum SummaryText {
    /// Reserved system framing for retained historical claims, never current recap evidence.
    static let supersededPrefix = "Superseded: "

    static func isSuperseded(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(supersededPrefix)
    }

    /// The sentences of a text. Line breaks always end a sentence. A sentence the system ends after
    /// a title ("… the meeting with Ms." | "Wang takes place …") is joined to the next one.
    public static func sentences(in text: String) -> [String] {
        var sentences: [String] = []
        for paragraph in text.split(whereSeparator: \.isNewline) {
            let paragraph = String(paragraph)
            var current: [String] = []
            paragraph.enumerateSubstrings(in: paragraph.startIndex..., options: .bySentences) { substring, _, _, _ in
                if let sentence = substring?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty {
                    if let last = current.last, endsWithTitle(last) {
                        current[current.count - 1] = last + " " + sentence
                    } else {
                        current.append(sentence)
                    }
                }
            }
            sentences += current
        }
        return sentences
    }

    /// The statements of a draft in order: the summary's sentences, then the key points (trimmed,
    /// empty ones left out). Each key point is one statement, whatever its punctuation.
    public static func statements(summary: String, keyPoints: [String]) -> (summary: [String], keyPoints: [String]) {
        let points = keyPoints.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return (sentences(in: summary), points)
    }

    private static func endsWithTitle(_ text: String) -> Bool {
        guard let word = text.split(separator: " ").last else { return false }
        return titleAbbreviations.contains(word.lowercased())
    }

    static let titleAbbreviations: Set<String> = ["mr.", "mrs.", "ms.", "dr.", "prof.", "st.", "mt.", "vs.", "jr.", "sr."]

    /// The words of a text, lower-cased (unchanged from Window 8). Text written without spaces
    /// between words (Chinese, Japanese, Thai …) is segmented by the system's tokenizer, so that
    /// "12 words" and "a run of 6 words" mean about the same in every language.
    public static func words(in text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .split { !($0.isLetter || $0.isNumber || $0 == "'") }
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
            .flatMap { $0.unicodeScalars.contains(where: isUnspaced) ? segmented($0) : [$0] }
    }

    /// Scripts that are written without spaces between words.
    static func isUnspaced(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x2E80 ... 0x9FFF, 0xF900 ... 0xFAFF, 0x20000 ... 0x2FA1F, 0xAC00 ... 0xD7AF, 0x0E00 ... 0x0EFF:
            return true
        default:
            return false
        }
    }

    private static func segmented(_ run: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = run
        let tokens = tokenizer.tokens(for: run.startIndex ..< run.endIndex).map { String(run[$0]) }
        return tokens.isEmpty ? [run] : tokens
    }

    /// `words` occur in `other` one after the other, without a gap.
    public static func isRun(_ words: [String], in other: [String]) -> Bool {
        guard !words.isEmpty, words.count <= other.count else { return false }
        return (0 ... (other.count - words.count)).contains { Array(other[$0 ..< $0 + words.count]) == words }
    }

    /// The marker the engine puts where speech could not be transcribed.
    public static func isMissingSpeechMarker(_ line: String) -> Bool {
        let lowered = line.trimmingCharacters(in: .whitespaces).lowercased()
        return lowered.hasPrefix("[") && lowered.contains("could not be transcribed")
    }
}
