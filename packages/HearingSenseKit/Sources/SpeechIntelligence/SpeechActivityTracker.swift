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
///
/// Music changes the picture: sung or rapped vocals often get a `speech` score, so in a music
/// context the bar is higher (stage A of the speech relevance gate; stage B is
/// `SpeechRelevanceGate`). Measured on recordings (docs/testing/WINDOW3_TEST_RESULTS.md):
/// windows of real speech over music score ≥ 0.9 most of the time, vocal music mostly does not.
public struct SpeechActivationPolicy: Hashable, Sendable {
    /// Event kinds whose labels count as speech (`SoundTaxonomy` kind ids).
    public var speechKindIDs: Set<String> = ["speech", "shouting"]
    public var musicKindID = "music"
    /// Labels of the music kind that mean a human voice making music.
    public var vocalMusicLabels: Set<SoundLabel> = ["singing", "choir_singing", "rapping", "humming", "yodeling"]
    /// Minimum speech score of one window to activate or sustain speech activity when no music
    /// is around.
    public var candidateScore = 0.30
    /// A window with a music score at or above this value is "music present".
    public var musicPresentScore = 0.50
    /// Music context: music was present in at least `musicContextMinimum` of the last
    /// `musicContextWindows` windows (or is present now). Vocals can mask the music label for a
    /// window or two; the context remembers that music is playing.
    public var musicContextWindows = 4
    public var musicContextMinimum = 2
    /// In a music context a window counts as speech when its speech score reaches this value …
    public var strongSpeechScore = 0.90
    /// … or when it reaches this value while no vocal-music label is above
    /// `maximumVocalScoreOverMusic`.
    public var speechScoreOverMusic = 0.80
    public var maximumVocalScoreOverMusic = 0.20
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
    /// Best score among the vocal-music labels (singing, rapping, humming, …).
    public var vocalScore: Double
    /// Music is present now or was in most of the recent windows.
    public var isMusicContext: Bool
    /// The window qualifies as speech under the activation policy.
    public var isSpeech: Bool
    /// The window had a speech score ≥ `candidateScore` but was not accepted because of the
    /// music context (probably vocals).
    public var suppressedByMusic: Bool

    public static let none = SpeechEvidence(speechScore: 0, musicScore: 0, vocalScore: 0, isMusicContext: false,
                                            isSpeech: false, suppressedByMusic: false)
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
    /// Whether music was present in each of the most recent windows (newest last).
    private var recentMusic: [Bool] = []

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

    /// Evaluates one window given whether music was present in the windows before it.
    public func evidence(in frame: ClassificationFrame) -> SpeechEvidence {
        var speech = 0.0
        var music = 0.0
        var vocal = 0.0
        for prediction in frame.predictions {
            let score = prediction.score.rawValue
            if speechLabels.contains(prediction.label) { speech = max(speech, score) }
            if musicLabels.contains(prediction.label) { music = max(music, score) }
            if policy.vocalMusicLabels.contains(prediction.label) { vocal = max(vocal, score) }
        }
        let candidate = speech >= policy.candidateScore
        let musicContext = music >= policy.musicPresentScore
            || recentMusic.count(where: \.self) >= policy.musicContextMinimum
        let accepted: Bool
        if musicContext {
            accepted = speech >= policy.strongSpeechScore
                || (speech >= policy.speechScoreOverMusic && vocal <= policy.maximumVocalScoreOverMusic)
        } else {
            accepted = candidate
        }
        return SpeechEvidence(speechScore: speech, musicScore: music, vocalScore: vocal, isMusicContext: musicContext,
                              isSpeech: accepted, suppressedByMusic: candidate && !accepted)
    }

    public mutating func process(_ frame: ClassificationFrame) -> Transition? {
        let evidence = evidence(in: frame)
        lastEvidence = evidence
        recentMusic.append(evidence.musicScore >= policy.musicPresentScore)
        if recentMusic.count > policy.musicContextWindows {
            recentMusic.removeFirst(recentMusic.count - policy.musicContextWindows)
        }
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
        recentMusic.removeAll()
    }
}
