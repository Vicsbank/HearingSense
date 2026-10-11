import Foundation

/// Decides when a growing partial transcript is worth evaluating ahead of its final form
/// (Window 6.1).
///
/// The speech recognizer revises an utterance many times while it is spoken and delivers the
/// final text some time after the last word. Evaluating every revision would send the same
/// sentence to the language model again and again; waiting for the final text wastes the pause
/// between the last word and the recognizer's confirmation. This value type, driven by the
/// times of the revisions (no clock of its own), names at most a few moments per utterance:
///
/// - the text has not changed for `quietInterval` (the speaker has probably stopped), or
/// - the text ends a sentence (final punctuation) and has stayed so for `sentenceInterval`,
///
/// and only if the text differs from what was offered before by more than a word of growth
/// at the end being revised (a content fingerprint, not the raw string). What it offers is a
/// candidate for `SemanticAttentionEngine.submitProvisional`: its evaluation is used only if
/// the final transcript has the same words, and it is never shown or stored as something said.
public struct StablePartialDetector: Hashable, Sendable {
    public struct Policy: Hashable, Sendable {
        /// Unchanged for this long: probably the end of the utterance.
        public var quietInterval: TimeInterval = 0.4
        /// A complete sentence needs to stay unchanged only this long.
        public var sentenceInterval: TimeInterval = 0.15
        /// Fewer words than this are not worth an early evaluation.
        public var minimumWords = 2
        /// Early evaluations per utterance, at most.
        public var maximumOffers = 2

        public init() {}

        public static let standard = Policy()
    }

    public let policy: Policy
    private var utteranceID: UUID?
    private var fingerprint = ""
    private var text = ""
    private var changedAt: Date?
    private var offered: Set<String> = []

    public init(policy: Policy = .standard) {
        self.policy = policy
    }

    /// The words that carry the content: case, punctuation and spacing do not count.
    public static func fingerprint(of text: String) -> String {
        SemanticText.words(in: text).joined(separator: " ")
    }

    /// A new revision of the partial transcript of one utterance.
    public mutating func revise(_ text: String, utterance: UUID, at date: Date) {
        if utterance != utteranceID {
            utteranceID = utterance
            offered.removeAll()
            fingerprint = ""
        }
        let revised = Self.fingerprint(of: text)
        self.text = text
        guard revised != fingerprint else { return }
        fingerprint = revised
        changedAt = date
    }

    /// The utterance was finalized or abandoned: nothing more is offered for it.
    public mutating func finish() {
        utteranceID = nil
        fingerprint = ""
        text = ""
        changedAt = nil
        offered.removeAll()
    }

    /// When `offer(at:)` should be asked next, if the text does not change before.
    public var nextCheck: Date? {
        guard let changedAt, !fingerprint.isEmpty, !offered.contains(fingerprint), offered.count < policy.maximumOffers else {
            return nil
        }
        return changedAt.addingTimeInterval(endsSentence ? policy.sentenceInterval : policy.quietInterval)
    }

    /// The text to evaluate early, once per stable form.
    public mutating func offer(at date: Date) -> String? {
        guard let due = nextCheck, date >= due else { return nil }
        guard fingerprint.split(separator: " ").count >= policy.minimumWords else { return nil }
        offered.insert(fingerprint)
        return text
    }

    private var endsSentence: Bool {
        guard let last = text.trimmingCharacters(in: .whitespaces).last else { return false }
        return last == "." || last == "!" || last == "?"
    }
}
