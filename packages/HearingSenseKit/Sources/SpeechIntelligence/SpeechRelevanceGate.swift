import Foundation
import HearingSenseDomain

/// Stage B of the speech relevance gate: thresholds for judging a transcribed utterance from
/// the classifier windows that overlap it.
///
/// Chosen on a design set of GTZAN songs and LibriSpeech utterances mixed over music, checked on
/// disjoint clips (docs/testing/WINDOW3_TEST_RESULTS.md). The strongest single cue is temporal
/// consistency: while someone talks, most windows have a strong speech score; while someone
/// sings, strong speech scores are sporadic.
public struct SpeechRelevancePolicy: Hashable, Sendable {
    /// A window with a music score at or above this value has music in it.
    public var musicPresentScore = 0.50
    /// An utterance is "in a music context" when at least this share of its windows has music.
    public var musicContextShare = 0.34
    public var strongSpeechScore = 0.90
    public var clearSpeechScore = 0.80
    /// In a music context the utterance counts as speech when this share of its windows has a
    /// strong speech score and the recognizer's mean confidence reaches `minimumConfidence` …
    public var minimumStrongShare = 0.34
    public var minimumConfidence = 0.50
    /// … or when this share has a clear speech score and the recognizer was very confident.
    public var minimumClearShare = 0.50
    public var minimumConfidenceForClearShare = 0.80
    /// A window with a vocal-music score at or above this value counts as "vocals present".
    public var vocalPresentScore = 0.10
    /// A window is attributed to an utterance when they overlap by this much (or by half the
    /// utterance, if that is shorter).
    public var minimumOverlap: TimeInterval = 0.5
    /// Classifier windows remembered for assessing utterances.
    public var historySeconds: TimeInterval = 120

    public init() {}

    public static let standard = SpeechRelevancePolicy()
}

/// Judges whether a transcribed utterance was probably spoken (possibly over music) or is
/// probably part of the music, from the sound classifier's view of the same audio.
///
/// It cannot know the truth: it does not separate voices, and a rapper and a talking person
/// produce the same kind of evidence. Speech at about the same level as loud vocal music is
/// often labelled `possiblyMusic`, and a small share of lyrics passes as speech. The result is
/// therefore reported as an estimate (`SpeechRelevance`), and uncertain utterances keep their
/// transcript but are not interpreted.
///
/// Deterministic value type: uses only the frames' audio clock.
public struct SpeechRelevanceGate: Sendable {
    private struct Window {
        var range: AudioTimeRange
        var evidence: SpeechEvidence
    }

    public let policy: SpeechRelevancePolicy
    private var windows: [Window] = []

    public init(policy: SpeechRelevancePolicy = .standard) {
        self.policy = policy
    }

    /// Remembers one classifier window and what the activity tracker made of it.
    public mutating func record(_ frame: ClassificationFrame, evidence: SpeechEvidence) {
        windows.append(Window(range: frame.audioTime, evidence: evidence))
        let horizon = frame.audioTime.end - policy.historySeconds
        if let first = windows.first, first.range.end < horizon {
            windows.removeAll { $0.range.end < horizon }
        }
    }

    public mutating func reset() {
        windows.removeAll()
    }

    /// Acoustic context of the audio in `range`. Nil when no classifier window is available for
    /// it (nothing can be said).
    /// - Parameter meanConfidence: the recognizer's confidence for the utterance, if reported.
    public func assess(_ range: AudioTimeRange, meanConfidence: Double?) -> SpeechAcousticContext? {
        func overlap(_ window: Window) -> TimeInterval {
            min(window.range.end, range.end) - max(window.range.start, range.start)
        }
        let needed = min(policy.minimumOverlap, range.duration / 2)
        var selected = windows.filter { overlap($0) >= needed && overlap($0) > 0 }
        if selected.isEmpty, let nearest = windows.max(by: { overlap($0) < overlap($1) }), overlap(nearest) > -1.5 {
            selected = [nearest]
        }
        guard !selected.isEmpty else { return nil }

        let count = Double(selected.count)
        func share(_ predicate: (SpeechEvidence) -> Bool) -> Double {
            Double(selected.count { predicate($0.evidence) }) / count
        }
        let musicShare = share { $0.musicScore >= policy.musicPresentScore }
        let strongShare = share { $0.speechScore >= policy.strongSpeechScore }
        let clearShare = share { $0.speechScore >= policy.clearSpeechScore }
        let vocalShare = share { $0.vocalScore >= policy.vocalPresentScore }

        let relevance: SpeechRelevance
        if musicShare < policy.musicContextShare {
            relevance = .nearbySpeech
        } else {
            // Without a confidence (the recognizer did not finalize) only the acoustic cue counts.
            let confidence = meanConfidence ?? 1
            let sustained = strongShare >= policy.minimumStrongShare && confidence >= policy.minimumConfidence
            let clear = meanConfidence != nil && clearShare >= policy.minimumClearShare
                && confidence >= policy.minimumConfidenceForClearShare
            relevance = sustained || clear ? .speechOverMusic : .possiblyMusic
        }
        return SpeechAcousticContext(relevance: relevance, windows: selected.count, musicShare: musicShare,
                                     strongSpeechShare: strongShare, vocalMusicShare: vocalShare)
    }
}
