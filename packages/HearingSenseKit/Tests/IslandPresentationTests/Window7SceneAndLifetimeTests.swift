import AttentionReplay
import Foundation
import HearingSenseDomain
import IslandPresentation
import SoundEventDetection
import Testing

/// Window 7: the acoustic scene layer.
@Suite struct AcousticSceneTrackerTests {
    /// Drives the tracker and delivers its deadlines.
    struct Driver {
        var tracker = AcousticSceneTracker()
        private(set) var changes: [(time: TimeInterval, scene: AcousticScene)] = []
        private var number = 0

        init() { tracker.process(.sessionStarted(at: T.origin)) }

        mutating func advance(to time: TimeInterval) {
            while let deadline = tracker.nextDeadline, deadline <= T.date(time) {
                note(tracker.process(.tick(at: deadline)), at: T.seconds(deadline))
            }
            note(tracker.process(.tick(at: T.date(time))), at: time)
        }

        /// A sound from `start` to `end`, republished every 5 s like the detector does.
        mutating func play(_ kind: String, from start: TimeInterval, to end: TimeInterval, quality: EventQuality = .strong) {
            number += 1
            var event = SyntheticSoundEvent(kindID: kind, number: number, start: T.date(start), quality: quality, confirmDelay: 0)
            advance(to: start)
            note(tracker.process(.sound(event.started())), at: start)
            var time = start + 5
            while time < end {
                advance(to: time)
                note(tracker.process(.sound(event.updated(at: T.date(time)))), at: time)
                time += 5
            }
            advance(to: end)
            note(tracker.process(.sound(event.ended(at: T.date(end)))), at: end)
        }

        private mutating func note(_ change: AcousticSceneEstimate?, at time: TimeInterval) {
            if let change { changes.append((time, change.scene)) }
        }

        var scenes: [AcousticScene] { changes.map(\.scene) }
    }

    @Test func nothingRecognizedBecomesQuietAfterAWhileAndThenNeedsNoTimer() {
        var driver = Driver()
        driver.advance(to: 10)
        #expect(driver.tracker.current == nil)
        driver.advance(to: 60)
        #expect(driver.scenes == [.quiet])
        #expect(driver.tracker.nextDeadline == nil)
    }

    @Test func sustainedMusicBecomesTheMusicScene() {
        var driver = Driver()
        driver.play("music", from: 2, to: 80)
        #expect(driver.scenes == [.music])
        #expect((driver.tracker.current?.confidence ?? 0) > 0.9)
        // Evidence accumulation and dwell: not in the first seconds.
        #expect((driver.changes.first?.time ?? 0) >= 12)
    }

    @Test func eachKindOfSurroundingsIsRecognizedFromItsSounds() {
        let cases: [(String, AcousticScene)] = [("speech", .conversation), ("crowd", .conversation), ("road_vehicle", .traffic),
                                                ("rain", .nature), ("bird", .nature), ("music", .music), ("appliance", .indoor)]
        for (kind, scene) in cases {
            var driver = Driver()
            driver.play(kind, from: 1, to: 60)
            #expect(driver.tracker.current?.scene == scene, "\(kind)")
        }
    }

    /// Temporal smoothing: one short sound does not change the scene.
    @Test func aShortSoundDoesNotChangeTheScene() {
        var driver = Driver()
        driver.play("rain", from: 1, to: 60)
        #expect(driver.tracker.current?.scene == .nature)
        driver.play("vehicle_horn", from: 61, to: 62)
        driver.play("dog", from: 64, to: 67)
        driver.play("rain", from: 68, to: 120)
        #expect(driver.scenes == [.nature])
    }

    /// Hysteresis: the scene follows a lasting change, once, and not at the first sign of it.
    @Test func aLastingChangeSwitchesTheSceneOnceAfterADelay() throws {
        var driver = Driver()
        driver.play("music", from: 1, to: 60)
        driver.play("road_vehicle", from: 60, to: 200)
        #expect(driver.scenes.first == .music)
        #expect(driver.scenes.last == .traffic)
        let traffic = try #require(driver.changes.first { $0.scene == .traffic })
        // The traffic has to outweigh the remembered music and then lead for the dwell time.
        #expect(traffic.time >= 80)
        #expect(traffic.time <= 140)
        // No flicker: every scene appears at most once.
        #expect(Set(driver.scenes).count == driver.scenes.count)
    }

    @Test func alternatingSoundsDoNotMakeTheSceneFlicker() {
        var driver = Driver()
        var time = 1.0
        for index in 0 ..< 30 {
            driver.play(index.isMultiple(of: 2) ? "speech" : "music", from: time, to: time + 7)
            time += 8
        }
        // Whatever it settles on, it does not follow every sound.
        #expect(driver.changes.count <= 3)
        for (earlier, later) in zip(driver.changes, driver.changes.dropFirst()) {
            #expect(later.time - earlier.time >= AcousticScenePolicy.standard.minimumHold)
        }
    }

    @Test func severalKindsAtOnceWithoutALeaderAreMixed() {
        var driver = Driver()
        for start in stride(from: 1.0, to: 90, by: 30) {
            driver.play("music", from: start, to: start + 9)
            driver.play("road_vehicle", from: start + 10, to: start + 19)
            driver.play("speech", from: start + 20, to: start + 29)
        }
        #expect(driver.scenes.contains(.mixed))
    }

    @Test func afterTheSoundsEndItBecomesQuietAgain() {
        var driver = Driver()
        driver.play("music", from: 1, to: 50)
        driver.advance(to: 200)
        #expect(driver.scenes == [.music, .quiet])
        #expect(driver.tracker.nextDeadline == nil)
    }

    @Test func weakEvidenceCountsLessAndSomeSoundsSayNothingAboutTheScene() {
        let policy = AcousticScenePolicy.standard
        #expect(policy.weight(for: .weak) < policy.weight(for: .strong))
        for id in ["dog", "footsteps", "silence", "mic_wind_noise", "screaming", "door"] {
            let kind = SyntheticSound.kind(id)
            if id == "door" {
                #expect(policy.scene(for: kind) == .indoor)
            } else {
                #expect(policy.scene(for: kind) == nil, "\(id)")
            }
        }
        #expect(policy.scene(for: SyntheticSound.kind("siren")) == .traffic)
        var driver = Driver()
        driver.play("dog", from: 1, to: 40)
        #expect(driver.scenes.allSatisfy { $0 == .quiet })
    }

    @Test func theSameInputsGiveTheSameScenesAndTheStateIsBounded() {
        func run() -> [String] {
            var driver = Driver()
            var time = 1.0
            let kinds = ["music", "speech", "road_vehicle", "rain", "bird", "appliance", "vehicle_horn", "crowd"]
            for index in 0 ..< 400 {
                driver.play(kinds[(index * 7) % kinds.count], from: time, to: time + Double(index % 5) + 1)
                time += Double(index % 4) + 1.5
            }
            #expect(driver.tracker.evidence(at: T.date(time)).values.reduce(0, +) <= 60 * 8)
            return driver.changes.map { "\($0.time):\($0.scene.rawValue)" }
        }
        #expect(run() == run())
    }

    @Test func endingTheSessionForgetsEverything() {
        var driver = Driver()
        driver.play("music", from: 1, to: 60)
        driver.tracker.process(.sessionEnded(at: T.date(61)))
        #expect(driver.tracker.current == nil)
        #expect(driver.tracker.nextDeadline == nil)
        #expect(driver.tracker.evidence(at: T.date(62)).isEmpty)
        // Sounds that still arrive after the end change nothing.
        var late = SyntheticSoundEvent(kindID: "music", number: 999, start: T.date(62), confirmDelay: 0)
        #expect(driver.tracker.process(.sound(late.started())) == nil)
        #expect(driver.tracker.process(.sound(late.ended(at: T.date(70)))) == nil)
        #expect(driver.tracker.current == nil)
    }

    @Test func everySceneHasWordsAndASymbol() {
        for scene in AcousticScene.allCases {
            #expect(!scene.title.isEmpty)
            #expect(!scene.symbolName.isEmpty)
        }
        #expect(Set(AcousticScene.allCases.map(\.title)).count == AcousticScene.allCases.count)
    }
}

/// Acceptance test 15: the eight-hour limit of a Live Activity. The app does not work around
/// it (decision of 2026-10-11): nothing is replaced, and nothing is requested after the limit.
@Suite struct ActivityLifetimeTests {
    private let policy = ActivityLifetimePolicy.standard
    private func hours(_ value: Double) -> Date { T.date(value * 3600) }

    @Test func aRunningActivityIsNeverReplacedHoweverOldItIs() {
        for reachedLimit in [false, true] {
            for active in [true, false] {
                #expect(policy.decide(sessionIsLive: true, hasActivity: true, reachedLimit: reachedLimit, appIsActive: active) == .keep)
            }
        }
        // The policy has no decision that ends a running activity.
        #expect(!ActivityLifetimePolicy.Decision.allCases.map(\.rawValue).contains { $0.contains("renew") || $0.contains("replace") })
    }

    @Test func afterTheSystemsLimitNothingIsRequestedForThisSession() {
        #expect(policy.endedAtLimit(startedAt: T.origin, endedAt: hours(8)))
        #expect(policy.endedAtLimit(startedAt: T.origin, endedAt: hours(7.9)))
        #expect(policy.endedAtLimit(startedAt: T.origin, endedAt: hours(11)))
        for active in [true, false] {
            #expect(policy.decide(sessionIsLive: true, hasActivity: false, reachedLimit: true, appIsActive: active) == .stayEnded)
        }
    }

    @Test func anActivityRemovedBeforeItsTimeIsShownAgainWhenTheAppIsOpened() {
        #expect(!policy.endedAtLimit(startedAt: T.origin, endedAt: hours(0.5)))
        #expect(!policy.endedAtLimit(startedAt: T.origin, endedAt: hours(7.5)))
        #expect(policy.decide(sessionIsLive: true, hasActivity: false, reachedLimit: false, appIsActive: false) == .waitForForeground)
        #expect(policy.decide(sessionIsLive: true, hasActivity: false, reachedLimit: false, appIsActive: true) == .start)
    }

    @Test func withoutASessionNothingIsEverRequested() {
        for active in [true, false] {
            for hasActivity in [true, false] {
                for reachedLimit in [true, false] {
                    #expect(policy.decide(sessionIsLive: false, hasActivity: hasActivity, reachedLimit: reachedLimit, appIsActive: active)
                        == .keep)
                }
            }
        }
    }

    @Test func theExpectedEndIsEightHoursAfterTheStart() {
        #expect(policy.expectedEnd(startedAt: T.origin) == hours(8))
        #expect(policy.limitTolerance < 3600)
    }
}

/// Cost of the Window 7 layers per input, on the machine that runs the tests (a debug build;
/// printed for the report, and bounded loosely so that an accidental quadratic step fails).
@Suite struct Window7CostTests {
    @Test func theSceneTrackerAndThePipelineCostMicrosecondsPerInput() {
        var tracker = AcousticSceneTracker()
        var pipeline = IslandPipeline()
        tracker.process(.sessionStarted(at: T.origin))
        _ = pipeline.process(.sessionStarted(at: T.origin))
        let kinds = ["music", "speech", "road_vehicle", "rain", "bird", "appliance", "vehicle_horn", "crowd", "dog", "door"]
        var updates: [AcousticEventUpdate] = []
        var time = 1.0
        for index in 0 ..< 5_000 {
            var event = SyntheticSoundEvent(kindID: kinds[index % kinds.count], number: index + 1, start: T.date(time), confirmDelay: 0)
            updates.append(event.started())
            updates.append(event.updated(at: T.date(time + 2)))
            updates.append(event.ended(at: T.date(time + 3)))
            time += 3.5
        }
        let clock = ContinuousClock()
        let sceneTime = clock.measure { for update in updates { tracker.process(.sound(update)) } }
        let islandTime = clock.measure { for update in updates { _ = pipeline.process(.sound(update)) } }
        func microseconds(_ duration: Duration) -> Double {
            (Double(duration.components.seconds) * 1e6 + Double(duration.components.attoseconds) / 1e12) / Double(updates.count)
        }
        print("Window 7 cost per input (debug build, this Mac): scene tracker \(microseconds(sceneTime).formatted(.number.precision(.fractionLength(1)))) µs, "
            + "island pipeline \(microseconds(islandTime).formatted(.number.precision(.fractionLength(1)))) µs, \(updates.count) inputs")
        #expect(microseconds(sceneTime) < 2_000)
        #expect(microseconds(islandTime) < 2_000)
    }
}
