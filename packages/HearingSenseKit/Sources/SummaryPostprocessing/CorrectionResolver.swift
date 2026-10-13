import Foundation

/// An explicit change of a value in speech: "The meeting is Thursday." … "Actually, move it to
/// Friday." The earlier value is superseded; the later one is current.
public struct Correction: Hashable, Sendable {
    public enum Cue: String, Hashable, Sendable {
        /// "actually", "no wait", "I mean", "scratch that", "make that", "sorry", "correction".
        case repair
        /// "move it to", "changed to", "pushed to", "rescheduled for".
        case changeVerb
        case instead
        /// "is now on", "now at".
        case isNow
        /// "from Thursday to Friday".
        case fromTo
        /// "Wednesday, not Monday", "not three but four".
        case notThis
        /// A "no" at the start of a reply that gives another value ("no, it's four minutes").
        case answerNo
        /// "No need to bring twenty dollars" withdraws a payment instruction, not a price.
        case waivedPaymentRequirement
    }

    public var cue: Cue
    public var newValue: NormalizedValue
    public var newLine: Int
    /// The value it replaces and the line it was said in; nil when no earlier value of the same
    /// type was found (the correction is then known but not applied to anything).
    public var oldValue: NormalizedValue?
    public var oldLine: Int?
    /// Content stems of the slot: the words of the old line and the new one, without the words
    /// of the change itself.
    public var topic: Set<String>
}

/// Finds corrections in a transcript, works out the current value of a corrected slot, and tells
/// whether a statement presents a superseded value as current.
public struct CorrectionResolver: Hashable, Sendable {
    /// How many utterances back the value a correction replaces may lie.
    public var lookback: Int

    public init(lookback: Int = 8) {
        self.lookback = lookback
    }

    private static let changeVerbs: Set<String> = [
        "move", "moved", "moving", "change", "changed", "changing", "switch", "switched", "push", "pushed", "postpone",
        "postponed", "reschedule", "rescheduled", "shift", "shifted", "bump", "bumped",
    ]
    private static let repairWords: Set<String> = ["actually", "correction", "sorry", "scratch"]
    private static let locationStems = Set(["location", "venue"].map(Lexicon.canonicalStem))
    /// Words of the change itself, left out of a slot's topic.
    private static let changeStems: Set<String> = [
        "wait", "mean", "meant", "sorry", "correction", "mov", "chang", "switch", "push", "shift", "bump", "instead",
        "scratch", "mak", "make", "let", "do", "actually", "now",
    ]
    /// Kinds that name a slot's value. Plain numbers count only between two plain numbers.
    private static let slotKinds: Set<ValueKind> = [.time, .date, .ordinal, .weekday, .month, .money, .percent, .duration, .relativeDay, .number, .place]

    public func corrections(in lines: [String]) -> [Correction] {
        corrections(in: AnalyzedTranscript(lines: lines))
    }

    public func corrections(in transcript: AnalyzedTranscript) -> [Correction] {
        var found: [Correction] = []
        for (index, line) in transcript.lines.enumerated() where !line.isMissingSpeechMarker && !line.values.isEmpty {
            found += corrections(inLine: line, at: index, transcript: transcript)
        }
        // A correction of a correction is about the same slot ("Thursday" → "Friday" → "no wait,
        // Monday"): it inherits the topic of the one it corrects.
        for index in found.indices {
            for earlier in found[..<index] where earlier.newLine == found[index].oldLine {
                if let old = found[index].oldValue, old.isCompatible(with: earlier.newValue) {
                    found[index].topic.formUnion(earlier.topic)
                }
            }
        }
        return found
    }

    /// The values of a text without the parts of a larger value (the month of a date).
    private func slotValues(_ text: AnalyzedText) -> [NormalizedValue] {
        text.values.filter { value in
            !text.values.contains { other in
                other != value && other.tokenRange.count > value.tokenRange.count
                    && other.tokenRange.lowerBound <= value.tokenRange.lowerBound && other.tokenRange.upperBound >= value.tokenRange.upperBound
            }
        }
    }

    private func corrections(inLine line: AnalyzedText, at index: Int, transcript: AnalyzedTranscript) -> [Correction] {
        let tokens = line.tokens
        let words = tokens.map { $0.kind == .word ? $0.text : "" }
        let values = slotValues(line)
        var results: [Correction] = []

        func makeCorrection(_ cue: Correction.Cue, new: NormalizedValue, old: NormalizedValue?, oldLine: Int?) -> Correction {
            var topic = Set(line.contentStems)
            if let oldLine { topic.formUnion(transcript.lines[oldLine].contentStems) }
            topic.subtract(Self.changeStems)
            if new.kinds.contains(.place) { topic.formUnion(Self.locationStems) }
            // "Thursday noon, not Wednesday" names no matter: it answers the utterance before it.
            if topic.isEmpty, index > 0 { topic = Set(transcript.lines[index - 1].contentStems).subtracting(Self.changeStems) }
            return Correction(cue: cue, newValue: new, newLine: index, oldValue: old, oldLine: oldLine, topic: topic)
        }

        // Natural speech puts "now" after the predicate too: "tickets are free now".
        // Only a parsed zero price with an explicit temporal change counts, not a payment waiver.
        if !line.isQuestion, words.contains("now"), let zero = values.first(where: { value in
            value.readings.contains { if case let .money(amount, _) = $0 { return amount == 0 }; return false }
        }), let earlier = earlierValue(like: zero, before: index, within: lookback, line: line, transcript: transcript,
                                        anyMatterWithin: 0, implicitChange: false)
        {
            results.append(makeCorrection(.isNow, new: zero, old: earlier.0, oldLine: earlier.1))
        }

        // A revoked instruction is narrower than a zero price: not needing to bring cash may
        // mean paying another way. Only supersede affirmative bring/pay requirements below.
        if !line.isQuestion, let need = words.firstIndex(of: "need"), need > 0,
           ["no", "not"].contains(words[need - 1]),
           let amount = values.first(where: { $0.kinds.contains(.money) && $0.tokenRange.lowerBound > need })
        {
            let waived = NormalizedValue(readings: [.money(0, nil)], tokenRange: (need - 1) ..< need + 1)
            let instructionWords: Set<String> = ["bring", "pay", "need", "required", "must", "requested", "request", "owed"]
            let topic = line.contentStemSet.subtracting(["need", "bring", "pay"])
            let previousInstruction = transcript.lines.indices.prefix(index).reversed().first { previous in
                guard index - previous <= lookback else { return false }
                let candidate = transcript.lines[previous]
                return candidate.containsWord(in: instructionWords)
                    && candidate.values.contains { $0.isCompatible(with: amount) }
                    && (!topic.isDisjoint(with: candidate.contentStemSet) || (topic.isEmpty && previous == index - 1))
            }
            results.append(makeCorrection(.waivedPaymentRequirement, new: waived, old: amount, oldLine: previousInstruction ?? index))
        }

        // In-line: "from X to Y".
        if let from = words.firstIndex(of: "from") {
            let after = values.filter { $0.tokenRange.lowerBound > from }
            if after.count >= 2, after[0].tokenRange.lowerBound <= from + 3, after[0].sharesKind(with: after[1]),
               !after[0].isCompatible(with: after[1]), after[0].tokenRange.upperBound <= after[1].tokenRange.lowerBound,
               words[after[0].tokenRange.upperBound ..< after[1].tokenRange.lowerBound].contains("to")
            {
                results.append(makeCorrection(.fromTo, new: after[1], old: after[0], oldLine: index))
            }
        }

        // In-line: a value with a "not" right before it, and another of the same type without one.
        for rejected in values where isNegated(rejected, in: words) {
            let kept = values.first { candidate in
                candidate != rejected && !isNegated(candidate, in: words) && candidate.sharesKind(with: rejected)
                    && !candidate.isCompatible(with: rejected)
            }
            if let kept { results.append(makeCorrection(.notThis, new: kept, old: rejected, oldLine: index)) }
        }

        // A question is a proposal, not a change.
        if line.isYesNoQuestion { return [] }

        // An explicit "Y instead of X" identifies both sides of the repair, even when
        // "sorry" or "make that" appears first. The rejected X is not further information.
        if let instead = words.firstIndex(of: "instead"), instead + 1 < words.count, words[instead + 1] == "of",
           let kept = values.last(where: { $0.tokenRange.upperBound <= instead }),
           let rejected = values.first(where: {
               $0.tokenRange.lowerBound > instead && $0.tokenRange.lowerBound <= instead + 3
                   && $0.sharesKind(with: kept) && !$0.isCompatible(with: kept)
           })
        {
            return [makeCorrection(.instead, new: kept, old: rejected, oldLine: index)]
        }

        // The cue and where the new value is. A strong repair ("no wait", "I mean", "scratch that",
        // "make that") fixes what was just said; a weak cue ("actually", "sorry", a reply "no", a
        // change verb) changes something only when it is about the same matter.
        var cueIndex: Int?
        var cue = Correction.Cue.repair
        var isStrongRepair = false
        for (position, word) in words.enumerated() where !word.isEmpty {
            let previousWord = position > 0 ? words[position - 1] : ""
            let nextWord = position + 1 < words.count ? words[position + 1] : ""
            let isStrong = (word == "wait" && (previousWord == "no" || nextWord == "no"))
                || ((word == "mean" || word == "meant") && previousWord == "i")
                || (word == "make" && (nextWord == "that" || nextWord == "it"))
                || word == "scratch" || word == "correction"
            let valueFollows = values.contains { $0.tokenRange.lowerBound > position && $0.tokenRange.lowerBound <= position + 3 }
            let isRepair = isStrong || word == "actually" || (word == "sorry" && valueFollows)
            if isRepair {
                cueIndex = position
                cue = .repair
                isStrongRepair = isStrong
                break
            }
            if Self.changeVerbs.contains(word) {
                let reach = words[(position + 1) ..< min(words.count, position + 5)]
                if let to = reach.firstIndex(where: { $0 == "to" || $0 == "for" || $0 == "until" || $0 == "till" }) {
                    cueIndex = to
                    cue = .changeVerb
                    break
                }
            }
            if word == "instead" {
                cueIndex = position
                cue = .instead
                break
            }
            if word == "now", ["is", "are", "it's", "that's", "be"].contains(previousWord) {
                cueIndex = position
                cue = .isNow
                break
            }
        }

        // A reply "no" followed by the answer ("no, it's four", "no Sunday …"), not a "no" that
        // starts a phrase ("no more than two pages", "no phones").
        if cueIndex == nil, line.startsWithDenial, let first = words.firstIndex(where: { !$0.isEmpty && !Lexicon.leadingFillers.contains($0) }) {
            let following = first + 1 < words.count ? words[first + 1] : ""
            let answerWords: Set<String> = ["no", "it's", "its", "it", "that's", "that", "wait", "sorry", "actually", "i", "i'm", "we", "it'll", "is", "was"]
            let valueFollows = values.contains { $0.tokenRange.lowerBound == first + 1 || $0.tokenRange.lowerBound == first + 2 }
            if first + 1 >= tokens.count || tokens[first + 1].kind == .punctuation || answerWords.contains(following) || valueFollows {
                cueIndex = first
                cue = .answerNo
            }
        }
        guard let cueAt = cueIndex else { return results }

        // New values: after the cue; for "instead" also the one right before it. A repair or a
        // reply corrects one value: the first one after it (the rest is further information).
        let boundRanges = Set(results.flatMap { [$0.newValue.tokenRange] + ($0.oldValue.map { [$0.tokenRange] } ?? []) })
        var newValues = values.filter { $0.tokenRange.lowerBound > cueAt && !boundRanges.contains($0.tokenRange) }
        if cue == .repair || cue == .answerNo { newValues = Array(newValues.prefix(1)) }
        var inlineOld: [NormalizedValue] = []
        if cue == .instead {
            if cueAt + 1 < words.count, words[cueAt + 1] == "of" {
                inlineOld = newValues.filter { $0.tokenRange.lowerBound <= cueAt + 3 }
                newValues = values.filter { value in !inlineOld.contains(value) }
            } else if let before = values.last(where: { $0.tokenRange.upperBound <= cueAt }) {
                newValues = [before]
            }
        } else if cue == .isNow {
            inlineOld = values.filter { $0.tokenRange.upperBound <= cueAt }
        }

        for new in newValues where !new.kinds.isDisjoint(with: Self.slotKinds) {
            if let old = inlineOld.first(where: { $0.sharesKind(with: new) && !$0.isCompatible(with: new) }) {
                results.append(makeCorrection(cue, new: new, old: old, oldLine: index))
                continue
            }
            if cue == .isNow, inlineOld.contains(where: { $0.sharesKind(with: new) }) { continue }
            let window = cue == .answerNo ? 2 : lookback
            if let earlier = earlierValue(like: new, before: index, within: window, line: line, transcript: transcript,
                                          anyMatterWithin: isStrongRepair ? 2 : 0,
                                          implicitChange: words.contains("it") && words.contains(where: Self.changeVerbs.contains))
            {
                results.append(makeCorrection(cue, new: new, old: earlier.0, oldLine: earlier.1))
            }
        }
        return results
    }

    /// The most recent earlier value of the same type that differs from `new`. When the
    /// correcting utterance names its matter, the earlier utterance has to share a content word
    /// with it (a shared number alone is no evidence: "and now in sports … by six" changes no
    /// closing time); within `anyMatterWithin` utterances (a strong repair) any value counts.
    private func earlierValue(like new: NormalizedValue, before index: Int, within window: Int, line: AnalyzedText,
                              transcript: AnalyzedTranscript, anyMatterWithin: Int, implicitChange: Bool) -> (NormalizedValue, Int)?
    {
        let topic = Set(line.contentStems).subtracting(Self.changeStems)
        var position = index - 1
        while position >= 0, position >= index - window {
            let candidate = transcript.lines[position]
            if let old = slotValues(candidate).last(where: { $0.sharesKind(with: new) && !$0.isCompatible(with: new) }) {
                if topic.isEmpty || !topic.isDisjoint(with: candidate.contentStemSet) || index - position <= anyMatterWithin {
                    return (old, position)
                }
            }
            position -= 1
        }
        // "Move it to Friday; the same time works better for Dana" refers to the immediately
        // preceding slot despite adding new rationale. Prefer a named-topic match above; only
        // fall back when that adjacent utterance has a single slot of this type.
        if implicitChange, index > 0 {
            let adjacent = slotValues(transcript.lines[index - 1]).filter { $0.sharesKind(with: new) }
            if adjacent.count == 1, let old = adjacent.first, !old.isCompatible(with: new) { return (old, index - 1) }
        }
        return nil
    }

    private func isNegated(_ value: NormalizedValue, in words: [String]) -> Bool {
        let start = value.tokenRange.lowerBound
        for offset in 1 ... 2 where start - offset >= 0 {
            if words[start - offset] == "not" { return true }
        }
        return false
    }

    /// The value a correction leads to in the end, following later corrections of the same
    /// slot (Thursday → Friday → Monday gives Monday).
    public func finalValue(of correction: Correction, in corrections: [Correction]) -> NormalizedValue {
        func chainTopic(_ correction: Correction) -> Set<String> {
            var topic = correction.topic.subtracting(Self.locationStems)
            for value in [correction.newValue] + (correction.oldValue.map { [$0] } ?? []) {
                for reading in value.readings {
                    if case let .place(phrase) = reading {
                        topic.subtract(phrase.split(separator: " ").map { Lexicon.canonicalStem(String($0)) })
                    }
                }
            }
            return topic
        }
        var current = correction
        var guardCount = 0
        while guardCount < corrections.count,
              let next = corrections.first(where: { later in
                  guard later.newLine > current.newLine, let old = later.oldValue else { return false }
                  return old.isCompatible(with: current.newValue)
                      && (later.oldLine == current.newLine || !chainTopic(later).isDisjoint(with: chainTopic(current)))
              })
        {
            current = next
            guardCount += 1
        }
        return current.newValue
    }

    /// The correction whose superseded value `statement` presents as current, if any. A statement
    /// that frames the change ("moved from Thursday to Friday", "originally Thursday"), names the
    /// current value, or rejects the old one ("not Thursday") is not affected. Neither is a value
    /// said again, unchanged, after the correction (it belongs to something else), or a statement
    /// about another topic.
    public func supersededCorrection(for statement: AnalyzedText, corrections: [Correction], transcript: AnalyzedTranscript,
                                     fromLine: Int = 0) -> Correction?
    {
        let correctionLines = Set(corrections.flatMap { [$0.newLine] + ($0.oldLine.map { [$0] } ?? []) })
        let words = statement.tokens.map { $0.kind == .word ? $0.text : "" }
        let framed = statement.tokens.contains { $0.kind == .word && Lexicon.changeFramingWords.contains($0.text) }
        for correction in corrections where correction.newLine >= fromLine {
            guard let old = correction.oldValue else { continue }
            var correctionTopic = correction.topic
            if old.kinds.contains(.place) {
                // A venue change does not make unrelated facts about the old building false.
                let locationWords: Set<String> = ["at", "in", "location", "venue", "meet", "meeting", "held", "scheduled"]
                guard statement.containsWord(in: locationWords) else { continue }
                // A shared building name identifies the value, not the event that uses it.
                // Keep generic location labels for abbreviated recap points, but exclude both
                // venue phrases when deciding whether this correction belongs to another event.
                for value in [old, correction.newValue] {
                    for reading in value.readings {
                        if case let .place(phrase) = reading {
                            correctionTopic.subtract(phrase.split(separator: " ").map { Lexicon.canonicalStem(String($0)) })
                        }
                    }
                }
            }
            if correction.cue == .waivedPaymentRequirement {
                let requirementWords: Set<String> = ["bring", "pay", "need", "required", "must", "requested", "request", "owed"]
                guard !statement.hasNegation, statement.containsWord(in: requirementWords) else { continue }
            }
            let final = finalValue(of: correction, in: corrections)
            for value in statement.values where value.isCompatible(with: old) && !value.isCompatible(with: final) {
                let topicOverlap = statement.contentStemSet.intersection(correctionTopic).count
                let laterLines = transcript.lines.indices.filter { $0 > correction.newLine && !correctionLines.contains($0) }
                let saidAgain = laterLines.contains { lineIndex in
                    let line = transcript.lines[lineIndex]
                    guard line.values.contains(where: { $0.isCompatible(with: value) }) else { return false }
                    if old.kinds.contains(.place) {
                        return line.contentStemSet.intersection(statement.contentStemSet).count > topicOverlap
                    }
                    return true
                }
                if saidAgain { continue }
                // Said again in the correcting utterance itself, after the new value, for something
                // else ("it's the nineteenth, the twelfth is the wedding").
                let restated = transcript.lines[correction.newLine].values.contains { candidate in
                    candidate.isCompatible(with: value) && candidate.tokenRange.lowerBound > correction.newValue.tokenRange.lowerBound
                        && !(correction.oldLine == correction.newLine && candidate.tokenRange == old.tokenRange)
                        && !corrections.contains { rejected in
                            (rejected.oldLine == correction.newLine
                                || (rejected.cue == .waivedPaymentRequirement && rejected.newLine == correction.newLine))
                                && rejected.oldValue?.tokenRange == candidate.tokenRange
                        }
                }
                if restated, !old.kinds.contains(.place), correction.cue != .waivedPaymentRequirement { continue }
                if !correctionTopic.isEmpty, topicOverlap == 0 { continue }
                // Another utterance that holds the value, is about another matter and matches the
                // statement better: that is what the statement reports.
                let betterElsewhere = transcript.lines.indices.contains { lineIndex in
                    let line = transcript.lines[lineIndex]
                    guard !correctionLines.contains(lineIndex), line.contentStemSet.isDisjoint(with: correctionTopic),
                          line.values.contains(where: { $0.isCompatible(with: value) })
                    else { return false }
                    return line.contentStemSet.intersection(statement.contentStemSet).count > topicOverlap
                }
                if betterElsewhere { continue }
                if framed { continue }
                if statement.values.contains(where: { $0.isCompatible(with: final) && !isNegated($0, in: words) }) { continue }
                let start = value.tokenRange.lowerBound
                let before = (1 ... 3).compactMap { start - $0 >= 0 ? words[start - $0] : nil }
                if before.contains(where: { Lexicon.negators.contains($0) }) || before.prefix(2).contains("from") { continue }
                return correction
            }
        }
        return nil
    }
}
