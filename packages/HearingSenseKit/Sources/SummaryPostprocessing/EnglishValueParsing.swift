import Foundation

/// Reading numbers, times, dates, money, percentages and durations out of tokens.
extension EnglishNormalizer {
    static let units: [String: Int] = ["zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9]
    static let teens: [String: Int] = [
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    static let tensWords: [String: Int] = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90]
    static let ordinalUnits: [String: Int] = ["first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9]
    static let ordinalTeens: [String: Int] = [
        "tenth": 10, "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fourteenth": 14, "fifteenth": 15,
        "sixteenth": 16, "seventeenth": 17, "eighteenth": 18, "nineteenth": 19,
    ]
    static let ordinalTens: [String: Int] = ["twentieth": 20, "thirtieth": 30, "fortieth": 40, "fiftieth": 50, "sixtieth": 60, "seventieth": 70, "eightieth": 80, "ninetieth": 90]
    static let weekdays: [String: Int] = [
        "monday": 1, "tuesday": 2, "wednesday": 3, "thursday": 4, "friday": 5, "saturday": 6, "sunday": 7,
        "mondays": 1, "tuesdays": 2, "wednesdays": 3, "thursdays": 4, "fridays": 5, "saturdays": 6, "sundays": 7,
    ]
    static let months: [String: Int] = [
        "january": 1, "february": 2, "march": 3, "april": 4, "may": 5, "june": 6, "july": 7, "august": 8,
        "september": 9, "october": 10, "november": 11, "december": 12,
    ]
    /// Month names that are also ordinary words: a month only next to a day or after "in", "of" ….
    static let ambiguousMonths: Set<String> = ["may", "march", "august"]
    static let monthAbbreviations: [String: Int] = [
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12,
    ]
    static let durationUnits: [String: Int] = [
        "second": 1, "seconds": 1, "minute": 60, "minutes": 60, "hour": 3600, "hours": 3600, "day": 86400,
        "days": 86400, "week": 604_800, "weeks": 604_800, "month": 2_592_000, "months": 2_592_000,
        "year": 31_536_000, "years": 31_536_000,
    ]
    static let durationModifiers: Set<String> = ["extra", "more", "additional", "full", "whole", "straight", "long", "short", "free"]
    static let timePrepositions: Set<String> = ["at", "around", "by", "until", "till", "til", "before", "after", "from", "since", "between", "about", "past"]
    static let monthPrepositions: Set<String> = ["in", "of", "since", "until", "by", "early", "late", "mid", "from", "till", "during", "through"]
    static let rangeConnectors: Set<String> = ["to", "through", "thru", "until", "till"]
    static let hedgeBefore: Set<String> = ["around", "about", "roughly", "approximately", "maybe", "probably", "possibly", "perhaps", "likely", "nearly", "almost", "estimated", "expected", "sometime", "approx"]
    static let hedgeAfter: Set<String> = ["ish", "maybe", "probably", "approximately", "roughly", "think", "guess"]
    static let certainWords: Set<String> = ["exactly", "sharp", "precisely", "promptly", "definitely"]
    static let venueHeads: Set<String> = ["auditorium", "cafeteria", "library", "gym", "theater", "theatre", "house", "gate", "entrance"]
    static let venueModifiers: Set<String> = ["school", "main", "north", "south", "east", "west", "front", "rear", "back", "public", "community"]
    static let priceContext: Set<String> = ["ticket", "tickets", "price", "prices", "cost", "costs", "fee", "fees", "admission", "entry", "parking", "garage", "payment", "pay", "charge", "charged"]

    /// The values of a token array, in order.
    public func values(in tokens: [NormalizedToken]) -> [NormalizedValue] {
        var found: [NormalizedValue] = []
        var index = 0
        while index < tokens.count {
            if let result = value(in: tokens, at: index) {
                found += result.0
                index = max(result.1, index + 1)
            } else {
                index += 1
            }
        }
        var result = found.map { annotated($0, in: tokens) }
        // "seventy one percent and we want eighty": a percent said once covers the bare numbers
        // said with it.
        if result.contains(where: { value in value.readings.contains { $0.kind == .percent } }) {
            for position in result.indices {
                guard result[position].readings.count == 1, case let .number(amount) = result[position].readings[0], amount <= 10000 else { continue }
                result[position].readings.append(.percent(amount))
            }
        }
        return result
    }

    // MARK: One value

    private func word(_ tokens: [NormalizedToken], _ index: Int) -> String? {
        guard index >= 0, index < tokens.count, tokens[index].kind == .word else { return nil }
        return tokens[index].text
    }

    private func value(in tokens: [NormalizedToken], at index: Int) -> ([NormalizedValue], Int)? {
        let token = tokens[index]
        if token.kind == .number { return digitValue(tokens, at: index) }
        guard token.kind == .word else { return nil }
        let text = token.text

        // Only literal venue heads and bounded modifiers: ordinary names and arbitrary noun
        // phrases are not treated as locations. Context still decides whether one is a changed slot.
        if Self.venueHeads.contains(text) {
            var start = index
            while start > 0, index - start < 2, let previous = word(tokens, start - 1),
                  Self.venueModifiers.contains(previous) || previous.hasSuffix("'s") {
                start -= 1
            }
            let phrase = tokens[start ... index].map(\.text).joined(separator: " ")
            return ([NormalizedValue(readings: [.place(phrase)], tokenRange: start ..< index + 1)], index + 1)
        }
        // "Free" is a zero price only in a payment context; "feel free" and "free time" are
        // never prices. A stated zero price carries no invented currency.
        let refersToFreeItem = word(tokens, index - 1) == "for" || word(tokens, index - 1) == "it's"
            || (word(tokens, index - 1) == "is" && word(tokens, index - 2) == "it")
            || (word(tokens, index + 1) == "of" && word(tokens, index + 2) == "charge")
        if text == "free", word(tokens, index - 1) != "feel", word(tokens, index + 1) != "time",
           refersToFreeItem || tokens[max(0, index - 8) ..< index].contains(where: { Self.priceContext.contains($0.text) }) {
            return ([NormalizedValue(readings: [.money(0, nil)], tokenRange: index ..< index + 1)], index + 1)
        }

        // Days relative to today.
        if text == "day", word(tokens, index + 1) == "after", word(tokens, index + 2) == "tomorrow" {
            return ([NormalizedValue(readings: [.relativeDay("day after tomorrow")], tokenRange: index ..< index + 3)], index + 3)
        }
        switch text {
        case "today", "tomorrow", "yesterday":
            return ([NormalizedValue(readings: [.relativeDay(text)], tokenRange: index ..< index + 1)], index + 1)
        case "tonight":
            return ([NormalizedValue(readings: [.relativeDay("tonight"), .relativeDay("today")], tokenRange: index ..< index + 1)], index + 1)
        case "this":
            if let next = word(tokens, index + 1), ["morning", "afternoon", "evening"].contains(next) {
                let readings: [ValueReading] = next == "evening" ? [.relativeDay("today"), .relativeDay("tonight")] : [.relativeDay("today")]
                return ([NormalizedValue(readings: readings, tokenRange: index ..< index + 2)], index + 2)
            }
            return nil
        case "noon", "midday":
            return ([NormalizedValue(readings: [.time(12, 0, .pm)], tokenRange: index ..< index + 1)], index + 1)
        case "midnight":
            return ([NormalizedValue(readings: [.time(12, 0, .am)], tokenRange: index ..< index + 1)], index + 1)
        default:
            break
        }

        if let time = clockPhrase(tokens, at: index) { return time }

        if let day = Self.weekdays[text] {
            var qualifier: DayQualifier?
            switch word(tokens, index - 1) ?? "" {
            case "next", "coming", "following": qualifier = .next
            case "this": qualifier = .this
            case "last", "past": qualifier = .last
            default: qualifier = nil
            }
            return ([NormalizedValue(readings: [.weekday(day, qualifier)], tokenRange: index ..< index + 1)], index + 1)
        }

        if let month = monthNumber(tokens, at: index) { return monthValue(tokens, at: index, month: month) }

        return wordNumberValue(tokens, at: index)
    }

    /// "a quarter past nine", "half past six", "quarter to ten", "ten past five", "twenty five after four".
    private func clockPhrase(_ tokens: [NormalizedToken], at index: Int) -> ([NormalizedValue], Int)? {
        var minutes: Int?
        var length = 0
        var isTo = false
        switch word(tokens, index) ?? "" {
        case "quarter": minutes = 15; length = 1
        case "half": minutes = 30; length = 1
        case "twenty":
            if word(tokens, index + 1) == "five" { minutes = 25; length = 2 } else { minutes = 20; length = 1 }
        case "five": minutes = 5; length = 1
        case "ten": minutes = 10; length = 1
        default: return nil
        }
        guard let minute = minutes else { return nil }
        let relation = word(tokens, index + length)
        if relation == "past" || relation == "after" {
            isTo = false
        } else if minute == 15, relation == "to" || relation == "till" || relation == "of" {
            isTo = true
        } else {
            return nil
        }
        guard let hourFound = hourAt(tokens, index + length + 1) else { return nil }
        let hour = hourFound.0, hourEnd = hourFound.1
        let start = word(tokens, index - 1) == "a" ? index - 1 : index
        let reading: ValueReading = isTo ? .time(hour == 1 ? 12 : hour - 1, 60 - minute, nil) : .time(hour, minute, nil)
        return ([NormalizedValue(readings: [reading], tokenRange: start ..< hourEnd)], hourEnd)
    }

    /// An hour 1...12 written as one word or as digits.
    private func hourAt(_ tokens: [NormalizedToken], _ index: Int) -> (Int, Int)? {
        guard index < tokens.count else { return nil }
        if let text = word(tokens, index), let value = Self.units[text] ?? Self.teens[text], (1 ... 12).contains(value) {
            return (value, index + 1)
        }
        if tokens[index].kind == .number, let value = Int(tokens[index].text), (1 ... 12).contains(value) {
            return (value, index + 1)
        }
        return nil
    }

    private func monthNumber(_ tokens: [NormalizedToken], at index: Int) -> Int? {
        guard let text = word(tokens, index) else { return nil }
        if let month = Self.months[text] {
            guard Self.ambiguousMonths.contains(text) else { return month }
            if dayAt(tokens, index + 1) != nil || dayRangeToken(tokens, index + 1) != nil { return month }
            if text != "may", tokens[index].isCapitalized, !tokens[index].startsSentence { return month }
            // "in May", "since March"; never "this may be later".
            guard let previous = word(tokens, index - 1), Self.monthPrepositions.contains(previous) else { return nil }
            if text == "may", let next = word(tokens, index + 1), !["and", "or", "next", "last", "this"].contains(next) { return nil }
            return month
        }
        if let month = Self.monthAbbreviations[text], dayAt(tokens, index + 1) != nil { return month }
        return nil
    }

    /// "21-25" after a month: two days of the month.
    private func dayRangeToken(_ tokens: [NormalizedToken], _ index: Int) -> (Int, Int)? {
        var position = index
        if word(tokens, position) == "the" { position += 1 }
        guard position < tokens.count, tokens[position].kind == .number else { return nil }
        let parts = tokens[position].text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2, (1 ... 31).contains(parts[0]), (1 ... 31).contains(parts[1]), parts[0] < parts[1] else { return nil }
        return (parts[0], parts[1])
    }

    /// A day of the month right after a month: "28", "28th", "twenty eighth", "the 28th".
    private func dayAt(_ tokens: [NormalizedToken], _ index: Int) -> (day: Int, end: Int)? {
        var position = index
        if word(tokens, position) == "the" { position += 1 }
        guard position < tokens.count else { return nil }
        if tokens[position].kind == .number {
            let text = tokens[position].text
            let digits = text.prefix(while: { $0.isNumber })
            let rest = text.dropFirst(digits.count)
            guard let value = Int(digits), (1 ... 31).contains(value), rest.isEmpty || ["st", "nd", "rd", "th"].contains(String(rest)) else { return nil }
            return (value, position + 1)
        }
        guard let run = numberRun(tokens, at: position), run.digits == nil, run.groups.count == 1 else { return nil }
        let group = run.groups[0]
        guard group.hundredths == 0, (1 ... 31).contains(group.value) else { return nil }
        return (group.value, run.end)
    }

    private func monthValue(_ tokens: [NormalizedToken], at index: Int, month: Int) -> ([NormalizedValue], Int) {
        let monthOnly = NormalizedValue(readings: [.month(month)], tokenRange: index ..< index + 1)
        if let range = dayRangeToken(tokens, index + 1) {
            let end = word(tokens, index + 1) == "the" ? index + 3 : index + 2
            return ([NormalizedValue(readings: [.date(month, range.0)], tokenRange: index ..< end),
                     NormalizedValue(readings: [.date(month, range.1)], tokenRange: end - 1 ..< end), monthOnly], end)
        }
        guard let found = dayAt(tokens, index + 1) else { return ([monthOnly], index + 1) }
        var values = [NormalizedValue(readings: [.date(month, found.day)], tokenRange: index ..< found.end), monthOnly]
        var end = found.end
        // "October 21 to 25", "December fourth through the sixth": the second day is in the same month.
        if let connector = word(tokens, end), Self.rangeConnectors.contains(connector), let second = dayAt(tokens, end + 1) {
            let after = word(tokens, second.end) ?? ""
            if !["am", "pm", "oclock"].contains(after) {
                values.insert(NormalizedValue(readings: [.date(month, second.day)], tokenRange: end + 1 ..< second.end), at: 1)
                end = second.end
            }
        }
        return (values, end)
    }

    // MARK: Number words

    struct NumberGroup {
        var value: Int
        var hundredths: Int
        var isOrdinal: Bool
        var isSingleDigit: Bool
        var isTwoDigitForm: Bool
        var isOhForm: Bool
        var start: Int
        var end: Int
    }

    private func small(_ tokens: [NormalizedToken], _ index: Int) -> (value: Int, ordinal: Bool, length: Int, single: Bool, twoDigit: Bool)? {
        guard let text = word(tokens, index) else { return nil }
        if let value = Self.units[text] { return (value, false, 1, true, false) }
        if let value = Self.teens[text] { return (value, false, 1, false, true) }
        if let value = Self.ordinalUnits[text] { return (value, true, 1, true, false) }
        if let value = Self.ordinalTeens[text] { return (value, true, 1, false, true) }
        if let value = Self.ordinalTens[text] { return (value, true, 1, false, true) }
        if let value = Self.tensWords[text] {
            if let next = word(tokens, index + 1) {
                if let unit = Self.units[next], unit > 0 { return (value + unit, false, 2, false, true) }
                if let unit = Self.ordinalUnits[next] { return (value + unit, true, 2, false, true) }
            }
            return (value, false, 1, false, true)
        }
        return nil
    }

    /// One cardinal or ordinal said in words: "seven", "forty five", "one hundred and forty",
    /// "two thousand nineteen", "twelve hundred", "three point five", "twenty eighth".
    private func numberGroup(_ tokens: [NormalizedToken], at start: Int) -> NumberGroup? {
        let count = tokens.count
        var index = start
        var current = 0
        var isOrdinal = false
        var single = false
        var twoDigit = false
        let scales: Set<String> = ["hundred", "thousand", "dozen", "million"]
        if let text = word(tokens, index), text == "a" || text == "an", let next = word(tokens, index + 1), scales.contains(next) {
            current = 1
            index += 1
        } else if let first = small(tokens, index) {
            current = first.value
            index += first.length
            isOrdinal = first.ordinal
            single = first.single
            twoDigit = first.twoDigit
        } else {
            return nil
        }
        var total = 0
        var usedScale = false
        if !isOrdinal {
            scaling: while index < count, let text = word(tokens, index) {
                switch text {
                case "hundred", "hundredth":
                    guard current >= 1, current < 100 else { break scaling }
                    current *= 100
                    usedScale = true
                    index += 1
                    if text == "hundredth" {
                        isOrdinal = true
                        break scaling
                    }
                    var next = index
                    if word(tokens, next) == "and", small(tokens, next + 1) != nil { next += 1 }
                    if let part = small(tokens, next) {
                        current += part.value
                        index = next + part.length
                        if part.ordinal {
                            isOrdinal = true
                            break scaling
                        }
                    }
                case "thousand", "thousandth", "million", "millionth":
                    let scale = text.hasPrefix("thousand") ? 1000 : 1_000_000
                    total += max(current, 1) * scale
                    current = 0
                    usedScale = true
                    index += 1
                    if text.hasSuffix("th") {
                        isOrdinal = true
                        break scaling
                    }
                    var next = index
                    if word(tokens, next) == "and", small(tokens, next + 1) != nil { next += 1 }
                    guard let part = small(tokens, next) else { break scaling }
                    current = part.value
                    index = next + part.length
                    if part.ordinal {
                        isOrdinal = true
                        break scaling
                    }
                case "dozen":
                    current = max(current, 1) * 12
                    usedScale = true
                    index += 1
                    break scaling
                default:
                    break scaling
                }
            }
        }
        var hundredths = 0
        if !isOrdinal, word(tokens, index) == "point", let first = word(tokens, index + 1), let digit = Self.units[first] {
            hundredths = digit * 10
            index += 2
            if let second = word(tokens, index), let digit2 = Self.units[second] {
                hundredths += digit2
                index += 1
            }
            while let more = word(tokens, index), Self.units[more] != nil { index += 1 }
        } else if !isOrdinal, word(tokens, index) == "and", word(tokens, index + 1) == "a", word(tokens, index + 2) == "half" {
            hundredths = 50
            index += 3
        }
        if usedScale || hundredths > 0 {
            single = false
            twoDigit = false
        }
        return NumberGroup(value: total + current, hundredths: hundredths, isOrdinal: isOrdinal, isSingleDigit: single,
                           isTwoDigitForm: twoDigit, isOhForm: false, start: start, end: index)
    }

    /// The number words starting at `start`: either digits said one by one (three or more, as in
    /// a phone number) or a sequence of groups ("seven" "forty five").
    func numberRun(_ tokens: [NormalizedToken], at start: Int) -> (groups: [NumberGroup], end: Int, digits: String?)? {
        var index = start
        var digits = ""
        while let text = word(tokens, index) {
            if let unit = Self.units[text] {
                digits += String(unit)
            } else if text == "oh" || text == "o", index > start, let next = word(tokens, index + 1),
                      Self.units[next] != nil || next == "oh" || next == "o"
            {
                digits += "0"
            } else {
                break
            }
            index += 1
        }
        if index - start >= 3 { return ([], index, digits) }

        var groups: [NumberGroup] = []
        index = start
        while index < tokens.count {
            if !groups.isEmpty, let text = word(tokens, index), text == "oh" || text == "o", let next = word(tokens, index + 1),
               let unit = Self.units[next]
            {
                groups.append(NumberGroup(value: unit, hundredths: 0, isOrdinal: false, isSingleDigit: false, isTwoDigitForm: true,
                                          isOhForm: true, start: index, end: index + 2))
                index += 2
                continue
            }
            guard let group = numberGroup(tokens, at: index) else { break }
            groups.append(group)
            index = group.end
            if group.isOrdinal { break }
        }
        guard !groups.isEmpty else { return nil }
        return (groups, index, nil)
    }

    private func wordNumberValue(_ tokens: [NormalizedToken], at index: Int) -> ([NormalizedValue], Int)? {
        guard let run = numberRun(tokens, at: index) else { return nil }
        let groups = run.groups, end = run.end
        if let digits = run.digits {
            // "seven oh five" is also the time 7:05 and the number 705.
            var readings: [ValueReading] = []
            if end - index == 3, let middle = word(tokens, index + 1), middle == "oh" || middle == "o",
               let first = word(tokens, index).flatMap({ Self.units[$0] }), let last = word(tokens, index + 2).flatMap({ Self.units[$0] })
            {
                if (1 ... 12).contains(first) { readings.append(.time(first, last, nil)) }
                readings.append(.number((first * 100 + last) * 100))
            }
            readings.append(.digits(digits))
            let value = NormalizedValue(readings: readings, tokenRange: index ..< end)
            guard readings.count > 1 else { return ([value], end) }
            let suffixed = withSuffix(value, tokens: tokens, end: end)
            return ([suffixed.0], max(end, suffixed.1))
        }
        var values: [NormalizedValue] = []
        if groups.count == 2, let pair = pairValue(groups[0], groups[1]) {
            values = [pair]
        } else {
            for group in groups {
                if let value = singleValue(group, tokens: tokens) { values.append(value) }
            }
        }
        guard !values.isEmpty else { return ([], end) }
        let suffixed = withSuffix(values[values.count - 1], tokens: tokens, end: end)
        let last = withPrefix(suffixed.0, tokens: tokens)
        let after = suffixed.1
        values[values.count - 1] = last
        if values.count > 1 { values[0] = withPrefix(values[0], tokens: tokens) }
        return (values, max(after, end))
    }

    /// "seven forty five": the time 7:45 or the number 745; "two twelve": 2:12 or 212;
    /// "nineteen ninety": 1990. Nil when the two groups are not such a pair.
    private func pairValue(_ first: NumberGroup, _ second: NumberGroup) -> NormalizedValue? {
        guard !first.isOrdinal, !second.isOrdinal, first.hundredths == 0, second.hundredths == 0,
              (1 ... 99).contains(first.value), second.isTwoDigitForm || second.isOhForm, (0 ... 99).contains(second.value)
        else { return nil }
        var readings: [ValueReading] = []
        if second.value <= 59 {
            if (1 ... 12).contains(first.value) {
                readings.append(.time(first.value, second.value, nil))
            } else if (13 ... 23).contains(first.value) {
                readings.append(.time(first.value - 12, second.value, .pm))
            }
        }
        if second.value >= 10 || second.isOhForm {
            readings.append(.number((first.value * 100 + second.value) * 100))
        }
        guard !readings.isEmpty else { return nil }
        return NormalizedValue(readings: readings, tokenRange: first.start ..< second.end)
    }

    /// One group on its own. "one" and "first" to "third" alone say nothing checkable ("one of
    /// them", "the first item") and give no value unless a unit or a date follows; "two" as a
    /// count of the people talking ("the two of them") is left out the same way.
    private func singleValue(_ group: NumberGroup, tokens: [NormalizedToken]) -> NormalizedValue? {
        let range = group.start ..< group.end
        let next = word(tokens, group.end)
        let previous = word(tokens, group.start - 1)
        if group.isOrdinal {
            if group.value <= 3, group.end - group.start == 1, !isDateContext(tokens, start: group.start, end: group.end) { return nil }
            return NormalizedValue(readings: [.ordinal(group.value)], tokenRange: range)
        }
        let amount = group.value * 100 + group.hundredths
        let isLoneOne = group.value == 1 && group.hundredths == 0 && group.end - group.start == 1
        // "one" is a value only with a unit or as an hour ("from one to four").
        if isLoneOne, !hasUnitAfter(tokens, group.end), !isTimeContext(tokens, start: group.start) { return nil }
        if group.value == 2 || group.value == 3, group.hundredths == 0, group.end - group.start == 1 {
            let following = next ?? ""
            if ["of", "speakers", "people", "participants", "parties", "sides"].contains(following) { return nil }
            // "the two considered …", "the two of them": the people talking, not a fact.
            if previous == "the", next == nil || following.hasSuffix("ed") || Lexicon.stopWords.contains(following) { return nil }
        }
        return NormalizedValue(readings: [.number(amount)], tokenRange: range)
    }

    private func hasUnitAfter(_ tokens: [NormalizedToken], _ index: Int) -> Bool {
        guard index < tokens.count else { return false }
        if tokens[index].kind == .symbol { return tokens[index].text == "%" }
        guard let next = word(tokens, index) else { return false }
        let units: Set<String> = ["dollar", "dollars", "buck", "bucks", "cent", "cents", "euro", "euros", "percent", "am", "pm", "oclock"]
        return units.contains(next) || Self.durationUnits[next] != nil
    }

    private func isDateContext(_ tokens: [NormalizedToken], start: Int, end: Int) -> Bool {
        if word(tokens, end) == "of", let month = word(tokens, end + 1), Self.months[month] != nil { return true }
        for offset in 1 ... 3 {
            if let before = word(tokens, start - offset), Self.months[before] != nil || Self.weekdays[before] != nil { return true }
            if let after = word(tokens, end + offset - 1), Self.months[after] != nil { return true }
        }
        // "on the third" is a date; "on the third floor" is not.
        guard word(tokens, start - 1) == "the", word(tokens, start - 2) == "on" else { return false }
        guard let following = word(tokens, end) else { return true }
        return ["of", "at", "and", "or", "to", "through", "until", "from", "in", "by", "for"].contains(following)
    }

    /// After "at", "around", "until", "between … and", "from … to" a number can be an hour.
    private func isTimeContext(_ tokens: [NormalizedToken], start: Int) -> Bool {
        let previous = word(tokens, start - 1)
        if let previous, Self.timePrepositions.contains(previous) { return true }
        guard previous == "and" || previous == "to" || previous == "or" else { return false }
        for offset in 2 ... 5 {
            if let earlier = word(tokens, start - offset), ["between", "from", "at", "around", "until", "till", "by"].contains(earlier) {
                return true
            }
        }
        return false
    }

    // MARK: Digits

    private func digitValue(_ tokens: [NormalizedToken], at index: Int) -> ([NormalizedValue], Int)? {
        let raw = tokens[index].text
        var body = Substring(raw)
        var currency: String?
        if let first = body.first, "$€£".contains(first) {
            currency = first == "$" ? "USD" : first == "€" ? "EUR" : "GBP"
            body = body.dropFirst()
        }
        var suffix = ""
        for candidate in ["%", "st", "nd", "rd", "th", "am", "pm", "s"] where body.hasSuffix(candidate) {
            suffix = candidate
            body = body.dropLast(candidate.count)
            break
        }
        let text = String(body)
        guard !text.isEmpty, text.first?.isNumber == true else { return nil }
        if text.contains("-") { return hyphenatedValues(text, currency: currency, at: index) }
        var readings: [ValueReading] = []
        var end = index + 1

        if text.contains(":") {
            let parts = text.split(separator: ":").compactMap { Int($0) }
            guard parts.count >= 2, (0 ... 23).contains(parts[0]), (0 ... 59).contains(parts[1]) else { return nil }
            var meridiem: Meridiem? = suffix == "am" ? .am : suffix == "pm" ? .pm : nil
            if meridiem == nil, let next = word(tokens, index + 1), next == "am" || next == "pm" {
                meridiem = next == "am" ? .am : .pm
                end += 1
            }
            readings = [twelveHour(parts[0], parts[1], meridiem)]
            return ([NormalizedValue(readings: readings, tokenRange: index ..< end)], end)
        }

        var whole = 0
        var hundredths = 0
        var hasFraction = false
        if text.range(of: #"^\d{1,3}(,\d{3})+$"#, options: .regularExpression) != nil {
            whole = Int(text.replacingOccurrences(of: ",", with: "")) ?? 0
        } else {
            let pieces = text.split(separator: ",", omittingEmptySubsequences: true).first.map(String.init) ?? text
            let parts = pieces.split(separator: ".", omittingEmptySubsequences: false)
            guard let integer = Int(parts[0]) else { return nil }
            whole = integer
            if parts.count > 1, !parts[1].isEmpty {
                hasFraction = true
                let fraction = String(parts[1].prefix(2))
                hundredths = (Int(fraction) ?? 0) * (fraction.count == 1 ? 10 : 1)
            }
        }
        let amount = whole * 100 + hundredths

        if let currency {
            readings = [.money(amount, currency)]
        } else if suffix == "%" {
            readings = [.percent(amount)]
        } else if ["st", "nd", "rd", "th"].contains(suffix) {
            readings = [.ordinal(whole)]
        } else if suffix == "am" || suffix == "pm" {
            guard (1 ... 12).contains(whole) else { return nil }
            readings = [.time(whole, hasFraction ? hundredths : 0, suffix == "am" ? .am : .pm)]
        } else if hasFraction, let next = word(tokens, index + 1), next == "am" || next == "pm", (1 ... 12).contains(whole), hundredths <= 59 {
            readings = [.time(whole, hundredths, next == "am" ? .am : .pm)]
            end += 1
        } else {
            readings = [.number(amount)]
            if text.hasPrefix("0"), text.count > 1, !hasFraction { readings.append(.digits(text)) }
            // Two plain groups of three or more digits in a row are one code ("555 0142").
            if suffix.isEmpty, !hasFraction, text.count >= 3, index + 1 < tokens.count, tokens[index + 1].kind == .number {
                let next = tokens[index + 1].text
                if next.count >= 3, next.allSatisfy(\.isNumber), let second = Int(next) {
                    readings = [.digits(text + next), .number(amount), .number(second * 100)]
                    if next.hasPrefix("0") { readings.append(.digits(next)) }
                    return ([NormalizedValue(readings: readings, tokenRange: index ..< index + 2)], index + 2)
                }
            }
        }
        var value = NormalizedValue(readings: readings, tokenRange: index ..< end)
        if readings.count == 1, case .number = readings[0] {
            let (suffixed, after) = withSuffix(value, tokens: tokens, end: end)
            value = withPrefix(suffixed, tokens: tokens)
            end = max(end, after)
        } else if readings.count == 1, case .ordinal = readings[0] {
            let (suffixed, after) = withSuffix(value, tokens: tokens, end: end)
            value = suffixed
            end = max(end, after)
        }
        return ([value], end)
    }

    /// Digits joined by hyphens: a code said digit by digit ("4-7-1-9"), a room or a phone number
    /// ("1-14", "555-0142") or a range ("7-2", "9-11"). Each part is a value that also carries the
    /// joined digits, so either reading can be found in the transcript.
    private func hyphenatedValues(_ text: String, currency: String?, at index: Int) -> ([NormalizedValue], Int)? {
        let parts = text.split(separator: "-").map(String.init)
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        let joined = parts.joined()
        var shared: [ValueReading] = [.digits(joined)]
        if joined.count <= 9, let whole = Int(joined) { shared.append(.number(whole * 100)) }
        let range = index ..< index + 1
        if parts.count >= 3, parts.allSatisfy({ $0.count == 1 }) {
            return ([NormalizedValue(readings: shared, tokenRange: range)], index + 1)
        }
        var values: [NormalizedValue] = []
        for part in parts {
            guard let amount = Int(part) else { continue }
            var readings: [ValueReading] = []
            if let currency {
                readings.append(.money(amount * 100, currency))
            } else {
                readings.append(.number(amount * 100))
            }
            if part.hasPrefix("0"), part.count > 1 { readings.append(.digits(part)) }
            values.append(NormalizedValue(readings: readings + shared, tokenRange: range))
        }
        return (values, index + 1)
    }

    private func twelveHour(_ hour: Int, _ minute: Int, _ meridiem: Meridiem?) -> ValueReading {
        if hour == 0 { return .time(12, minute, .am) }
        if hour > 12 { return .time(hour - 12, minute, .pm) }
        return .time(hour, minute, meridiem)
    }

    // MARK: Context

    /// The words after a number decide its type: "dollars", "percent", "p.m.", "o'clock",
    /// "minutes", "of October".
    private func withSuffix(_ value: NormalizedValue, tokens: [NormalizedToken], end: Int) -> (NormalizedValue, Int) {
        guard !value.readings.isEmpty else { return (value, end) }
        var amount: Int?
        var ordinal: Int?
        var pairHour: Int?
        var pairMinute = 0
        for reading in value.readings {
            switch reading {
            case let .number(x):
                if amount == nil { amount = x }
            case let .ordinal(x):
                ordinal = x
            case let .time(h, m, _):
                if pairHour == nil {
                    pairHour = h
                    pairMinute = m
                }
            default:
                break
            }
        }
        var result = value
        let next: NormalizedToken? = end < tokens.count ? tokens[end] : nil
        let rawNextWord = word(tokens, end)
        let spacedMeridiem = (rawNextWord == "a" || rawNextWord == "p") && word(tokens, end + 1) == "m"
        let nextWord = spacedMeridiem ? rawNextWord.map { $0 + "m" } : rawNextWord

        // Dates: "the twelfth of October", "28 October".
        if let day = ordinal ?? amount.flatMap({ $0 % 100 == 0 ? $0 / 100 : nil }), (1 ... 31).contains(day) {
            if nextWord == "of", let monthWord = word(tokens, end + 1), let month = Self.months[monthWord] {
                result.readings = [.date(month, day)]
                result.tokenRange = value.tokenRange.lowerBound ..< end + 2
                return (result, end + 2)
            }
            if pairHour == nil, let monthWord = nextWord, let month = Self.months[monthWord], !Self.ambiguousMonths.contains(monthWord) {
                result.readings = [.date(month, day)]
                result.tokenRange = value.tokenRange.lowerBound ..< end + 1
                return (result, end + 1)
            }
        }
        guard let amount else { return (result, end) }

        if next?.kind == .symbol, next?.text == "%" {
            result.readings = [.percent(amount)]
            return (result, end + 1)
        }
        guard let nextWord else { return (result, end) }
        switch nextWord {
        case "percent":
            result.readings = [.percent(amount)]
            return (result, end + 1)
        case "per" where word(tokens, end + 1) == "cent":
            result.readings = [.percent(amount)]
            return (result, end + 2)
        case "dollar", "dollars", "buck", "bucks":
            result.readings = [.money(amount, "USD")]
            return (result, end + 1)
        case "euro", "euros":
            result.readings = [.money(amount, "EUR")]
            return (result, end + 1)
        case "quid":
            result.readings = [.money(amount, "GBP")]
            return (result, end + 1)
        case "cent", "cents":
            if amount % 100 == 0 { result.readings = [.money(amount / 100, "USD")] }
            return (result, end + 1)
        case "am", "pm":
            let meridiem: Meridiem = nextWord == "am" ? .am : .pm
            if let hour = pairHour {
                result.readings = [.time(hour, pairMinute, meridiem)]
            } else if amount % 100 == 0, (1 ... 12).contains(amount / 100) {
                result.readings = [.time(amount / 100, 0, meridiem)]
            } else {
                return (result, end)
            }
            return (result, end + (spacedMeridiem ? 2 : 1))
        case "oclock":
            if pairHour == nil, amount % 100 == 0, (1 ... 12).contains(amount / 100) {
                result.readings = [.time(amount / 100, 0, nil)]
            }
            return (result, end + 1)
        default:
            break
        }
        // "in the morning", "at night": a time with its half of the day.
        if amount % 100 == 0, (1 ... 12).contains(amount / 100) || pairHour != nil {
            var meridiem: Meridiem?
            if nextWord == "in", word(tokens, end + 1) == "the", let part = word(tokens, end + 2) {
                if part == "morning" { meridiem = .am }
                if part == "afternoon" || part == "evening" { meridiem = .pm }
            } else if nextWord == "at", word(tokens, end + 1) == "night" {
                meridiem = .pm
            } else if nextWord == "tonight" {
                meridiem = .pm
            }
            if let meridiem {
                if let hour = pairHour {
                    result.readings = [.time(hour, pairMinute, meridiem)]
                } else {
                    result.readings = [.time(amount / 100, 0, meridiem)]
                }
                return (result, end)
            }
        }
        // Durations: "two extra days", "twenty minutes", "24 hours". A duration still matches a
        // plain number of the same count ("twelve total" — "twelve minutes"), never another unit.
        var unitIndex = end
        if Self.durationModifiers.contains(nextWord) { unitIndex += 1 }
        if let unitWord = word(tokens, unitIndex), let seconds = Self.durationUnits[unitWord], pairHour == nil {
            result.readings = [.duration(amount * seconds / 100, amount)]
        }
        return (result, end)
    }

    /// The words before a number: after "at", "around", "until", "between … and" a number from
    /// 1 to 12 can be a time of day; after "$" it is money.
    private func withPrefix(_ value: NormalizedValue, tokens: [NormalizedToken]) -> NormalizedValue {
        var result = value
        let start = value.tokenRange.lowerBound
        guard result.readings.count >= 1, case let .number(amount) = result.readings[0] else { return result }
        if start > 0, tokens[start - 1].kind == .symbol {
            switch tokens[start - 1].text {
            case "$": result.readings = [.money(amount, "USD")]
            case "€": result.readings = [.money(amount, "EUR")]
            case "£": result.readings = [.money(amount, "GBP")]
            default: break
            }
            return result
        }
        guard amount % 100 == 0, (1 ... 12).contains(amount / 100), !result.readings.contains(where: { $0.kind == .time }) else { return result }
        if isTimeContext(tokens, start: start) { result.readings.append(.time(amount / 100, 0, nil)) }
        return result
    }

    /// Hedges and certainty words next to a value.
    private func annotated(_ value: NormalizedValue, in tokens: [NormalizedToken]) -> NormalizedValue {
        var result = value
        let start = value.tokenRange.lowerBound, end = value.tokenRange.upperBound
        for offset in 1 ... 3 {
            guard let before = word(tokens, start - offset) else { continue }
            if Self.hedgeBefore.contains(before) { result.isHedged = true }
            if before == "close", word(tokens, start - offset + 1) == "to" { result.isHedged = true }
            if Self.certainWords.contains(before) { result.isCertain = true }
        }
        for offset in 0 ..< 3 {
            guard let after = word(tokens, end + offset) else { continue }
            if Self.hedgeAfter.contains(after) { result.isHedged = true }
            if after == "or", let next = word(tokens, end + offset + 1), next == "so" || next == "later" || next == "two" || next == "so" {
                result.isHedged = true
            }
            if Self.certainWords.contains(after) { result.isCertain = true }
            if after == "on", word(tokens, end + offset + 1) == "the", word(tokens, end + offset + 2) == "dot" { result.isCertain = true }
        }
        return result
    }
}
