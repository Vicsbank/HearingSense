import AttentionReplay
import Foundation
import HearingSenseDomain
import SoundEventDetection
import Testing
@testable import Attention

@Suite struct AttentionPolicyTests {
    @Test func everySoundKindOfTheTaxonomyHasAPolicyRow() {
        let configuration = AttentionConfiguration.standard
        for definition in SoundTaxonomy.appleV1.definitions + [SoundTaxonomy.appleV1.unmappedKind] where definition.producesEvents {
            let assignment = configuration.kinds[definition.kind.id]
            #expect(assignment != nil, "no attention policy for \(definition.kind.id)")
            if let assignment { #expect(configuration.profiles[assignment.profile] != nil) }
        }
        // And no row for a kind that does not exist.
        let known = Set(SoundTaxonomy.appleV1.definitions.map(\.kind.id) + ["unmapped"])
        #expect(Set(configuration.kinds.keys).subtracting(known).isEmpty)
    }

    @Test func basePrioritiesFollowTheBrief() {
        let configuration = AttentionConfiguration.standard
        func base(_ kind: String) -> [AttentionPriority] {
            let profile = configuration.profile(for: SyntheticSound.kind(kind))
            return AttentionMode.allCases.map { profile.base[$0] }
        }
        #expect(base("rain") == [.ambient, .ambient, .low])
        #expect(base("wind") == [.ambient, .ambient, .low])
        #expect(base("music") == [.ambient, .ambient, .ambient])
        #expect(base("dog") == [.ambient, .low, .normal])  // Balanced: conditional
        #expect(configuration.profile(for: SyntheticSound.kind("dog")).conditional[.balanced])
        #expect(base("door") == [.normal, .high, .high])
        #expect(base("vehicle_horn") == [.high, .high, .high])
        #expect(base("siren") == [.urgent, .urgent, .urgent])
        #expect(base("glass_breaking") == [.high, .high, .high])
    }

    @Test func aKindFromAFutureTaxonomyIsTrackedButAmbient() {
        var driver = EngineDriver(mode: .sensitive)
        let unknown = SoundEventKind(id: "hovercraft", displayName: "Hovercraft", category: .transportation)
        #expect(driver.engine.configuration.assignment(for: unknown).category == .transportation)
        #expect(driver.start("hovercraft", at: 0).decisions.map(\.action) == [.suppress])
    }

    @Test func configurationRoundTripsAsData() throws {
        let data = try JSONEncoder().encode(AttentionConfiguration.standard)
        #expect(try JSONDecoder().decode(AttentionConfiguration.self, from: data) == AttentionConfiguration.standard)
    }
}

@Suite struct AttentionPreferencesTests {
    @Test func defaultsAreBalancedAndAutomatic() {
        let preferences = AttentionPreferences.default
        #expect(preferences.mode == .balanced)
        #expect(preferences.speech == .standard)
        #expect(AttentionCategory.allCases.allSatisfy { preferences.setting(for: $0) == .automatic })
        #expect(preferences.isDefault)
    }

    @Test func roundTripsThroughJSON() throws {
        var preferences = AttentionPreferences(mode: .quiet, speech: .importantOnly)
        preferences.set(.muted, for: .animals)
        preferences.set(.high, for: .doorAndKnock)
        preferences.set(.automatic, for: .weather)
        let decoded = try JSONDecoder().decode(AttentionPreferences.self, from: JSONEncoder().encode(preferences))
        #expect(decoded == preferences)
        #expect(decoded.categories.count == 2)
        #expect(!decoded.isDefault)
    }

    @Test func unknownOrMissingValuesFallBackToDefaults() throws {
        let stored = #"{"mode":"loud","categories":{"animals":"muted","spaceships":"high","music":"shiny"},"extra":1}"#
        let decoded = try JSONDecoder().decode(AttentionPreferences.self, from: Data(stored.utf8))
        #expect(decoded.mode == .balanced)
        #expect(decoded.speech == .standard)
        #expect(decoded.categories == [.animals: .muted])
        #expect(try JSONDecoder().decode(AttentionPreferences.self, from: Data("{}".utf8)) == .default)
    }
}

@Suite struct AttentionPriorityTests {
    @Test func confidenceIsNotImportance() {
        // Strongly classified rain stays ambient; a weakly classified horn is still high.
        var driver = EngineDriver(mode: .balanced)
        let rain = driver.start("rain", at: 0, quality: .strong).decisions
        #expect(rain.map(\.action) == [.suppress])
        #expect(rain[0].event.priority == .ambient)
        let horn = driver.start("vehicle_horn", at: 10, quality: .weak).decisions
        #expect(horn.map(\.action) == [.show])
        #expect(horn[0].event.priority == .high)
        #expect(horn[0].reasons.contains(.weakEvidence))
        #expect(horn[0].event.isUncertain)
    }

    @Test func urgentNeedsMoreThanWeakEvidenceAndRisesWhenItArrives() {
        var driver = EngineDriver(mode: .balanced)
        var (siren, first) = driver.start("siren", at: 0, quality: .weak)
        #expect(first.map(\.action) == [.show])
        #expect(first[0].event.priority == .high)
        let later = driver.send(.sound(siren.updated(at: EngineDriver.date(4), quality: .strong)))
        #expect(later.map(\.action) == [.update])
        #expect(later[0].event.priority == .urgent)
        #expect(later[0].reasons.contains(.escalated))
        #expect(later[0].intent?.interruption == .timeSensitive)
        #expect(later[0].event.id == first[0].event.id)
    }

    @Test func everyDecisionHasReasonCodes() {
        for scenario in ScenarioLibrary.all {
            for decision in run(scenario, .balanced).decisions {
                #expect(!decision.decision.reasons.isEmpty, "\(scenario.id): \(decision.decision.summary)")
            }
        }
    }

    @Test func conditionalDogWaitsForSustainedEvidence() {
        var driver = EngineDriver(mode: .balanced)
        var (dog, first) = driver.start("dog", at: 0, quality: .moderate)
        #expect(first.map(\.action) == [.defer])
        #expect(first[0].reasons.contains(.conditionPending))
        #expect(first[0].intent == nil)
        let sustained = driver.send(.sound(dog.updated(at: EngineDriver.date(5))))
        #expect(sustained.map(\.action) == [.show])
        #expect(sustained[0].event.priority == .normal)
        #expect(sustained[0].reasons.contains(.conditionMet))
    }

    @Test func aBriefConditionalSoundIsDroppedSilently() {
        var driver = EngineDriver(mode: .balanced)
        var (dog, _) = driver.start("dog", at: 0, quality: .moderate)
        let ended = driver.send(.sound(dog.ended(at: EngineDriver.date(3.6))))
        #expect(ended.map(\.action) == [.expire])
        #expect(ended[0].reasons == [.deferredExpired, .sourceEnded])
        #expect(ended[0].intent == nil)
        #expect(driver.shows.isEmpty)
        #expect(driver.engine.snapshot.tracked.isEmpty)
    }

    @Test func minorSoundsStayAmbientInEveryMode() {
        for mode in AttentionMode.allCases {
            var driver = EngineDriver(mode: mode)
            for kind in ["small_objects", "typing_writing", "body_sounds", "insect", "clock", "mic_wind_noise"] {
                let decisions = driver.start(kind, at: 0).decisions
                #expect(decisions.map(\.action) == [.suppress])
                #expect(decisions[0].reasons == [.minorSound, .lowRelevance])
            }
        }
    }

    @Test func repeatedKnocksEscalateInQuiet() {
        var driver = EngineDriver(mode: .quiet)
        #expect(driver.brief("door", at: 0).first?.event.priority == .normal)
        let second = driver.brief("door", at: 8)
        #expect(second.first?.action == .update)
        #expect(second.first?.event.priority == .normal)
        let third = driver.brief("door", at: 16)
        #expect(third.first?.action == .update)
        #expect(third.first?.event.priority == .high)
        #expect(third.first?.reasons.contains(.repeatedEvent) == true)
        #expect(third.first?.reasons.contains(.escalated) == true)
        #expect(third.first?.intent?.interruption == .active)
        #expect(third.first?.event.subtitle == "Repeated 3 times")
        #expect(driver.shows.count == 1)
    }
}

@Suite struct AttentionCooldownTests {
    @Test func aSecondDogWithinTheCooldownIsSuppressedAndALaterOneIsShown() {
        var driver = EngineDriver(mode: .sensitive)  // dog: normal, cooldown 120 s × 0.5
        #expect(driver.brief("dog", at: 0).first?.action == .show)
        driver.advance(to: 30)
        let second = driver.brief("dog", at: 30)
        #expect(second.first?.action == .suppress)
        #expect(second.first?.reasons.contains(.cooldownActive) == true)
        #expect(driver.engine.snapshot.cooldowns.map(\.id) == ["dog"])
        driver.advance(to: 90)
        #expect(driver.brief("dog", at: 90).first?.action == .show)
    }

    @Test func aSoundThatBeganDuringItsCooldownDoesNotPopUpWhenTheCooldownEnds() {
        var driver = EngineDriver(mode: .sensitive)
        driver.brief("dog", at: 0)
        driver.advance(to: 30)
        var (dog, first) = driver.start("dog", at: 30)
        #expect(first.map(\.action) == [.suppress])
        // Still barking after the cooldown (60 s) has passed.
        for time in stride(from: 36.0, through: 81, by: 5) {
            let later = driver.send(.sound(dog.updated(at: EngineDriver.date(time))))
            #expect(later.map(\.action) == [.suppress])
        }
        #expect(driver.shows.count == 1)
    }

    @Test func cooldownsAreScaledByTheMode() {
        func secondDog(_ mode: AttentionMode, after seconds: TimeInterval) -> AttentionAction? {
            var preferences = AttentionPreferences(mode: mode)
            preferences.set(.normal, for: .animals)  // shown in every mode
            var driver = EngineDriver(preferences: preferences)
            driver.brief("dog", at: 0)
            driver.advance(to: seconds)
            return driver.brief("dog", at: seconds).first?.action
        }
        #expect(secondDog(.sensitive, after: 100) == .show)   // 60 s
        #expect(secondDog(.balanced, after: 100) == .suppress) // 120 s
        #expect(secondDog(.balanced, after: 130) == .show)
        #expect(secondDog(.quiet, after: 130) == .suppress)    // 240 s
    }

    @Test func aWarningSignalIsShownAgainAsSoonAsItIsANewOccurrence() {
        var driver = EngineDriver(mode: .balanced)
        driver.brief("vehicle_horn", at: 0)
        driver.advance(to: 30)
        let second = driver.brief("vehicle_horn", at: 30)
        #expect(second.first?.action == .show)
        #expect(second.first?.event.id != driver.shows.first?.event.id)
    }

    @Test func thePresentationBudgetDefersOrdinaryEventsOnly() {
        var preferences = AttentionPreferences(mode: .quiet)  // budget: 2 per minute
        preferences.set(.normal, for: .animals)
        preferences.set(.normal, for: .household)
        preferences.set(.normal, for: .transportation)
        var driver = EngineDriver(preferences: preferences)
        #expect(driver.start("dog", at: 0).decisions.map(\.action) == [.show])
        #expect(driver.start("kitchen", at: 1).decisions.map(\.action) == [.show])
        let third = driver.start("aircraft", at: 2).decisions
        #expect(third.map(\.action) == [.defer])
        #expect(third[0].reasons.contains(.rateLimited))
        #expect(driver.engine.snapshot.budgetUsed == 2)
        #expect(driver.engine.snapshot.deferred.count == 1)
        // A horn is not held back.
        let horn = driver.start("vehicle_horn", at: 3).decisions
        #expect(horn.map(\.action) == [.show])
        #expect(horn[0].reasons.contains(.rateLimitBypassed))
        // The deferred one is dropped when it has waited too long (15 s).
        let waited = driver.advance(to: 20)
        #expect(waited.contains { $0.action == .expire && $0.reasons.contains(.deferredExpired) })
    }

    @Test func aDeferredEventIsShownWhenTheBudgetFrees() {
        var configuration = AttentionConfiguration.standard
        configuration.tuning.quiet.budgetWindow = 10
        var preferences = AttentionPreferences(mode: .quiet)
        preferences.set(.normal, for: .animals)
        preferences.set(.normal, for: .household)
        preferences.set(.normal, for: .transportation)
        var driver = EngineDriver(preferences: preferences, configuration: configuration)
        driver.start("dog", at: 0)
        driver.start("kitchen", at: 1)
        var (aircraft, deferred) = driver.start("aircraft", at: 2)
        #expect(deferred.map(\.action) == [.defer])
        driver.send(.sound(aircraft.updated(at: EngineDriver.date(8))))
        let released = driver.advance(to: 12).filter { $0.event.kindID == "aircraft" }
        #expect(released.map(\.action) == [.show])
        #expect(released[0].reasons.contains(.deferredReleased))
        #expect(released[0].decidedAt == EngineDriver.date(11.6))  // first show (1.6 s) + 10 s window
    }
}

@Suite struct AttentionSpeechTests {
    @Test func urgentPhraseRules() {
        let policy = SpeechAttentionPolicy.standard
        #expect(SpeechAssessment.containsUrgentPhrase("Watch out!", policy: policy))
        #expect(SpeechAssessment.containsUrgentPhrase("hey look out behind you", policy: policy))
        #expect(SpeechAssessment.containsUrgentPhrase("Stop!", policy: policy))
        #expect(SpeechAssessment.containsUrgentPhrase("Help me", policy: policy))
        // Common words inside ordinary sentences do not count.
        #expect(!SpeechAssessment.containsUrgentPhrase("I run every morning before school", policy: policy))
        #expect(!SpeechAssessment.containsUrgentPhrase("can you help me with my homework", policy: policy))
        #expect(!SpeechAssessment.containsUrgentPhrase("we watched outside", policy: policy))
        #expect(!SpeechAssessment.containsUrgentPhrase("", policy: policy))
    }

    @Test func semanticSignaturesSeparateRewordingFromReversal() {
        func change(_ old: String, _ new: String) -> SemanticSignature.Change {
            SemanticSignature(text: old, isNegated: false).change(to: SemanticSignature(text: new, isNegated: false),
                                                                  sameMeaningSimilarity: 0.8)
        }
        #expect(change("Package Arrived", "The package has arrived.") == .cosmetic)
        #expect(change("Package Has Not Arrived", "The Package Hasn’t Arrived") == .cosmetic)
        #expect(change("Has not arrived", "Has now arrived") == .critical(negation: true))
        #expect(change("Don't open the door", "Open the door") == .critical(negation: true))
        #expect(change("Meeting at three", "Meeting at four") == .critical(negation: false))
        #expect(change("Test tomorrow", "Test today") == .critical(negation: false))
        #expect(change("Biology test tomorrow", "Biology exam tomorrow") == .refined)
        #expect(change("Dinner is ready", "Bus is late") == .refined)
    }

    @Test func watchOutIsHighInEveryModeAndDoesNotClaimAnAddressee() {
        for mode in AttentionMode.allCases {
            var driver = EngineDriver(mode: mode)
            var speech = driver.speech(at: 0)
            driver.send(.speech(speech.detected(at: EngineDriver.date(0))))
            let decisions = driver.send(.speech(speech.final("Watch out!", at: EngineDriver.date(1.5))))
            let decision = decisions.last!
            #expect(decision.event.priority == .high)
            #expect(decision.event.title == "Possible Spoken Warning")
            #expect(decision.event.isUncertain)  // a phrase match alone
            #expect(decision.reasons.contains(.urgentPhrase))
            #expect(decision.intent?.interruption == .active)
        }
    }

    @Test func aNegatedKeywordIsNotAWarning() {
        var driver = EngineDriver(mode: .balanced)
        var speech = driver.speech(at: 0)
        driver.send(.speech(speech.detected(at: EngineDriver.date(0))))
        let decisions = driver.send(.speech(speech.final("don't worry there is no emergency", at: EngineDriver.date(3),
                                                         isNegated: true)))
        #expect(decisions.last?.event.priority == .normal)
        #expect(decisions.last?.reasons.contains(.negatedStatement) == true)
    }

    @Test func laterOrdinarySentencesDoNotLowerAWarning() {
        var driver = EngineDriver(mode: .balanced)
        var speech = driver.speech(at: 0)
        driver.send(.speech(speech.detected(at: EngineDriver.date(0))))
        driver.send(.speech(speech.final("watch out", at: EngineDriver.date(1.5), category: .warning)))
        let later = driver.send(.speech(speech.final("okay that was close", at: EngineDriver.date(6),
                                                     category: .casualConversation)))
        #expect(later.allSatisfy { $0.event.priority == .high })
        #expect(driver.engine.snapshot.presented.first?.priority == .high)
        #expect(driver.engine.snapshot.presented.first?.title == "Possible Spoken Warning")
    }

    @Test func partialTranscriptsCauseNoDecisions() {
        var driver = EngineDriver(mode: .sensitive)
        var speech = driver.speech(at: 0)
        #expect(driver.send(.speech(speech.detected(at: EngineDriver.date(0)))).map(\.action) == [.show])
        for (index, text) in ["we", "we have", "we have a", "we have a biology", "we have a biology test"].enumerated() {
            #expect(driver.send(.speech(speech.partial(text, at: EngineDriver.date(1 + Double(index) * 0.2)))).isEmpty)
        }
        // The first partial changes the state (detected → transcribing); the rest change nothing.
        #expect(driver.engine.statistics.speechProgressIgnored == 4)
    }

    @Test func speechAttentionSettings() {
        func alerts(_ setting: SpeechAttention, mode: AttentionMode, warning: Bool) -> Int {
            var driver = EngineDriver(preferences: AttentionPreferences(mode: mode, speech: setting))
            var speech = driver.speech(at: 0)
            driver.send(.speech(speech.detected(at: EngineDriver.date(0))))
            driver.send(.speech(speech.final(warning ? "look out" : "nice weather today", at: EngineDriver.date(3),
                                             category: warning ? .warning : .casualConversation)))
            driver.advance(to: 10)
            return driver.shows.count
        }
        #expect(alerts(.off, mode: .sensitive, warning: true) == 0)
        #expect(alerts(.importantOnly, mode: .sensitive, warning: false) == 0)
        #expect(alerts(.importantOnly, mode: .quiet, warning: true) == 1)
        #expect(alerts(.standard, mode: .quiet, warning: false) == 0)
        #expect(alerts(.standard, mode: .balanced, warning: false) == 1)
        #expect(alerts(.everything, mode: .quiet, warning: false) == 1)
    }

    @Test func ordinarySpeechHasACooldownButAWarningIgnoresIt() {
        var driver = EngineDriver(mode: .sensitive)  // speech cooldown 90 s × 0.5
        var first = driver.speech(at: 0)
        driver.send(.speech(first.detected(at: EngineDriver.date(0))))
        driver.send(.speech(first.completed(at: EngineDriver.date(5))))
        driver.advance(to: 20)
        var second = driver.speech(at: 20)
        let again = driver.send(.speech(second.detected(at: EngineDriver.date(20))))
        #expect(again.map(\.action) == [.suppress])
        #expect(again[0].reasons.contains(.cooldownActive))
        // The same conversation turns into a warning: shown although speech is cooling down.
        let warning = driver.send(.speech(second.final("look out", at: EngineDriver.date(22), category: .warning)))
        #expect(warning.last?.action == .show)
        #expect(warning.last?.event.priority == .high)
    }

    @Test func aWarningAfterThePresentationTimedOutIsANewEpisode() throws {
        var driver = EngineDriver(mode: .sensitive)
        var speech = driver.speech(at: 0)
        let first = try #require(driver.send(.speech(speech.detected(at: EngineDriver.date(0)))).first)
        #expect(first.action == .show)
        // A long conversation: keep it alive with new sentences; its presentation lasts 30 s.
        for time in stride(from: 5.0, through: 45, by: 5) {
            driver.advance(to: time)
            driver.send(.speech(speech.final("sentence at \(Int(time))", at: EngineDriver.date(time), category: .casualConversation)))
        }
        #expect(driver.decisions.contains { $0.action == .expire && $0.reasons == [.presentationTimeout] })
        driver.advance(to: 50)
        let warning = try #require(driver.send(.speech(speech.final("watch out", at: EngineDriver.date(50), category: .warning))).last)
        #expect(warning.action == .show)
        #expect(warning.event.id != first.event.id)
        #expect(warning.event.priority == .high)
        #expect(warning.reasons.contains(.escalated))
    }

    @Test func speechDuringMusicWaitsForTheRelevanceEstimate() {
        var driver = EngineDriver(mode: .sensitive)
        driver.start("music", at: 0)
        var speech = driver.speech(at: 10)
        let detected = driver.send(.speech(speech.detected(at: EngineDriver.date(10))))
        #expect(detected.map(\.action) == [.suppress])
        #expect(detected[0].reasons.contains(.musicAmbiguity))
        // The pipeline decides it is someone talking over the music.
        let spoken = driver.send(.speech(speech.final("dinner is ready", at: EngineDriver.date(13),
                                                      category: .announcement, relevance: .speechOverMusic)))
        #expect(spoken.map(\.action) == [.show])
        #expect(spoken[0].event.isUncertain)
        #expect(spoken[0].reasons.contains(.musicAmbiguity))
    }

    @Test func speechReportedJustBeforeTheKnockIsConfirmedStillJoinsIt() throws {
        // Knock begins at 1.0 s and is confirmed at 2.6 s; speech is first reported at 2.0 s.
        var driver = EngineDriver(mode: .sensitive)
        var speech = driver.speech(at: 2)
        let alone = driver.send(.speech(speech.detected(at: EngineDriver.date(2))))
        #expect(alone.map(\.action) == [.show])
        let knock = driver.start("door", at: 1).decisions
        #expect(knock.map(\.action) == [.expire, .show])
        #expect(knock[0].reasons == [.temporalFusion, .mergedIntoEpisode])
        #expect(knock[0].intent?.action == .dismiss)
        #expect(knock[1].event.isFused)
        #expect(knock[1].event.subtitle == "Nearby speech afterwards")
        #expect(driver.engine.snapshot.presented.count == 1)
        // The summary that arrives later goes to the merged episode.
        let summary = try #require(driver.send(.speech(speech.summary("Package Arrived", at: EngineDriver.date(6),
                                                                      category: .announcement))).first)
        #expect(summary.event.id == knock[1].event.id)
        #expect(summary.intent?.privateDetail == "Package Arrived")
    }

    @Test func speechLongAfterAKnockIsItsOwnEpisode() {
        var driver = EngineDriver(mode: .sensitive)
        driver.brief("door", at: 0)
        driver.advance(to: 15)  // more than the 8 s fusion window after the knock was last observed
        var speech = driver.speech(at: 15)
        let decisions = driver.send(.speech(speech.detected(at: EngineDriver.date(15))))
        #expect(decisions.map(\.action) == [.show])
        #expect(!decisions[0].event.isFused)
        #expect(driver.engine.statistics.fusions == 0)
    }

    @Test func aWarningAfterAKnockAsksForAttentionAgain() throws {
        var driver = EngineDriver(mode: .balanced)
        let knock = try #require(driver.start("door", at: 0).decisions.first)
        var speech = driver.speech(at: 3)
        driver.send(.speech(speech.detected(at: EngineDriver.date(3))))
        let warning = try #require(driver.send(.speech(speech.final("watch out", at: EngineDriver.date(4.5), category: .warning))).last)
        #expect(warning.action == .update)
        #expect(warning.event.id == knock.event.id)
        #expect(warning.event.priority == .high)
        #expect(warning.intent?.interruption == .active)
        #expect(warning.event.subtitle == "Possible spoken warning afterwards")
    }
}

@Suite struct AttentionStateTests {
    @Test func modeSwitchAppliesToActiveEvents() {
        var driver = EngineDriver(mode: .balanced)
        driver.start("rain", at: 0)
        #expect(driver.engine.snapshot.presented.isEmpty)
        let switched = driver.send(.preferences(AttentionPreferences(mode: .sensitive), at: EngineDriver.date(5)))
        #expect(switched.map(\.action) == [.show])
        #expect(driver.engine.snapshot.mode == .sensitive)
        let back = driver.send(.preferences(AttentionPreferences(mode: .quiet), at: EngineDriver.date(8)))
        #expect(back.map(\.action) == [.suppress])
        #expect(back[0].intent?.action == .dismiss)
        #expect(driver.engine.snapshot.presented.isEmpty)
        // And again: a presentation ended by a preference can return with it.
        let again = driver.send(.preferences(AttentionPreferences(mode: .sensitive), at: EngineDriver.date(10)))
        #expect(again.map(\.action) == [.show])
        #expect(again[0].event.id != switched[0].event.id)
    }

    @Test func snapshotOrdersByPriorityThenRecency() {
        var driver = EngineDriver(mode: .balanced)
        driver.start("door", at: 0)
        driver.start("vehicle_horn", at: 1)
        driver.start("siren", at: 2)
        driver.start("phone", at: 3)
        #expect(driver.engine.snapshot.presented.map(\.kindID) == ["siren", "vehicle_horn", "door", "phone"])
        #expect(driver.engine.snapshot.presented.map(\.priority) == [.urgent, .high, .high, .normal])
    }

    @Test func stateIsBounded() {
        var configuration = AttentionConfiguration.standard
        configuration.maximumEpisodes = 5
        var driver = EngineDriver(mode: .sensitive, configuration: configuration)
        for (index, kind) in SyntheticSound.allKindIDs.enumerated() {
            driver.start(kind, at: Double(index) * 0.1)
            #expect(driver.engine.snapshot.presented.count + driver.engine.snapshot.tracked.count <= 5)
        }
        #expect(driver.engine.statistics.evictions > 0)
        #expect(driver.engine.statistics.maximumEpisodes <= 6)  // one over the limit only inside a single input
        // The most important ones survive.
        #expect(driver.engine.snapshot.presented.contains { $0.kindID == "siren" })

        // Sources of one episode are bounded too.
        var horns = EngineDriver(mode: .balanced)
        for index in 0..<40 { horns.brief("vehicle_horn", at: Double(index) * 5) }
        #expect(horns.shows.count == 1)
        let episode = horns.engine.snapshot.presented.first
        #expect(episode?.occurrences == 40)
        #expect((episode?.sources.count ?? 99) <= AttentionConfiguration.standard.maximumSourcesPerEpisode)
    }

    @Test func deadlinesDriveExpirationWithoutPolling() {
        var driver = EngineDriver(mode: .balanced)
        #expect(driver.engine.nextDeadline == nil)
        var (horn, _) = driver.start("vehicle_horn", at: 0)
        // Next thing that can happen by itself: the source going stale (20 s) or the presentation ending (45 s).
        #expect(driver.engine.nextDeadline == EngineDriver.date(1.6 + 20))
        driver.send(.sound(horn.ended(at: EngineDriver.date(3.6))))
        #expect(driver.engine.nextDeadline == EngineDriver.date(3.6 + 8))  // resolved: linger
        let expired = driver.send(.tick(at: EngineDriver.date(11.6)))
        #expect(expired.map(\.action) == [.expire])
        #expect(driver.engine.nextDeadline == nil)
        #expect(driver.engine.snapshot.presented.isEmpty && driver.engine.snapshot.tracked.isEmpty)
    }

    @Test func intentsCarryWhatWindow5Needs() throws {
        let result = run(ScenarioLibrary.modeComparison, .balanced)
        var lastRevision: [AttentionEventID: Int] = [:]
        var finished: Set<AttentionEventID> = []
        for intent in result.intents {
            #expect(!intent.title.isEmpty)
            #expect(!intent.symbolName.isEmpty)
            #expect(!intent.reasons.isEmpty)
            #expect(intent.expiresAt != nil)
            #expect(intent.timestamp >= result.scenario.start)
            #expect(intent.revision >= lastRevision[intent.id, default: 0])
            lastRevision[intent.id] = intent.revision
            if lastRevision.count > 0, intent.action == .present { #expect(!finished.contains(intent.id)) }
            #expect(!finished.contains(intent.id), "intent after the final dismissal of \(intent.id)")
            if intent.action == .dismiss, let expires = intent.expiresAt, expires <= intent.timestamp { finished.insert(intent.id) }
        }
        let first = try #require(result.intents.first { $0.action == .present })
        #expect(first.expiresAt! > first.timestamp)
    }

    @Test func privateTextIsNeverEncoded() throws {
        let result = run(ScenarioLibrary.knockFollowedBySpeech, .balanced)
        let withPrivate = try #require(result.decisions.map(\.decision).last { $0.event.privateContent != nil })
        #expect(withPrivate.intent?.privateDetail == "Package Arrived")
        let encoder = JSONEncoder()
        for data in [try encoder.encode(withPrivate), try encoder.encode(withPrivate.event), try encoder.encode(withPrivate.intent)] {
            let text = String(decoding: data, as: UTF8.self)
            #expect(!text.contains("Package"))
            #expect(!text.contains("Arrived"))
        }
        #expect(!withPrivate.summary.contains("Package"))
        // Decoding gives an event without private text and says that there was some.
        let decoded = try JSONDecoder().decode(AttentionPresentationIntent.self, from: encoder.encode(withPrivate.intent))
        #expect(decoded.privateDetail == nil)
        #expect(decoded.hasPrivateDetail)
    }

    @Test func outOfOrderAndUnknownInputsAreHarmless() {
        var driver = EngineDriver(mode: .balanced)
        var (horn, _) = driver.start("vehicle_horn", at: 10)
        // An end for an event the engine never saw, and a terminal speech result it never saw.
        var stranger = driver.sound("dog", at: 0)
        #expect(driver.send(.sound(stranger.ended(at: EngineDriver.date(2)))).isEmpty)
        var speech = driver.speech(at: 0)
        #expect(driver.send(.speech(speech.completed(at: EngineDriver.date(1)))).isEmpty)
        // An input stamped earlier than the clock does not move time backwards.
        let late = driver.send(.sound(horn.ended(at: EngineDriver.date(5))))
        #expect(late.map(\.action) == [.resolve])
        #expect(late[0].decidedAt == EngineDriver.date(11.6))
        // The same start twice is one event.
        let again = driver.start("siren", at: 20)
        #expect(driver.send(.sound(again.event.started())).map(\.action) == [.suppress])
    }

    @Test func switchingTranscriptionOffDropsSpeechAndItsText() throws {
        var driver = EngineDriver(mode: .sensitive)
        // A knock with speech attached, and a separate speech episode with a summary.
        driver.start("door", at: 0)
        var attached = driver.speech(at: 3)
        driver.send(.speech(attached.detected(at: EngineDriver.date(3))))
        driver.send(.speech(attached.summary("Package Arrived", at: EngineDriver.date(6), category: .announcement)))
        #expect(driver.engine.snapshot.presented.first?.privateContent?.text == "Package Arrived")
        driver.advance(to: 20)
        var alone = driver.speech(at: 20)
        driver.send(.speech(alone.detected(at: EngineDriver.date(20))))
        driver.send(.speech(alone.summary("Dinner Is Ready", at: EngineDriver.date(24), category: .announcement)))
        #expect(driver.engine.snapshot.presented.count == 2)

        let cleared = driver.send(.speechDataCleared(at: EngineDriver.date(25)))
        // The knock stays, without the speech; the speech episode is dismissed.
        let knock = try #require(driver.engine.snapshot.presented.first)
        #expect(driver.engine.snapshot.presented.count == 1)
        #expect(knock.kindID == "door")
        #expect(knock.subtitle == nil)
        #expect(knock.privateContent == nil)
        #expect(!knock.isFused)
        #expect(cleared.contains { $0.action == .expire && $0.reasons == [.speechDataCleared] && $0.intent?.action == .dismiss })
        #expect(cleared.allSatisfy { $0.intent?.privateDetail == nil || $0.action == .expire })
        // Later results of the discarded conversations start nothing they should not.
        #expect(driver.send(.speech(alone.completed(at: EngineDriver.date(26)))).isEmpty)
    }

    @Test func playbackMovesAScenarioInTimeWithFreshIdentifiers() {
        let scenario = ScenarioLibrary.knockFollowedBySpeech
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let first = scenario.playback(startingAt: start)
        let second = scenario.playback(startingAt: start)
        #expect(first.count == scenario.steps.count)
        #expect(first.map(\.offset) == scenario.steps.map { $0.input.date.timeIntervalSince(scenario.start) })
        #expect(zip(first, scenario.steps).allSatisfy { abs($0.input.date.timeIntervalSince(start) - $0.offset) < 0.001 && $1.sourceKey != nil })
        func soundIDs(_ inputs: [AttentionScenario.TimedInput]) -> Set<AcousticEventID> {
            Set(inputs.compactMap { if case .sound(let update) = $0.input { update.event.id } else { nil } })
        }
        #expect(soundIDs(first).count == 1)
        #expect(soundIDs(first).isDisjoint(with: soundIDs(second)))
        // Played into an engine it behaves like the original.
        var engine = AttentionEngine()
        let actions = first.flatMap { engine.process($0.input) }.map(\.action)
        #expect(actions == [.show, .update, .update, .resolve])
        // Preference and session steps are never played back into a user's engine.
        #expect(ScenarioLibrary.preferenceChanges.playback(startingAt: start).allSatisfy {
            if case .preferences = $0.input { false } else { true }
        })
    }

    @Test func sessionEndDismissesEverything() {
        var driver = EngineDriver(mode: .balanced)
        driver.start("siren", at: 0)
        driver.start("door", at: 1)
        let ended = driver.send(.sessionEnded(at: EngineDriver.date(5)))
        #expect(ended.map(\.action) == [.expire, .expire])
        #expect(ended.allSatisfy { $0.reasons == [.sessionEnded] && $0.intent?.action == .dismiss })
        #expect(driver.engine.snapshot.presented.isEmpty)
        #expect(driver.engine.nextDeadline == nil)
    }
}
