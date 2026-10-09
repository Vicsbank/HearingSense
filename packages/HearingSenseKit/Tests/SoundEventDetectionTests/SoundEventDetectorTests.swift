import Foundation
import HearingSenseDomain
import Testing
@testable import SoundEventDetection

/// Scripted frame sequences (1.5 s windows, 0.75 s hop, like the standard configuration).
@Suite struct SoundEventDetectorTests {
    @Test func continuousSpeechNeedsTwoWindowsAndFluctuationsStayOneEvent() {
        var detector = SoundEventDetector()
        var script = FrameScript()
        // speech → chatter → weak speech → silence-ish window → speech: one event.
        let updates = detector.run(&script, [
            ["speech": 0.8],
            ["speech": 0.7],
            ["chatter": 0.6, "speech": 0.4],
            ["speech": 0.35],
            ["silence": 0.6],
            ["speech": 0.9],
        ])
        // One event: started once, possibly updated (quality rose), never ended or restarted.
        #expect(updates.filter { !$0.summary.hasPrefix("updated") }.map(\.summary) == ["started speech"])
        #expect(Set(updates.map(\.event.id)).count == 1)
        let event = try! #require(detector.activeEvents.first)
        #expect(event.audioStart == 0)  // first supporting window starts at 0
        #expect(event.confirmationLatency == 2.25)  // window 1 ends at 0.75 + 1.5
        #expect(detector.activeEvents.count == 1)
    }

    @Test func singleSpeechWindowIsOnlyACandidate() {
        var detector = SoundEventDetector()
        var script = FrameScript()
        let updates = detector.run(&script, [["speech": 0.95], [:], [:], [:], [:]])
        #expect(updates.isEmpty)
        #expect(detector.statistics.candidatesStarted == 1)
        #expect(detector.statistics.candidatesRejected == 1)
    }

    @Test func briefLowConfidenceHornDuringSpeechIsSuppressed() {
        var detector = SoundEventDetector()
        var script = FrameScript()
        let updates = detector.run(&script, [
            ["speech": 0.8],
            ["speech": 0.8, "car_horn": 0.45],
            ["speech": 0.8],
            ["speech": 0.8],
            ["speech": 0.8],
            ["speech": 0.8],
        ])
        #expect(Set(updates.map(\.event.kind.id)) == ["speech"])
        #expect(!detector.activeEvents.contains { $0.kind.id == "vehicle_horn" })
        #expect(detector.statistics.candidatesStarted == 1)  // speech only: 0.45 < horn enter 0.5
    }

    @Test func singleStrongHornWindowIsNotEnoughButARepeatedHornIs() {
        var detector = SoundEventDetector()
        var script = FrameScript()
        #expect(detector.run(&script, [["car_horn": 0.75], [:], [:], [:]]).isEmpty)

        let updates = detector.run(&script, [["car_horn": 0.6], ["air_horn": 0.55]])
        #expect(updates.map(\.summary) == ["started vehicle_horn"])
    }

    @Test func veryStrongHornConfirmsInstantly() {
        var detector = SoundEventDetector()
        var script = FrameScript()
        #expect(detector.run(&script, [["car_horn": 0.9]]).map(\.summary) == ["started vehicle_horn"])
    }

    @Test func briefKnockConfirmsFromOneClearWindow() {
        var detector = SoundEventDetector()
        var script = FrameScript()
        let updates = detector.run(&script, [["knock": 0.7], [:], [:], [:], [:]])
        #expect(updates.map(\.summary) == ["started door", "ended door"])
        let ended = try! #require(updates.last?.event)
        #expect(ended.phase == .ended)
        #expect(ended.primaryLabel == "knock")
    }

    @Test func moderateKnocksInConsecutiveWindowsConfirm() {
        var detector = SoundEventDetector()
        var script = FrameScript()
        let updates = detector.run(&script, [["knock": 0.45], ["knock": 0.5]])
        #expect(updates.map(\.summary) == ["started door"])
    }

    @Test func hitsOutsideTheLookBackDoNotCombine() {
        var detector = SoundEventDetector()
        var script = FrameScript()
        // Two music hits 3.75 s apart: continuous rule needs 2 hits within 2 s.
        let updates = detector.run(&script, [["music": 0.6], [:], [:], [:], [:], ["music": 0.6], [:], [:], [:]])
        #expect(updates.isEmpty)
        #expect(detector.statistics.candidatesRejected == 2)
    }

    @Test func hysteresisKeepsAnActiveEventAtScoresThatCouldNotStartOne() {
        var detector = SoundEventDetector()
        var script = FrameScript()
        _ = detector.run(&script, [["rain": 0.6], ["rain": 0.6]])
        let sustain = detector.run(&script, Array(repeating: ["rain": 0.35], count: 8))
        #expect(!sustain.contains { if case .ended = $0 { true } else { false } })
        #expect(detector.activeEvents.map(\.kind.id) == ["rain"])

        var fresh = SoundEventDetector()
        var freshScript = FrameScript()
        #expect(fresh.run(&freshScript, Array(repeating: ["rain": 0.35], count: 8)).isEmpty)
    }

    @Test func continuousEventEndsAfterItsTimeout() {
        var detector = SoundEventDetector()
        var script = FrameScript()
        _ = detector.run(&script, [["music": 0.8], ["music": 0.8]])  // last support ends at 2.25 s
        // Silent windows end at 3.0, 3.75, 4.5, 5.25: ends when ≥ 3 s passed → at 5.25.
        let updates = detector.run(&script, [[:], [:], [:]])
        #expect(updates.isEmpty)
        let ending = detector.run(&script, [[:]])
        #expect(ending.map(\.summary) == ["ended music"])
        #expect(ending.first?.event.audioLastObserved == 2.25)
        #expect(detector.activeEvents.isEmpty)
    }

    @Test func synonymousLabelsMergeAndDifferentKindsCoexist() {
        var detector = SoundEventDetector()
        var script = FrameScript()
        let updates = detector.run(&script, [
            ["dog_bark": 0.6, "bird_chirp_tweet": 0.6],
            ["dog_growl": 0.5, "bird": 0.5],
        ])
        #expect(updates.map(\.summary).sorted() == ["started bird", "started dog"])
        let dog = try! #require(detector.activeEvents.first { $0.kind.id == "dog" })
        #expect(Set(dog.evidence.labels.map(\.label)) == ["dog_bark", "dog_growl"])
        #expect(dog.primaryLabel == "dog_bark")
    }

    @Test func updatesAreRateLimitedButPrimaryLabelChangesArePublished() {
        var detector = SoundEventDetector()
        var script = FrameScript()
        _ = detector.run(&script, [["engine": 0.6], ["engine": 0.6]])
        // Same label for 4 more windows (3 s of audio): nothing new to publish.
        #expect(detector.run(&script, Array(repeating: ["engine": 0.6], count: 4)).isEmpty)
        // traffic_noise accumulates more evidence than engine → primary label changes.
        var changes: [AcousticEventUpdate] = []
        for _ in 0 ..< 8 { changes += detector.run(&script, [["traffic_noise": 0.9]]) }
        #expect(changes.contains { $0.event.primaryLabel == "traffic_noise" })
        #expect(changes.allSatisfy { if case .updated = $0 { true } else { false } })
        #expect(changes.allSatisfy { $0.event.phase == .ongoing })
    }

    @Test func finishEndsActiveEventsAndDropsCandidates() {
        var detector = SoundEventDetector()
        var script = FrameScript()
        _ = detector.run(&script, [["speech": 0.8], ["speech": 0.8, "dog": 0.5]])
        let end = Date(timeIntervalSince1970: 2_000_000)
        let updates = detector.finish(at: end)
        #expect(updates.map(\.summary) == ["ended speech"])
        #expect(updates.first?.event.endedDate == end)
        #expect(detector.activeEvents.isEmpty && detector.candidates.isEmpty)
        #expect(detector.statistics.candidatesRejected == 1)
    }

    @Test func wallClockTimesFollowTheCaptureClock() {
        var detector = SoundEventDetector()
        var script = FrameScript()
        let updates = detector.run(&script, [["speech": 0.8], ["speech": 0.8]])
        let event = try! #require(updates.first?.event)
        #expect(event.startDate == script.origin)  // audio time 0 ↔ origin
        #expect(event.confirmedDate == script.origin.addingTimeInterval(2.25 + 0.05))
        #expect(event.source == .soundClassifier(.appleSoundClassifierV1))
    }

    @Test func replayingTheSameFramesGivesTheSameDecisions() {
        let windows: [[SoundLabel: Double]] = [
            ["speech": 0.7], ["speech": 0.6, "knock": 0.7], [:], ["music": 0.6], ["music": 0.7], [:], [:], [:], [:], [:],
        ]
        func run() -> [String] {
            var detector = SoundEventDetector()
            var script = FrameScript()
            return detector.run(&script, windows).map { "\($0.summary)@\($0.event.audioConfirmed)" }
        }
        #expect(run() == run())
    }

    @Test func eventIdentityIsStableAcrossUpdates() {
        var detector = SoundEventDetector()
        var script = FrameScript()
        var updates = detector.run(&script, [["crowd": 0.7], ["crowd": 0.7]])
        updates += detector.run(&script, Array(repeating: ["crowd": 0.7], count: 8))
        updates += detector.run(&script, Array(repeating: [:], count: 5))
        #expect(Set(updates.map(\.event.id)).count == 1)
        #expect(updates.first.map { if case .started = $0 { true } else { false } } == true)
        #expect(updates.last.map { if case .ended = $0 { true } else { false } } == true)
    }
}

@Suite struct EnvironmentStatusTests {
    @Test func distinguishesQuietUnclassifiedUncertainAndRecognized() {
        var detector = SoundEventDetector()
        var script = FrameScript()
        #expect(detector.process(script.frame([:], rmsDBFS: -75)).status == .quiet)
        #expect(detector.process(script.frame(["silence": 0.9], rmsDBFS: -40)).status == .quiet)
        #expect(detector.process(script.frame(["speech": 0.1], rmsDBFS: -30)).status == .unclassified)
        let uncertain = detector.process(script.frame(["typing": 0.35], rmsDBFS: -30)).status
        guard case .uncertain(let top) = uncertain else {
            Issue.record("expected uncertain, got \(uncertain)")
            return
        }
        #expect(top.label == "typing")
        _ = detector.process(script.frame(["music": 0.8]))
        let recognized = detector.process(script.frame(["music": 0.8])).status
        guard case .recognized(let events) = recognized else {
            Issue.record("expected recognized, got \(recognized)")
            return
        }
        #expect(events.map(\.kind.id) == ["music"])
    }

    @Test func unknownLevelDoesNotImplyQuiet() {
        var detector = SoundEventDetector()
        var script = FrameScript()
        #expect(detector.process(script.frame([:], rmsDBFS: nil)).status == .unclassified)
    }
}

@Suite struct CompetingClassificationTests {
    @Test func foghornDuringMusicIsSuppressedButCarHornIsNot() {
        var detector = SoundEventDetector()
        var script = FrameScript()
        let foghorn = detector.run(&script, [["music": 0.8, "foghorn": 0.95], ["music": 0.8, "foghorn": 0.9]])
        #expect(!foghorn.contains { $0.event.kind.id == "vehicle_horn" })

        var other = SoundEventDetector()
        var otherScript = FrameScript()
        let carHorn = other.run(&otherScript, [["music": 0.8, "car_horn": 0.9]])
        #expect(carHorn.contains { $0.event.kind.id == "vehicle_horn" })
    }

    @Test func foghornWithoutMusicStillCounts() {
        var detector = SoundEventDetector()
        var script = FrameScript()
        #expect(detector.run(&script, [["foghorn": 0.9]]).map(\.summary) == ["started vehicle_horn"])
    }
}
