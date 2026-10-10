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
        driver.send(sound("dog", 2, at: 1).started())  // higher rank, but rain was shown 1 s ago
        #expect(driver.stream.current?.symbolName == "cloud.rain")
        driver.advance(to: 3.9)
        #expect(driver.stream.current?.symbolName == "cloud.rain")
        driver.advance(to: 4)
        #expect(driver.timeline == ["0:cloud.rain", "4:dog"])
    }

    @Test func aLowerRankedSoundDoesNotReplaceOneThatIsStillPresent() {
        var driver = AmbientDriver()
        var rain = sound("rain", 1, at: 0)
        driver.send(rain.started())
        var music = sound("music", 2, at: 10)
        driver.send(music.started())
        driver.send(rain.updated(at: T.date(15)))
        driver.send(music.updated(at: T.date(15)))
        driver.advance(to: 18)
        #expect(driver.timeline == ["0:cloud.rain"])
        // When the rain is over (and lingered) the music that is still playing takes its place.
        driver.send(rain.ended(at: T.date(20)))
        driver.send(music.updated(at: T.date(22)))
        driver.advance(to: 26)
        #expect(driver.timeline == ["0:cloud.rain", "25:music.note"])
    }

    @Test func aBriefSoundLingersThenTheIconGoes() {
        var driver = AmbientDriver()
        var knock = sound("door", 1, at: 0)
        driver.send(knock.started())
        driver.send(knock.ended(at: T.date(2)))
        driver.advance(to: 6.9)
        #expect(driver.stream.current?.symbolName == "door.left.hand.closed")
        driver.advance(to: 7)
        #expect(driver.timeline == ["0:door.left.hand.closed", "7:-"])
        #expect(driver.stream.nextDeadline == nil)
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
        driver.advance(to: 20)
        #expect(driver.timeline == ["0:dog", "18:-"])
    }

    @Test func changesAreLimitedPerMinute() {
        var policy = AmbientIconPolicy.standard
        policy.minimumDisplay = 0
        policy.linger = 0
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
        #expect(driver.stream.current == nil)
        #expect(driver.stream.statistics.staleEvents == 1)
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
        #expect(run() == ["0:cloud.rain", "4:dog", "11:cloud.rain", "20:-"])
    }
}
