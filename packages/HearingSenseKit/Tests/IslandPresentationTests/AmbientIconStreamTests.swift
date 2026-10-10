import AttentionReplay
import Foundation
import HearingSenseDomain
import IslandPresentation
import Testing

@Suite struct AmbientIconStreamTests {
    @Test func aConfirmedSoundBecomesAnIconWithoutText() {
        var driver = AmbientDriver()
        driver.send(sound("rain", 1, at: 2).started())
        #expect(driver.stream.current?.symbolName == "cloud.rain")
        #expect(driver.stream.current?.kindID == "rain")
        #expect(driver.timeline == ["2:cloud.rain"])
    }

    @Test func weakEvidenceGetsNoIconUntilItImproves() {
        var driver = AmbientDriver()
        var dog = sound("dog", 1, at: 0, quality: .weak)
        driver.send(dog.started())
        #expect(driver.stream.current == nil)
        driver.send(dog.updated(at: T.date(5), quality: .moderate))
        #expect(driver.stream.current?.symbolName == "dog")

        var never = AmbientDriver()
        var click = sound("small_objects", 2, at: 0, quality: .weak)
        never.send(click.started())
        never.send(click.ended(at: T.date(2)))
        never.advance(to: 30)
        #expect(never.changes.isEmpty)
        #expect(never.stream.statistics.belowQuality == 1)
        #expect(never.stream.trackedCount == 0)
    }

    @Test func aShownIconStaysForTheMinimumDisplayTime() {
        var driver = AmbientDriver()
        driver.send(sound("rain", 1, at: 0).started())
        driver.send(sound("dog", 2, at: 1).started())  // newer, but rain was shown 1 s ago
        #expect(driver.stream.current?.symbolName == "cloud.rain")
        driver.advance(to: 1.9)
        #expect(driver.stream.current?.symbolName == "cloud.rain")
        driver.advance(to: 10)
        #expect(driver.timeline == ["0:cloud.rain", "2:dog"])
    }

    /// The student's observation on the iPhone: with speech going on, a strong sneeze did not
    /// appear. The newest sound takes the icon whatever its rank, and the one that keeps going
    /// comes back.
    @Test func aNewSoundShowsAtOnceAndTheOneThatKeepsGoingComesBack() {
        var driver = AmbientDriver()
        var speech = sound("speech", 1, at: 0)
        driver.send(speech.started())
        driver.send(speech.updated(at: T.date(20)))
        var sneeze = sound("body_sounds", 2, at: 21)  // rank 15 against 80
        driver.send(sneeze.started())
        #expect(driver.stream.current?.kindID == "body_sounds")
        driver.send(sneeze.ended(at: T.date(22.5)))
        driver.send(speech.updated(at: T.date(25)))
        driver.advance(to: 30)
        #expect(driver.timeline == ["0:person.wave.2", "21:lungs", "26:person.wave.2"])
    }

    @Test func aLowerRankedNewSoundShowsFirstThenTheHigherRankedOneReturns() {
        var driver = AmbientDriver()
        var rain = sound("rain", 1, at: 0)
        driver.send(rain.started())
        var music = sound("music", 2, at: 10)
        driver.send(music.started())
        driver.send(rain.updated(at: T.date(15)))
        driver.send(music.updated(at: T.date(15)))
        driver.advance(to: 18)
        #expect(driver.timeline == ["0:cloud.rain", "10:music.note", "15:cloud.rain"])
        // When the rain is over (and lingered) the music that is still playing takes its place.
        driver.send(rain.ended(at: T.date(20)))
        driver.send(music.updated(at: T.date(22)))
        driver.advance(to: 26)
        #expect(driver.timeline == ["0:cloud.rain", "10:music.note", "15:cloud.rain", "25:music.note"])
    }

    /// Seen on the iPhone: a drawer that had closed 5 s earlier appeared for 4 s when the speech
    /// icon above it went away.
    @Test func aSoundThatIsOverDoesNotAppearLate() {
        var policy = AmbientIconPolicy.standard
        policy.minimumDisplay = 8  // the drawer cannot take the icon while it is fresh
        var driver = AmbientDriver(policy: policy)
        var speech = sound("speech", 1, at: 0)
        driver.send(speech.started())
        var drawer = sound("small_objects", 2, at: 1)
        driver.send(drawer.started())
        driver.send(drawer.ended(at: T.date(4)))
        driver.send(speech.ended(at: T.date(4.5)))
        driver.advance(to: 30)
        // Speech lingered until 9.5; the drawer (ended, lower rank) is not shown after it.
        #expect(driver.timeline == ["0:person.wave.2", "14.5:-"])
    }

    @Test func aBriefSoundLingersThenTheIconGoesAfterTheIdleHold() {
        var driver = AmbientDriver()
        var knock = sound("door", 1, at: 0)
        driver.send(knock.started())
        driver.send(knock.ended(at: T.date(2)))
        driver.advance(to: 11.9)
        #expect(driver.stream.current?.symbolName == "door.left.hand.closed")
        driver.advance(to: 12)
        #expect(driver.timeline == ["0:door.left.hand.closed", "12:-"])
        #expect(driver.stream.nextDeadline == nil)
    }

    /// Seen on the iPhone: icon → plain glyph → icon within 2–6 s, again and again.
    @Test func aSoundDuringTheIdleHoldReplacesTheIconDirectly() {
        var driver = AmbientDriver()
        var knock = sound("door", 1, at: 0)
        driver.send(knock.started())
        driver.send(knock.ended(at: T.date(2)))
        driver.send(sound("dog", 2, at: 9).started())  // the knock's linger is over, the hold is not
        driver.advance(to: 15)
        #expect(driver.timeline == ["0:door.left.hand.closed", "9:dog"])
    }

    @Test func aSoundThatComesBackKeepsItsIconWithoutAChange() {
        var driver = AmbientDriver()
        var first = sound("dog", 1, at: 0)
        driver.send(first.started())
        driver.send(first.ended(at: T.date(3)))
        var second = sound("dog", 2, at: 5)  // inside the linger of the first
        driver.send(second.started())
        driver.advance(to: 12)
        #expect(driver.timeline == ["0:dog"])
        driver.send(second.ended(at: T.date(13)))
        driver.advance(to: 25)
        #expect(driver.timeline == ["0:dog", "23:-"])
    }

    @Test func changesAreLimitedPerMinute() {
        var policy = AmbientIconPolicy.standard
        policy.minimumDisplay = 0
        policy.linger = 0
        policy.idleHold = 0
        policy.maximumChangesPerMinute = 4
        var driver = AmbientDriver(policy: policy)
        // Twenty brief sounds of alternating kinds within 40 s.
        for index in 0 ..< 20 {
            var event = sound(index.isMultiple(of: 2) ? "dog" : "bird", index + 1, at: Double(index) * 2)
            driver.send(event.started())
            driver.send(event.ended(at: T.date(Double(index) * 2 + 1)))
        }
        driver.advance(to: 40)
        #expect(driver.changes.count == 4)
        #expect(driver.stream.statistics.heldBack > 0)
        // The limit is a sliding minute: later changes are possible again.
        driver.advance(to: 200)
        #expect(driver.stream.current == nil)
    }

    @Test func anEventWithoutUpdatesIsDroppedAsStale() {
        var driver = AmbientDriver()
        driver.send(sound("wind", 1, at: 0).started())
        driver.advance(to: 19.9)
        #expect(driver.stream.current?.symbolName == "wind")
        driver.advance(to: 20)
        #expect(driver.stream.statistics.staleEvents == 1)
        driver.advance(to: 25)
        #expect(driver.stream.current == nil)
    }

    @Test func microphoneWindNoiseNeverGetsAnIcon() {
        var driver = AmbientDriver()
        driver.send(sound("mic_wind_noise", 1, at: 0).started())
        driver.advance(to: 10)
        #expect(driver.changes.isEmpty)
        #expect(driver.stream.statistics.excluded == 1)
    }

    @Test func theSessionEndRemovesTheIconAtOnce() {
        var driver = AmbientDriver()
        driver.send(sound("rain", 1, at: 0).started())
        let change = driver.stream.process(.sessionEnded(at: T.date(1)))
        #expect(change == AmbientIconStream.Change(icon: nil, date: T.date(1)))
        #expect(driver.stream.nextDeadline == nil)
        #expect(driver.stream.trackedCount == 0)
    }

    @Test func everyKindOfTheTaxonomyGetsAnIconOrIsExcluded() {
        for (index, kindID) in SyntheticSound.allKindIDs.enumerated() {
            var driver = AmbientDriver()
            driver.send(sound(kindID, index + 1, at: 0).started())
            if AmbientIconPolicy.standard.excludedKindIDs.contains(kindID) {
                #expect(driver.stream.current == nil)
            } else {
                #expect(driver.stream.current?.kindID == kindID, "no icon for \(kindID)")
            }
        }
    }

    @Test func theSameInputsGiveTheSameChanges() {
        func run() -> [String] {
            var driver = AmbientDriver()
            var rain = sound("rain", 1, at: 0)
            driver.send(rain.started())
            var dog = sound("dog", 2, at: 3)
            driver.send(dog.started())
            driver.send(dog.ended(at: T.date(6)))
            driver.send(rain.updated(at: T.date(8)))
            driver.send(rain.ended(at: T.date(15)))
            driver.advance(to: 40)
            return driver.timeline
        }
        #expect(run() == run())
        #expect(run() == ["0:cloud.rain", "3:dog", "11:cloud.rain", "25:-"])
    }
}
