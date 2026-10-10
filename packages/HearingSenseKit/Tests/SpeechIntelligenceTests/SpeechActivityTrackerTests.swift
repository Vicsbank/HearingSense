import Foundation
import HearingSenseDomain
import Testing
@testable import SpeechIntelligence

/// Synthetic classifier windows (1.5 s long, one every 0.75 s).
struct WindowScript {
    private var index = 0

    mutating func frame(_ scores: [SoundLabel: Double]) -> ClassificationFrame {
        let range = AudioTimeRange(start: Double(index) * 0.75, duration: 1.5)
        let date = Date(timeIntervalSince1970: 1_000_000 + range.end)
        index += 1
        return ClassificationFrame(
            sequence: index - 1, audioTime: range, producedAt: date, capturedAt: date, model: .appleSoundClassifierV1,
            predictions: scores.map {
                RawSoundPrediction(label: $0.key, score: ClassifierScore($0.value), audioTime: range, producedAt: date,
                                   model: .appleSoundClassifierV1)
            },
            inputLevel: nil)
    }
}

@Suite struct SpeechActivityTrackerTests {
    @Test func aSingleCandidateWindowActivatesBeforeTheSoundDetectorWouldConfirm() {
        var tracker = SpeechActivityTracker()
        var script = WindowScript()
        #expect(tracker.process(script.frame(["silence": 0.9])) == nil)
        #expect(tracker.process(script.frame(["speech": 0.29])) == nil)
        // One window at 0.35 is below the detector's enter threshold (0.5) but activates speech.
        #expect(tracker.process(script.frame(["speech": 0.35])) == .began(onset: 1.5))
        #expect(tracker.isActive && tracker.lastEvidence.isSpeech)
        #expect(tracker.process(script.frame(["speech": 0.9])) == nil)
    }

    @Test func activityEndsAfterTheReleaseTimeWithoutSpeech() {
        var tracker = SpeechActivityTracker()
        var script = WindowScript()
        #expect(tracker.process(script.frame(["speech": 0.8])) == .began(onset: 0))  // ends 1.5
        #expect(tracker.process(script.frame([:])) == nil)  // 2.25
        #expect(tracker.process(script.frame(["speech": 0.31])) == nil)  // 3.0: sustained
        #expect(tracker.process(script.frame([:])) == nil)  // 3.75
        #expect(tracker.process(script.frame(["dog_bark": 0.9])) == nil)  // 4.5
        #expect(tracker.process(script.frame([:])) == .ended(at: 5.25))
        #expect(!tracker.isActive)
        #expect(tracker.process(script.frame(["speech": 0.6])) == .began(onset: 4.5))
    }

    @Test func whisperingChatterAndShoutingCountAsSpeech() {
        for label in ["whispering", "chatter", "shout", "yell", "children_shouting"] {
            var tracker = SpeechActivityTracker()
            var script = WindowScript()
            #expect(tracker.process(script.frame([SoundLabel(label): 0.5])) == .began(onset: 0), "\(label)")
        }
        // Non-linguistic human sounds do not.
        for label in ["laughter", "crying_sobbing", "screaming", "cough", "singing"] {
            var tracker = SpeechActivityTracker()
            var script = WindowScript()
            #expect(tracker.process(script.frame([SoundLabel(label): 0.9])) == nil, "\(label)")
        }
    }

    @Test func inAMusicContextOnlyStrongOrVocalFreeSpeechActivates() {
        var tracker = SpeechActivityTracker()
        var script = WindowScript()
        // Sung vocals: music is confident, speech is a secondary label, a vocal label is present.
        #expect(tracker.process(script.frame(["music": 0.9, "singing": 0.8, "speech": 0.4])) == nil)
        #expect(tracker.lastEvidence.suppressedByMusic && !tracker.lastEvidence.isSpeech)
        #expect(tracker.lastEvidence.vocalScore == 0.8 && tracker.lastEvidence.isMusicContext)
        // Even a fairly high speech score does not activate while a vocal label is present …
        #expect(tracker.process(script.frame(["music": 0.9, "rapping": 0.5, "speech": 0.85])) == nil)
        // … nor a moderate one without vocals.
        #expect(tracker.process(script.frame(["music": 0.9, "speech": 0.7])) == nil)
        #expect(tracker.windowsSuppressedByMusic == 3)
        // A clear speech score without vocal labels does: someone talks over instrumental music.
        #expect(tracker.process(script.frame(["music": 0.9, "speech": 0.82, "singing": 0.15])) == .began(onset: 2.25))

        // A strong speech score activates whatever else is in the window.
        var strong = SpeechActivityTracker()
        #expect(strong.process(script.frame(["music": 0.9, "singing": 0.6, "speech": 0.93])) != nil)
        // Weak music is not a music context.
        var quiet = SpeechActivityTracker()
        #expect(quiet.process(script.frame(["guitar": 0.45, "speech": 0.35])) != nil)
        #expect(!quiet.lastEvidence.isMusicContext)
    }

    @Test func theMusicContextIsRememberedWhenVocalsMaskTheMusicLabel() {
        var tracker = SpeechActivityTracker()
        var script = WindowScript()
        _ = tracker.process(script.frame(["music": 0.8]))
        _ = tracker.process(script.frame(["music": 0.7]))
        // The music label dips below "present", but music was playing a moment ago.
        #expect(tracker.process(script.frame(["music": 0.3, "speech": 0.5])) == nil)
        #expect(tracker.lastEvidence.isMusicContext && tracker.lastEvidence.suppressedByMusic)
        // After enough windows without music the ordinary candidate threshold applies again.
        _ = tracker.process(script.frame([:]))
        _ = tracker.process(script.frame([:]))
        _ = tracker.process(script.frame([:]))
        #expect(tracker.process(script.frame(["speech": 0.35])) != nil)
        #expect(!tracker.lastEvidence.isMusicContext)
    }

    @Test func thresholdsComeFromThePolicy() {
        var policy = SpeechActivationPolicy()
        policy.candidateScore = 0.6
        policy.releaseAfter = 0.75
        var tracker = SpeechActivityTracker(policy: policy)
        var script = WindowScript()
        #expect(tracker.process(script.frame(["speech": 0.5])) == nil)
        #expect(tracker.process(script.frame(["speech": 0.6])) == .began(onset: 0.75))
        #expect(tracker.process(script.frame([:])) == .ended(at: 3.0))
        tracker.reset()
        #expect(!tracker.isActive && tracker.lastSpeechTime == 0)
    }
}
