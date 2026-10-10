import Foundation
import HearingSenseDomain
import Testing
@testable import SpeechIntelligence

/// Synthetic classifier windows. The thresholds themselves were chosen and checked on recordings
/// (docs/testing/WINDOW3_TEST_RESULTS.md); these tests pin the rule's logic.
@Suite struct SpeechRelevanceGateTests {
    /// Feeds windows (1.5 s long, every 0.75 s) with the given scores through tracker and gate.
    static func gate(_ windows: [[SoundLabel: Double]]) -> SpeechRelevanceGate {
        var tracker = SpeechActivityTracker()
        var gate = SpeechRelevanceGate()
        var script = WindowScript()
        for scores in windows {
            let frame = script.frame(scores)
            _ = tracker.process(frame)
            gate.record(frame, evidence: tracker.lastEvidence)
        }
        return gate
    }

    static let wholeSpan = AudioTimeRange(start: 0.75, end: 6.0)

    @Test func speechWithoutMusicIsNearbySpeech() throws {
        let gate = Self.gate(Array(repeating: ["speech": 0.6], count: 8))
        let context = try #require(gate.assess(Self.wholeSpan, meanConfidence: 0.4))
        #expect(context.relevance == .nearbySpeech && context.musicShare == 0 && context.windows == 8)
    }

    @Test func sustainedStrongSpeechOverMusicIsSpeechOverMusic() throws {
        let talking: [SoundLabel: Double] = ["speech": 0.95, "music": 0.7]
        let dip: [SoundLabel: Double] = ["speech": 0.7, "music": 0.8, "singing": 0.3]
        let gate = Self.gate([talking, talking, dip, talking, dip, dip, talking, talking])
        let context = try #require(gate.assess(Self.wholeSpan, meanConfidence: 0.7))
        #expect(context.relevance == .speechOverMusic && context.musicShare == 1)
        #expect(context.strongSpeechShare > 0.5 && context.vocalMusicShare > 0)
        // The same audio with a recognizer that could barely make out words is not trusted.
        #expect(gate.assess(Self.wholeSpan, meanConfidence: 0.45)?.relevance == .possiblyMusic)
    }

    @Test func sporadicSpeechScoresInVocalMusicArePossiblyMusic() throws {
        let singing: [SoundLabel: Double] = ["music": 0.85, "singing": 0.6, "speech": 0.5]
        let peak: [SoundLabel: Double] = ["music": 0.8, "singing": 0.4, "speech": 0.92]
        let gate = Self.gate([singing, singing, peak, singing, singing, singing, singing, singing])
        let context = try #require(gate.assess(Self.wholeSpan, meanConfidence: 0.75))
        #expect(context.relevance == .possiblyMusic && context.strongSpeechShare < 0.34 && context.vocalMusicShare == 1)
    }

    @Test func clearScoresWithAVeryConfidentRecognizerAlsoCount() throws {
        let clear: [SoundLabel: Double] = ["music": 0.7, "speech": 0.85]
        let gate = Self.gate(Array(repeating: clear, count: 8))
        #expect(gate.assess(Self.wholeSpan, meanConfidence: 0.9)?.relevance == .speechOverMusic)
        #expect(gate.assess(Self.wholeSpan, meanConfidence: 0.7)?.relevance == .possiblyMusic)
        // Without a confidence only the strong-score cue can vouch for speech.
        #expect(gate.assess(Self.wholeSpan, meanConfidence: nil)?.relevance == .possiblyMusic)
    }

    @Test func onlyWindowsThatOverlapTheUtteranceCount() throws {
        let music: [SoundLabel: Double] = ["music": 0.9, "singing": 0.7]
        let talk: [SoundLabel: Double] = ["speech": 0.97]
        // Windows end at 1.5, 2.25, …; music stops, then someone talks from about 6 s.
        let gate = Self.gate([music, music, music, music, [:], [:], [:], talk, talk, talk, talk])
        let speech = try #require(gate.assess(AudioTimeRange(start: 6.0, end: 8.5), meanConfidence: 0.9))
        #expect(speech.relevance == .nearbySpeech && speech.musicShare == 0)
        let song = try #require(gate.assess(AudioTimeRange(start: 0.5, end: 3.0), meanConfidence: 0.6))
        #expect(song.relevance == .possiblyMusic && song.musicShare == 1)
        // A very short utterance still gets the window that covers it.
        let short = try #require(gate.assess(AudioTimeRange(start: 7.0, end: 7.3), meanConfidence: 0.9))
        #expect(short.relevance == .nearbySpeech && short.windows >= 1)
    }

    @Test func withoutClassifierWindowsNothingIsClaimed() {
        var gate = SpeechRelevanceGate()
        #expect(gate.assess(Self.wholeSpan, meanConfidence: 0.9) == nil)
        gate = Self.gate([["speech": 0.9]])
        #expect(gate.assess(AudioTimeRange(start: 100, end: 102), meanConfidence: 0.9) == nil)
        gate.reset()
        #expect(gate.assess(AudioTimeRange(start: 0, end: 1.5), meanConfidence: 0.9) == nil)
    }

    @Test func historyIsBounded() {
        var policy = SpeechRelevancePolicy()
        policy.historySeconds = 6
        var tracker = SpeechActivityTracker()
        var gate = SpeechRelevanceGate(policy: policy)
        var script = WindowScript()
        for _ in 0 ..< 40 {
            let frame = script.frame(["speech": 0.9])
            _ = tracker.process(frame)
            gate.record(frame, evidence: tracker.lastEvidence)
        }
        // Audio older than the history is no longer assessable; recent audio is.
        #expect(gate.assess(AudioTimeRange(start: 0, end: 3), meanConfidence: 0.9) == nil)
        #expect(gate.assess(AudioTimeRange(start: 27, end: 30), meanConfidence: 0.9) != nil)
    }
}
