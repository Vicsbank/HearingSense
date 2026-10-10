import Foundation
import HearingSenseDomain

/// Merges the partial (volatile) and final results of one utterance into a single transcript.
///
/// The recognizer reports: volatile results that replace each other while speech continues, and
/// final results that will not change. Finals arrive once per natural sentence, so a long
/// utterance has several. Rules:
/// - a final result is appended unless it repeats audio that is already final (same time range
///   or identical text right after the previous final) — counted as a duplicate;
/// - a volatile result replaces the previous volatile text and is dropped when a final arrives.
///
/// Pure value type with no clock: deterministic for any sequence of updates.
public struct TranscriptAssembler: Sendable {
    public struct Segment: Hashable, Sendable {
        public var text: String
        public var audioTime: AudioTimeRange
        public var meanConfidence: Double?
        public var minimumConfidence: Double?
    }

    public private(set) var segments: [Segment] = []
    public private(set) var volatileText = ""
    public private(set) var volatileRange: AudioTimeRange?
    public private(set) var duplicatesDropped = 0

    public init() {}

    /// Returns true if the visible text changed.
    @discardableResult
    public mutating func apply(_ update: TranscriptionUpdate) -> Bool {
        let before = text
        let cleaned = TranscriptText.clean(update.text)
        if update.isFinal {
            volatileText = ""
            volatileRange = nil
            guard TranscriptText.isMeaningful(cleaned) else { return text != before }
            if isDuplicate(cleaned, range: update.audioTime) {
                duplicatesDropped += 1
            } else {
                segments.append(Segment(text: cleaned, audioTime: update.audioTime,
                                        meanConfidence: update.meanConfidence,
                                        minimumConfidence: update.minimumConfidence))
            }
        } else {
            volatileText = TranscriptText.isMeaningful(cleaned) ? cleaned : ""
            volatileRange = volatileText.isEmpty ? nil : update.audioTime
        }
        return text != before
    }

    /// Final text followed by the current volatile text.
    public var text: String {
        (segments.map(\.text) + (volatileText.isEmpty ? [] : [volatileText])).joined(separator: " ")
    }

    public var finalText: String { segments.map(\.text).joined(separator: " ") }
    public var hasFinalText: Bool { !segments.isEmpty }
    public var isEmpty: Bool { segments.isEmpty && volatileText.isEmpty }

    /// Span from the first to the last recognized audio (finals and volatile).
    public var audioTime: AudioTimeRange? {
        let ranges = segments.map(\.audioTime) + (volatileRange.map { [$0] } ?? [])
        guard let start = ranges.map(\.start).min(), let end = ranges.map(\.end).max() else { return nil }
        return AudioTimeRange(start: start, end: end)
    }

    /// Recognition quality over the final segments, weighted by word count.
    public var quality: TranscriptQuality {
        let words = TranscriptText.words(in: finalText).count
        var weighted = 0.0
        var weight = 0.0
        var minimum: Double?
        for segment in segments {
            guard let mean = segment.meanConfidence else { continue }
            let count = Double(max(TranscriptText.words(in: segment.text).count, 1))
            weighted += mean * count
            weight += count
            if let low = segment.minimumConfidence { minimum = min(minimum ?? low, low) }
        }
        return TranscriptQuality.assess(meanConfidence: weight > 0 ? weighted / weight : nil,
                                        minimumConfidence: minimum, wordCount: words)
    }

    /// Treats the current volatile text as final (used when the recognizer did not finalize in
    /// time). The promoted segment has no confidence, so its quality is `unknown`.
    public mutating func promoteVolatile() {
        guard !volatileText.isEmpty, let range = volatileRange else { return }
        segments.append(Segment(text: volatileText, audioTime: range, meanConfidence: nil, minimumConfidence: nil))
        volatileText = ""
        volatileRange = nil
    }

    private func isDuplicate(_ text: String, range: AudioTimeRange) -> Bool {
        let normalized = TranscriptText.normalized(text)
        return segments.contains { segment in
            let overlap = min(segment.audioTime.end, range.end) - max(segment.audioTime.start, range.start)
            let shorter = min(segment.audioTime.duration, range.duration)
            let sameAudio = shorter > 0 && overlap / shorter > 0.5
            let sameText = TranscriptText.normalized(segment.text) == normalized
            let adjacent = abs(range.start - segment.audioTime.end) < 2 || overlap > 0
            return sameAudio || (sameText && adjacent)
        }
    }
}

/// Text helpers shared by transcript handling and summary validation.
public enum TranscriptText {
    /// Trims whitespace and leading punctuation the recognizer sometimes emits ("... He has").
    public static func clean(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = result.unicodeScalars.first,
              CharacterSet.punctuationCharacters.contains(first) || CharacterSet.whitespaces.contains(first)
        {
            result.unicodeScalars.removeFirst()
        }
        return result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// True if the text contains at least one word (letters or digits), i.e. is not just
    /// punctuation such as ",......".
    public static func isMeaningful(_ text: String) -> Bool {
        !words(in: text).isEmpty
    }

    /// Lowercased words without surrounding punctuation; inner apostrophes are kept ("don't").
    public static func words(in text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .split { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == ":") }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "':")) }
            .filter { !$0.isEmpty }
    }

    /// Case-, punctuation- and spacing-insensitive form for comparing transcripts.
    public static func normalized(_ text: String) -> String {
        words(in: text).joined(separator: " ")
    }
}
