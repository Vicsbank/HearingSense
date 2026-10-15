import Foundation

/// A spelling change, never a paraphrase: a uniquely located, unquoted tens-plus-unit
/// cardinal may use digits. All acceptance gates still belong to the ordinary copy pass.
enum CardinalFormatRestatement {
    static func candidates(for text: String, normalizer: EnglishNormalizer) -> [String] {
        // Literal wording and identifiers are not quantities that we may reformat.
        let quotes = #"["“”‘]|(?<!\p{L})'|['’](?!\p{L})"#
        guard text.range(of: quotes, options: .regularExpression) == nil else { return [] }
        let tokens = normalizer.tokens(in: text)
        let identifiers = Set(["code", "password", "passcode", "pin", "serial", "identifier", "phone", "telephone", "zip", "postal", "room", "year"].map(Lexicon.stem))
        guard !tokens.contains(where: { identifiers.contains(Lexicon.stem($0.text)) }) else { return [] }
        var result: [String] = []
        for value in normalizer.values(in: tokens) {
            guard value.readings.count == 1, case let .number(amount) = value.readings[0],
                  amount >= 0, amount % 100 == 0, value.tokenRange.count == 2 else { continue }
            let words = Array(tokens[value.tokenRange])
            guard words.allSatisfy({ $0.kind == .word && (!$0.isCapitalized || $0.startsSentence) }),
                  let tens = EnglishNormalizer.tensWords[words[0].original.lowercased()],
                  let units = EnglishNormalizer.units[words[1].original.lowercased()], units > 0,
                  amount == (tens + units) * 100 else { continue }
            if value.tokenRange.lowerBound > 0 {
                let previous = tokens[value.tokenRange.lowerBound - 1].text
                if EnglishNormalizer.timePrepositions.contains(previous) || ["on", "of"].contains(previous) { continue }
            }
            let phrase = words.map { NSRegularExpression.escapedPattern(for: $0.original) }.joined(separator: #"[\s-]+"#)
            let pattern = #"(?<![\p{L}\p{N}'])"# + phrase + #"(?![\p{L}\p{N}'])"#
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
            guard matches.count == 1, let range = Range(matches[0].range, in: text) else { continue }
            var candidate = text
            candidate.replaceSubrange(range, with: String(amount / 100))
            if !result.contains(candidate) { result.append(candidate) }
        }
        return result
    }
}
