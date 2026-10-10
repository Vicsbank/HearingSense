import Foundation
import HearingSenseDomain
import SoundEventDetection

/// When classifier windows count as "someone may be speaking nearby".
///
/// Transcription is activated by **speech candidates**, not by confirmed events: the sound
/// detector confirms speech after two windows ≥ 0.5 (≈ 2.25 s of audio), while a single window
/// at `candidateScore` is available ≈ 0.75 s earlier and also catches utterances too short to
/// ever be confirmed. A false activation costs a short transcription that produces no text; a
/// missed one loses the sentence.
public struct SpeechActivationPolicy: Hashable, Sendable {
    /// Event kinds whose labels count as speech (`SoundTaxonomy` kind ids).
    public var speechKindIDs: Set<String> = ["speech", "shouting"]
    public var musicKindID = "music"
    /// Minimum speech score of one window to activate or sustain speech activity.
    public var candidateScore = 0.30
    /// A window with a music score at or above this value is "music present".
    public var musicPresentScore = 0.50
    /// While music is present the speech score must reach this value. Sung vocals (labels
    /// `singing`, `rapping`, … belong to the music kind) often carry a weak `speech` score;
    /// genuine speech over music is usually scored higher.
    public var speechScoreOverMusic = 0.50
    /// Speech activity ends after this much audio without a qualifying window.
    public var releaseAfter: TimeInterval = 2.25
    /// Audio before the first qualifying window that is also transcribed: the previous window
    /// may already contain the first word without reaching the threshold.
    public var leadIn: TimeInterval = 0.75

    public init() {}

    public static let standard = SpeechActivationPolicy()
}

/// The speech-related content of one classifier window.
public struct SpeechEvidence: Hashable, Sendable {
    public var speechScore: Double
    public var musicScore: Double
    /// The window qualifies as speech under the activation policy.
    public var isSpeech: Bool
    /// The window had a speech score ≥ `candidateScore` but was not accepted because music was
    /// present and the speech score stayed below `speechScoreOverMusic`.
    public var suppressedByMusic: Bool

    public static let none = SpeechEvidence(speechScore: 0, musicScore: 0, isSpeech: false, suppressedByMusic: false)
}

/// Turns classifier windows into speech activity (began / ended). Deterministic: uses only the
/// frames' audio clock.
public struct SpeechActivityTracker: Sendable {
    public enum Transition: Hashable, Sendable {
        /// Speech activity began; `onset` is the audio clock start of the first qualifying window.
        case began(onset: TimeInterval)
        case ended(at: TimeInterval)
    }

    public let policy: SpeechActivationPolicy
    private let speechLabels: Set<SoundLabel>
    private let musicLabels: Set<SoundLabel>

    public private(set) var isActive = false
    public private(set) var lastEvidence = SpeechEvidence.none
    /// Audio clock end of the latest qualifying window.
    public private(set) var lastSpeechTime: TimeInterval = 0
    public private(set) var windowsSuppressedByMusic = 0

    public init(policy: SpeechActivationPolicy = .standard, taxonomy: SoundTaxonomy = .appleV1) {
        self.policy = policy
        var speech = Set<SoundLabel>()
        var music = Set<SoundLabel>()
        for definition in taxonomy.definitions {
            if policy.speechKindIDs.contains(definition.kind.id) { speech.formUnion(definition.labels) }
            if definition.kind.id == policy.musicKindID { music.formUnion(definition.labels) }
        }
        speechLabels = speech
        musicLabels = music
    }

    public func evidence(in frame: ClassificationFrame) -> SpeechEvidence {
        var speech = 0.0
        var music = 0.0
        for prediction in frame.predictions {
            if speechLabels.contains(prediction.label) { speech = max(speech, prediction.score.rawValue) }
            if musicLabels.contains(prediction.label) { music = max(music, prediction.score.rawValue) }
        }
        let candidate = speech >= policy.candidateScore
        let musicPresent = music >= policy.musicPresentScore
        let accepted = candidate && (!musicPresent || speech >= policy.speechScoreOverMusic)
        return SpeechEvidence(speechScore: speech, musicScore: music, isSpeech: accepted,
                              suppressedByMusic: candidate && !accepted)
    }

    public mutating func process(_ frame: ClassificationFrame) -> Transition? {
        let evidence = evidence(in: frame)
        lastEvidence = evidence
        if evidence.suppressedByMusic { windowsSuppressedByMusic += 1 }
        if evidence.isSpeech {
            lastSpeechTime = frame.audioTime.end
            guard !isActive else { return nil }
            isActive = true
            return .began(onset: frame.audioTime.start)
        }
        if isActive, frame.audioTime.end - lastSpeechTime >= policy.releaseAfter - 1e-6 {
            isActive = false
            return .ended(at: frame.audioTime.end)
        }
        return nil
    }

    public mutating func reset() {
        isActive = false
        lastEvidence = .none
        lastSpeechTime = 0
        windowsSuppressedByMusic = 0
    }
}
