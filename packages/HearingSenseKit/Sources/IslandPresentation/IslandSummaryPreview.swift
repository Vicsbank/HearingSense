import Foundation

/// The short form of a finished summary for the expanded Dynamic Island.
///
/// The island is at most 160 points high. With text large enough to read at a glance that is a
/// title and about two lines. So there are two levels: the full summary, which is saved and
/// read in the app, and this preview, which is made from it — whole sentences chosen from the
/// summary's own key points and sentences, never a sentence cut off in the middle and never a
/// second text written from the transcript. The full summary is not changed by it.
///
/// Pure text work without a language model: making the preview costs nothing and cannot
/// contradict the summary.
public enum IslandSummaryPreview {
    public struct Limits: Hashable, Sendable {
        /// Characters of the title that fit on one line at the heading's size.
        public var heading: Int
        /// Characters of body text that fit in the lines below it.
        public var body: Int

        // Used where the text cannot be measured (tests, previews). On the iPhone 18 Pro's
        // expanded island (about 320 points of text width) three lines of 17-point text hold
        // about 120 characters; the limit leaves room for the breaks between the lines. The
        // app itself measures (`body(summary:keyPoints:newestFirst:fits:)`).
        public init(heading: Int = 36, body: Int = 110) {
            self.heading = heading
            self.body = body
        }

        public static let standard = Limits()
    }

    /// The title on one line: whole when it fits, otherwise its beginning up to a word, without
    /// a trailing connecting word ("Meeting with Ms. Wang about the" → "Meeting with Ms. Wang").
    public static func heading(for title: String, limit: Int = Limits.standard.heading) -> String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.count > limit else { return title }
        var words: [Substring] = []
        var length = 0
        for word in title.split(separator: " ") {
            let added = length == 0 ? word.count : length + 1 + word.count
            if added > limit { break }
            words.append(word)
            length = added
        }
        while let last = words.last, words.count > 1,
              connectingWords.contains(last.lowercased().trimmingCharacters(in: .punctuationCharacters))
        {
            words.removeLast()
        }
        let shortened = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ",;:–—-"))
        return shortened.count >= 6 ? shortened : String(title.prefix(max(limit - 1, 1))) + "…"
    }

    /// As many whole sentences as fit (up to four) with the most to act on: a sentence with a time, a day, a
    /// number or a name comes before one without, a key point before a sentence of the running
    /// text, and a sentence that only announces the topic ("The conversation was about …") last.
    ///
    /// - Parameter newestFirst: while a conversation is followed, what was added last matters most.
    public static func body(summary: String, keyPoints: [String], limit: Int = Limits.standard.body,
                            newestFirst: Bool = false) -> String
    {
        body(summary: summary, keyPoints: keyPoints, newestFirst: newestFirst) { $0.count <= limit }
    }

    /// The same choice with the caller's own test of what fits: the app measures the text in
    /// the island's font and width, so that the lines are filled with whole sentences and
    /// nothing has to be shrunk or cut by the view.
    public static func body(summary: String, keyPoints: [String], newestFirst: Bool = false,
                            fits: (String) -> Bool) -> String
    {
        var seen: Set<String> = []
        var candidates: [(text: String, order: Int, score: Int)] = []
        let points = keyPoints.map(finished)
        let running = sentences(in: summary)
        for (order, text) in ((newestFirst ? points.reversed() : points) + (newestFirst ? running.reversed() : running)).enumerated() {
            let key = text.lowercased().filter { $0.isLetter || $0.isNumber }
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            candidates.append((text, order, score(text)))
        }
        guard !candidates.isEmpty else { return "" }
        // While following, the newest comes first whatever it contains; only a topic
        // announcement stands back.
        let ranked = candidates.sorted { first, second in
            let (a, b) = newestFirst ? (min(first.score, 0), min(second.score, 0)) : (first.score, second.score)
            return a != b ? a > b : first.order < second.order
        }

        var chosen: [(text: String, order: Int, score: Int)] = []
        func joined(_ items: [(text: String, order: Int, score: Int)]) -> String {
            items.sorted { $0.order < $1.order }.map(\.text).joined(separator: " ")
        }
        // The best-ranked sentence that fits is always part of the choice; with it, the
        // combination of further sentences that puts the most facts into the space (among
        // combinations of the same size the better-ranked win). At most six sentences are
        // tried, so at most 32 combinations are measured.
        let pool = Array(ranked.prefix(6))
        var best: (items: [(text: String, order: Int, score: Int)], rank: Int) = ([], .max)
        if let lead = pool.firstIndex(where: { fits($0.text) }) {
            let others = pool.indices.filter { $0 != lead }
            for mask in 0 ..< (1 << others.count) {
                let indices = [lead] + others.indices.filter { mask & (1 << $0) != 0 }.map { others[$0] }
                guard indices.count <= 4, indices.count >= best.items.count else { continue }
                let items = indices.map { pool[$0] }
                // A further sentence must add something: not a mere topic announcement.
                if items.count > 1, !newestFirst, items.contains(where: { $0.score <= 0 }) { continue }
                let rank = indices.reduce(0, +)
                guard items.count > best.items.count || rank < best.rank else { continue }
                if fits(joined(items)) { best = (items, rank) }
            }
        }
        chosen = best.items
        if chosen.isEmpty, let best = ranked.first {
            // Even the best sentence is too long by itself: the longest whole part of it that fits.
            var limit = best.text.count - 1
            while limit > 24 {
                let shorter = shortened(best.text, to: limit)
                if fits(shorter) { return shorter }
                limit = min(limit - 4, shorter.count - 1)
            }
            return shortened(best.text, to: 24)
        }
        return joined(chosen)
    }

    // MARK: - Sentences

    /// Sentences of running text. Unlike a split at every full stop, this keeps "Ms. Wang",
    /// "3 p.m." and "12.30" together.
    public static func sentences(in text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            current.append(character)
            if "。！？".contains(character) {
                // Chinese and Japanese full stops end a sentence wherever they stand.
                sentences.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            } else if character == "." || character == "!" || character == "?" {
                let next = index + 1 < characters.count ? characters[index + 1] : nil
                let afterSpace = characters[(index + 1)...].first { !$0.isWhitespace }
                let endsHere = next == nil
                    || (next!.isWhitespace && (afterSpace == nil || afterSpace!.isUppercase || afterSpace!.isNumber
                            || afterSpace == "“" || afterSpace == "\""))
                if endsHere, character != "." || !endsWithAbbreviation(current) {
                    sentences.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                    current = ""
                }
            }
            index += 1
        }
        let rest = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { sentences.append(finished(rest)) }
        return sentences.filter { !$0.isEmpty }
    }

    private static func endsWithAbbreviation(_ text: String) -> Bool {
        let word = text.dropLast().split(whereSeparator: \.isWhitespace).last.map { $0.lowercased() } ?? ""
        let bare = word.trimmingCharacters(in: CharacterSet(charactersIn: "(\"“"))
        return abbreviations.contains(bare) || (bare.count == 1 && bare.first!.isLetter)
    }

    /// With a full stop when it has no closing punctuation.
    private static func finished(_ text: String) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = text.last else { return "" }
        if ".!?…”\"。！？".contains(last) { return text }
        return text + (isUnspaced(last) ? "。" : ".")
    }

    /// A character of a script written without spaces between words (Chinese, Japanese, Korean).
    static func isUnspaced(_ character: Character) -> Bool {
        character.unicodeScalars.contains { (0x2E80 ... 0x9FFF).contains($0.value) || (0xAC00 ... 0xD7AF).contains($0.value) }
    }

    // MARK: - Ranking and shortening

    private static func score(_ text: String) -> Int {
        let lowered = text.lowercased()
        if topicOpeners.contains(where: lowered.hasPrefix) { return -1 }
        let words = lowered.split { !($0.isLetter || $0.isNumber || $0 == ":" || $0 == ".") }.map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: ".:"))
        }
        var score = 0
        if words.contains(where: { $0.contains(where: \.isNumber) || timeWords.contains($0) })
            || unspacedTimeWords.contains(where: lowered.contains)
        {
            score += 2
        }
        // A capitalized word after the first: a name or a place.
        let tokens = text.split(separator: " ").dropFirst()
        if tokens.contains(where: { $0.first?.isUppercase == true && $0.count > 1 && $0 != "I" }) { score += 1 }
        // A sentence that narrates ("Someone said …") gives way to one that states its fact.
        if narratingOpeners.contains(where: lowered.hasPrefix) { score = max(score - 2, 0) }
        return score
    }

    /// A sentence that is too long by itself, as a shorter whole sentence: up to the last clause
    /// that fits, or — when the sentence has no "not", "if", "until" and the like, whose meaning
    /// a cut could turn around — up to the last added detail ("… at ten | in study room 204").
    /// When neither is in reach it ends at a word and is marked as cut ("…").
    static func shortened(_ sentence: String, to limit: Int) -> String {
        guard sentence.count > limit else { return sentence }
        let head = String(sentence.prefix(limit))
        func lastBreak(_ separators: [String]) -> String.Index? {
            var best: String.Index?
            for separator in separators {
                if let range = head.range(of: separator, options: .backwards), best == nil || range.lowerBound > best! {
                    best = range.lowerBound
                }
            }
            guard let best, head.distance(from: head.startIndex, to: best) >= limit / 2 else { return nil }
            return best
        }
        let words = Set(sentence.lowercased().split { !($0.isLetter || $0 == "'") }.map(String.init))
        let isDelicate = words.contains { delicateWords.contains($0) || $0.hasSuffix("n't") }
        // Chinese clauses end at "，" and "；"; the words that make a cut risky are parts of the
        // running text there ("不", "如果").
        let isUnspacedText = sentence.contains(where: isUnspaced)
        var separators = [", ", "; ", " – ", " — ", " because ", " but ", " and ", " so that ", " which ", " while ", "，", "；"]
        if !isDelicate, !isUnspacedText { separators += [" in ", " at ", " on ", " with ", " for ", " from ", " near "] }
        if let cut = lastBreak(separators) {
            let clause = head[..<cut].trimmingCharacters(in: CharacterSet(charactersIn: " ,;:–—，；、"))
            return clause + ((clause.last.map(isUnspaced) ?? false) ? "。" : ".")
        }
        let room = String(sentence.prefix(max(limit - 1, 1)))
        // Between words where there are spaces; between characters where there are none.
        let cut = (room.last.map(isUnspaced) ?? false) ? room
            : room.range(of: " ", options: .backwards).map { String(room[..<$0.lowerBound]) } ?? room
        return cut.trimmingCharacters(in: CharacterSet(charactersIn: ",;:，；、")) + "…"
    }

    /// With one of these a sentence can mean something else without its ending.
    private static let delicateWords: Set<String> = [
        "not", "no", "never", "nobody", "nothing", "neither", "nor", "without", "cannot", "if", "unless", "until", "only",
        "except", "before", "after", "instead",
    ]

    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "st", "vs", "etc", "no", "a.m", "p.m", "e.g", "i.e", "jr", "sr", "mt", "approx",
    ]

    private static let connectingWords: Set<String> = [
        "a", "an", "the", "and", "or", "of", "to", "in", "on", "at", "for", "with", "about", "from", "by", "as", "is",
        "are", "was", "were", "that", "this", "its", "their", "his", "her", "our", "my", "your", "vs", "&",
    ]

    private static let timeWords: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "today", "tonight", "tomorrow",
        "yesterday", "noon", "midnight", "morning", "afternoon", "evening", "week", "weekend", "month", "january",
        "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december",
        "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve", "half", "am", "pm",
    ]

    private static let unspacedTimeWords = ["今天", "明天", "后天", "昨天", "今晚", "上午", "下午", "晚上", "中午", "星期", "礼拜", "周一", "周二",
                                            "周三", "周四", "周五", "周六", "周日", "点", "點", "月", "号", "號"]

    private static let narratingOpeners = ["someone said", "someone mentioned", "somebody said", "they also said", "it was said"]

    private static let topicOpeners = [
        "the conversation was about", "the conversation is about", "the conversation covered", "this conversation",
        "the discussion was about", "they talked about", "they discussed", "the speakers discussed", "the topic was",
    ]
}
