import Foundation

/// Word lists and the stemmer shared by the postprocessing components. English only.
///
/// Everything here is a fixed table: no model, no system tagger, so that a verdict is the same
/// on every device and in every run.
public enum Lexicon {
    /// A light, deterministic stemmer: "leaves", "leaving" and "leave" give "leav"; "copies" and
    /// "copy" give "copy"; "stopped" gives "stop". Irregular forms map to their base first. It is
    /// only used to compare words with each other, never to write text.
    public static func stem(_ raw: String) -> String {
        var word = raw.lowercased()
        if word.hasSuffix("'s") {
            word.removeLast(2)
        } else if word.hasSuffix("s'") {
            word.removeLast()
        }
        word = word.replacingOccurrences(of: "'", with: "")
        if let base = irregularForms[word] { return regularStem(base) }
        return regularStem(word)
    }

    /// The stem, with a few common paraphrases mapped onto one word ("depart" → "leav",
    /// "purchase" → "buy"). Used for coverage and duplicate tests.
    public static func canonicalStem(_ raw: String) -> String {
        let base = stem(raw)
        return synonyms[base] ?? base
    }

    private static func regularStem(_ word: String) -> String {
        guard word.count > 3, word.allSatisfy({ $0.isLetter }) else { return word }
        var stem = word
        if stem.hasSuffix("ies"), stem.count > 4 {
            stem = String(stem.dropLast(3)) + "y"
        } else if stem.hasSuffix("ied"), stem.count > 4 {
            stem = String(stem.dropLast(3)) + "y"
        } else if stem.hasSuffix("sses") {
            stem.removeLast(2)
        } else if stem.hasSuffix("ing"), stem.count >= 6 {
            stem.removeLast(3)
            stem = undoubled(stem)
        } else if stem.hasSuffix("ed"), stem.count >= 5 {
            stem.removeLast(2)
            stem = undoubled(stem)
        } else if stem.hasSuffix("s"), !stem.hasSuffix("ss"), !stem.hasSuffix("us"), !stem.hasSuffix("is") {
            stem.removeLast()
        }
        if stem.count > 3, stem.hasSuffix("e") { stem.removeLast() }
        return stem
    }

    /// "stopp" → "stop", "plann" → "plan"; "call" and "pass" stay.
    private static func undoubled(_ stem: String) -> String {
        let characters = Array(stem)
        guard characters.count >= 3, let last = characters.last, characters[characters.count - 2] == last,
              !"aeioulsz".contains(last)
        else { return stem }
        return String(characters.dropLast())
    }

    private static let irregularForms: [String: String] = [
        "went": "go", "gone": "go", "came": "come", "left": "leave", "ran": "run", "took": "take", "taken": "take",
        "bought": "buy", "brought": "bring", "told": "tell", "said": "say", "made": "make", "met": "meet", "sent": "send",
        "kept": "keep", "paid": "pay", "got": "get", "gotten": "get", "gave": "give", "given": "give", "found": "find",
        "thought": "think", "felt": "feel", "held": "hold", "children": "child", "men": "man", "women": "woman",
        "wrote": "write", "written": "write", "chose": "choose", "chosen": "choose", "began": "begin", "begun": "begin",
        "broke": "break", "broken": "break", "fell": "fall", "spent": "spend", "built": "build", "lost": "lose",
        "won": "win", "sold": "sell", "saw": "see", "seen": "see", "ate": "eat", "eaten": "eat", "drove": "drive",
        "driven": "drive", "rode": "ride", "flew": "fly", "flown": "fly", "stood": "stand", "understood": "understand",
        "forgot": "forget", "forgotten": "forget", "did": "do", "done": "finish", "hated": "hate", "hates": "hate",
        "approval": "approve", "failure": "fail", "failures": "fail", "requirement": "require",
        "requirements": "require", "payment": "pay", "payments": "pay", "availability": "available",
        "decision": "decide", "decisions": "decide", "preference": "prefer", "preferences": "prefer",
        "arrival": "arrive", "delivery": "deliver", "cancellation": "cancel", "cancellations": "cancel",
        "cancelled": "cancel", "canceled": "cancel", "cancelling": "cancel", "canceling": "cancel",
        "confirmation": "confirm", "registration": "register", "reservation": "reserve", "reservations": "reserve",
        "departure": "depart", "submission": "submit", "submissions": "submit", "repairs": "repair",
        "mice": "mouse", "feet": "foot", "teeth": "tooth", "people": "person",
    ]

    /// Stems that mean the same thing for the purpose of finding evidence. Kept small: a pair is
    /// listed only when a recap commonly uses one word for the other one said aloud.
    private static let synonyms: [String: String] = [
        "depart": "leav", "back": "return", "begin": "start", "commenc": "start",
        "complet": "finish", "purchas": "buy", "assist": "help",
        "requir": "need", "necessary": "need", "reschedul": "mov", "postpon": "mov",
        "arriv": "come", "submit": "hand", "turn": "hand", "repair": "fix", "deadlin": "due",
        "fee": "cost", "pric": "cost", "charg": "cost", "pay": "cost", "exam": "test", "quiz": "test",
        "mother": "mom", "mum": "mom", "father": "dad", "child": "kid", "dislik": "hat",
        "favorit": "prefer", "favourit": "prefer", "delay": "late", "larg": "big",
        "littl": "small", "tiny": "small", "phon": "call", "automobil": "car", "vehicl": "car",
        "physician": "doctor", "dr": "doctor",
    ]

    /// Words that carry no claim of their own: function words, pronouns, speech fillers,
    /// reporting verbs and words about the conversation itself.
    public static let stopWords: Set<String> = [
        "a", "an", "the", "is", "are", "was", "were", "be", "been", "being", "am", "has", "have", "had", "having",
        "will", "would", "shall", "do", "does", "doing", "to", "of", "in", "on", "at", "for", "and", "or", "but",
        "it", "its", "it's", "this", "that", "these", "those", "there", "here", "i", "you", "he", "she", "we", "they",
        "me", "him", "her", "us", "them", "my", "your", "our", "their", "his", "hers", "ours", "theirs", "mine",
        "yours", "myself", "yourself", "himself", "herself", "ourselves", "themselves", "so", "as", "by", "with",
        "from", "about", "if", "then", "than", "can", "could", "should", "may", "might", "must", "what", "who",
        "whom", "whose", "when", "where", "why", "how", "which", "also", "because", "into", "over", "up", "out",
        "off", "just", "really", "very", "too", "even", "still", "already", "yet", "now", "again", "there's",
        "that's", "what's", "here's", "let's", "i'm", "i'll", "i'd", "i've", "you're", "you'll", "you'd", "you've",
        "he's", "she's", "he'd", "she'd", "he'll", "she'll", "we're", "we'll", "we'd", "we've", "they're", "they'll",
        "they'd", "they've", "it'll", "um", "uh", "oh", "okay", "ok", "yeah", "yes", "yep", "hmm", "ah", "well",
        "like", "right", "alright", "sure", "hey", "hi", "hello", "please", "gonna", "wanna", "gotta", "get", "gets",
        "getting", "go", "goes", "going", "not", "no", "never", "without", "none", "nobody", "nothing", "neither",
        "nor", "one", "someone", "somebody", "speaker", "speakers", "person", "conversation", "said", "says",
        "say", "saying", "mentioned", "mentions", "mention", "noted", "notes", "note", "added", "adds", "explained",
        "explains", "stated", "states", "told", "tells", "tell", "asked", "asks", "ask", "talked", "talk", "discussed",
        "discuss", "another", "other", "others", "some", "any", "each", "every", "all", "both", "either", "own",
        "such", "only", "same", "more", "most", "much", "many", "few", "lot", "lots", "thing", "things", "stuff",
        "way", "kind", "sort", "bit", "actually", "basically", "probably", "maybe", "perhaps", "around", "approximately",
        "roughly", "anyway", "though", "although", "while", "whether", "until", "till", "til", "since", "during",
        "through", "via", "per", "within", "between", "among", "against", "across", "along", "upon", "onto", "toward",
        "towards", "under", "above", "below", "near", "next", "last", "this", "being", "did", "didn't", "don't",
        "aren't", "isn't", "wasn't", "weren't", "doesn't", "haven't", "hasn't", "hadn't", "won't", "wouldn't",
        "can't", "couldn't", "shouldn't", "cannot", "after", "before", "then", "than", "who's", "where's", "how's",
        "o'clock", "oclock", "something", "anything", "everything", "anyone", "everyone", "everybody", "anybody",
    ]

    /// Words of a statement that say nothing about what was said: a statement made only of these
    /// (and stop words), with no number and no name, is filler ("A few announcements were made").
    /// Only used for that test; for grounding, these words stay content.
    public static let fillerVocabulary: Set<String> = [
        "conversation", "discuss", "discussion", "talk", "topic", "several", "various", "different", "thing",
        "matter", "item", "announcement", "announc", "mak", "make", "cover", "occur", "plac", "place", "happen",
        "start", "begin", "end", "conclud", "agre", "agr", "agreement", "finaliz", "detail", "plan", "information", "info",
        "point", "mention", "meet", "session", "chat", "exchang", "few", "some", "many", "multipl", "number", "overall",
        "general", "generally", "brief", "briefly", "includ", "relat", "regard", "regarding", "concern", "issu",
        "take", "took", "tak", "do", "doing", "done", "finish", "speaker", "people", "person", "everyone", "everybody",
        "group", "thank", "thanks", "wrap", "conversation", "recap", "summary", "summar", "say", "said", "ask",
        "noted", "not", "explain", "state", "talked", "discussed", "covered", "touched", "touch", "address",
        "addressed", "follow", "followed", "proceed", "proceeded", "continu", "went", "go", "come",
    ]

    /// Words that deny what follows them. Contractions are split before ("can't" → "can not").
    public static let negators: Set<String> = ["not", "no", "never", "without", "none", "nobody", "nothing", "neither", "nor"]

    /// Stems whose meaning includes a "not": a statement with one of them is negative even
    /// without a "not" ("The copy awaits approval" for "the copy is still not approved").
    public static let negativeImplyingStems: Set<String> = [
        "await", "pend", "pending", "lack", "miss", "unabl", "fail", "refus", "declin", "absent", "unavailabl",
        "cancel", "instead", "rather", "reject", "avoid", "except", "outstand", "unclear", "unknown", "uncertain",
        "unsur", "forbid", "prohibit", "ban", "skip", "unlikely", "impossible", "clos", "independent", "independently",
        "unapprov", "unconfirm", "unpaid", "unsign", "longer", "free", "unless", "hat", "dislik", "little", "littl",
        "barely", "hardly", "rarely", "seldom", "scarcely", "against", "eliminat", "off", "spare",
    ]

    /// Whether a word carries a "not" of its own: one of `negativeImplyingStems`, or a word with a
    /// negative prefix ("unsuitable", "unavailable", "nonrefundable"; not "under", "unit", "until").
    public static func isNegativeImplying(_ word: String) -> Bool {
        let lowered = word.lowercased()
        if negativeImplyingStems.contains(lowered) || negativeImplyingStems.contains(stem(lowered)) { return true }
        if lowered.hasPrefix("un"), lowered.count >= 6, let next = lowered.dropFirst(2).first, !"dit".contains(next) { return true }
        if lowered.hasPrefix("non"), lowered.count >= 7 { return true }
        return false
    }

    /// Words after which a "not" says that the speaker does not know, not that something is false
    /// ("I'm not sure someone said …", "I don't know, traffic maybe"): a hedge, not a denial.
    public static let epistemicWords: Set<String> = ["know", "sure", "certain", "idea", "remember", "recall", "clear"]

    /// A "no" to a question with one of these says what the listener heard or knows, not that the
    /// thing asked about is false ("did you hear about the elevator?" — "no").
    public static let perceptionVerbs: Set<String> = [
        "hear", "heard", "know", "knew", "see", "saw", "seen", "watch", "watched", "notice", "noticed", "remember",
        "think", "mind", "guess", "recall", "read", "catch", "caught", "check", "checked",
    ]

    /// Capitalized abbreviations that are no names.
    public static let knownAbbreviations: Set<String> = [
        "tbd", "tba", "asap", "fyi", "ok", "eta", "rsvp", "aka", "diy", "faq", "pdf", "tv", "id", "am", "pm", "usa", "uk",
        "eu", "ceo", "hr", "ai", "vip", "etc", "vs", "mph", "kg", "km", "cm", "mm", "ml", "lb", "lbs", "oz", "ft", "sq",
        "gps", "atm", "dj", "pe", "pta", "ac", "it", "qa", "ui", "ux", "pr", "kpi", "rsvp",
    ]

    /// Spoken names of letters, inside letters said one by one ("the k p eye review").
    public static let letterNames: [String: String] = [
        "eye": "i", "bee": "b", "see": "c", "sea": "c", "dee": "d", "gee": "g", "jay": "j", "kay": "k", "pea": "p",
        "pee": "p", "cue": "q", "queue": "q", "are": "r", "tea": "t", "tee": "t", "you": "u", "vee": "v", "why": "y",
        "zee": "z", "zed": "z", "ex": "x", "em": "m", "en": "n", "es": "s", "el": "l", "ef": "f", "oh": "o", "aitch": "h",
    ]

    /// A rough sound key (Soundex-like, first letter included, vowels dropped): "Krebs" and
    /// "crabs" both give "2612". Only used to keep, as uncertain, a name the recognizer misspelt.
    public static func phoneticKey(_ word: String) -> String {
        var key = ""
        var last: Character?
        for character in word.lowercased() {
            guard let code = soundCodes[character] else {
                last = nil
                continue
            }
            if code != last { key.append(code) }
            last = code
        }
        return key
    }

    private static let soundCodes: [Character: Character] = [
        "b": "1", "f": "1", "p": "1", "v": "1", "c": "2", "g": "2", "j": "2", "k": "2", "q": "2", "s": "2", "x": "2",
        "z": "2", "d": "3", "t": "3", "l": "4", "m": "5", "n": "5", "r": "6",
    ]

    /// Words in speech that make a value or a statement less than certain.
    public static let hedgeWords: Set<String> = [
        "around", "about", "roughly", "approximately", "approx", "maybe", "probably", "possibly", "perhaps", "likely",
        "nearly", "almost", "ish", "estimated", "expected", "expect", "tentatively", "tentative", "might", "may",
        "could", "think", "guess", "sometime", "somewhere", "unsure", "possible", "if", "hopefully", "suppose",
        "supposedly", "should",
    ]

    /// Hedges in the transcript that make a whole utterance uncertain (not only one value).
    public static let modalHedgeWords: Set<String> = [
        "maybe", "probably", "possibly", "perhaps", "might", "could", "think", "guess", "unsure", "hopefully", "if", "unless",
    ]

    /// Words that state a value as exact. Turning a hedged value into one of these is a change of meaning.
    public static let strongCertaintyWords: Set<String> = ["exactly", "precisely", "definitely", "certainly", "guaranteed", "sharp", "promptly"]

    /// Words that state an outcome as settled; next to a hedged utterance the statement is uncertain.
    public static let settledWords: Set<String> = [
        "agreed", "decided", "settled", "confirmed", "chose", "chosen", "selected", "finalized", "finalised", "committed",
    ]

    /// Words that frame a value as an earlier, changed one ("originally on Thursday").
    public static let changeFramingWords: Set<String> = [
        "moved", "move", "moving", "changed", "change", "changing", "rescheduled", "reschedule", "postponed",
        "postpone", "pushed", "push", "shifted", "shift", "switched", "switch", "originally", "original", "initially",
        "initial", "previously", "previous", "earlier", "formerly", "instead", "replaced", "replace", "corrected",
        "correction", "correcting", "updated", "update", "thought", "assumed", "assumption", "believed", "belief",
        "rather", "longer", "was", "were", "had",
    ]

    /// Verbs that attribute words to a speaker ("Maya said").
    public static let speechVerbs: Set<String> = [
        "said", "says", "say", "told", "tells", "asked", "asks", "mentioned", "mentions", "explained", "explains",
        "announced", "announces", "reported", "reports", "stated", "states", "noted", "notes", "added", "adds",
        "promised", "promises", "agreed", "agrees", "suggested", "suggests", "proposed", "proposes", "offered",
        "offers", "confirmed", "confirms", "claimed", "claims", "insisted", "insists", "complained", "complains",
        "warned", "warns", "replied", "replies", "answered", "answers", "admitted", "argued", "emphasized",
        "reminded", "reminds", "clarified", "clarifies", "requested", "requests", "recommended", "recommends",
        "advised", "advises",
    ]

    /// Subject pronouns: a negation does not reach past one ("she can't she works Thursdays").
    public static let subjectPronouns: Set<String> = ["i", "you", "he", "she", "we", "they", "it", "there", "that", "this"]

    /// Words that end the reach of a negation.
    public static let scopeBreakers: Set<String> = ["and", "but", "or", "so", "because", "if", "then", "though", "although", "while", "when", "since"]

    /// Words next to which a thing is affirmed as required or exclusive ("paper copies only").
    public static let affirmationMarkers: Set<String> = ["only", "must", "need", "needs", "required", "require", "requires", "always"]

    /// Words that open a yes/no question in speech.
    public static let questionOpeners: Set<String> = [
        "is", "are", "was", "were", "can", "could", "do", "does", "did", "will", "would", "should", "shall", "may",
        "might", "have", "has", "had", "isn't", "aren't", "don't", "doesn't", "didn't", "won't", "can't", "couldn't",
    ]

    /// Words said before the real start of an utterance.
    public static let leadingFillers: Set<String> = ["um", "uh", "so", "and", "but", "oh", "okay", "ok", "well", "hey", "wait", "hmm", "like", "also", "then", "alright", "right", "ah"]

    public static let denialAnswers: Set<String> = ["no", "nope", "nah"]
    public static let affirmativeAnswers: Set<String> = ["yes", "yeah", "yep", "sure", "absolutely", "definitely", "correct", "exactly", "certainly"]

    /// Courtesy titles; the word after one is a name.
    public static let titles: Set<String> = ["mr", "mrs", "ms", "miss", "dr", "prof", "professor", "sir", "madam", "st", "mt", "jr", "sr"]

    /// Words that make a statement about the recording or the recap itself.
    public static let metaWords: Set<String> = [
        "transcript", "transcription", "transcribed", "recognizer", "recognition", "recording", "recorded", "recap",
        "inaudible", "garbled", "unintelligible",
    ]

    /// Words that make a statement a claim that something was not said.
    public static let absenceWords: Set<String> = ["missing", "unclear", "unspecified", "unknown", "unmentioned", "unstated", "undetermined", "undecided"]

    /// Participles that, after a "not", turn a statement into a claim of absence ("was not mentioned").
    public static let absenceParticiples: Set<String> = [
        "mentioned", "specified", "given", "stated", "provided", "discussed", "said", "clear", "known", "decided",
        "confirmed", "determined", "explained", "addressed", "covered", "shared", "included", "set",
    ]

    /// Words that report a question rather than assert its content ("asked whether").
    public static let questionReportingWords: Set<String> = ["asked", "asks", "ask", "whether", "wondered", "wonder", "question", "questions", "inquired", "inquire", "if"]
}
