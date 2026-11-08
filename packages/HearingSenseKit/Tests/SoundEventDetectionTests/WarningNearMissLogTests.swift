import Foundation
import HearingSenseDomain
import Testing
@testable import SoundEventDetection

@Suite struct WarningNearMissLogTests {
    /// The retest case: a siren that never met its confirmation rule leaves a readable trace.
    @Test func aSirenBelowItsRuleIsKeptWithScoreAndCompetitor() throws {
        var script = FrameScript()
        var detector = SoundEventDetector(taxonomy: .appleV1, policy: .standard)
        var log = WarningNearMissLog()
        let windows: [[SoundLabel: Double]] = [
            ["speech": 0.8], ["speech": 0.7, "siren": 0.32], ["speech": 0.75, "siren": 0.41], ["speech": 0.8, "siren": 0.2],
            ["speech": 0.8], ["speech": 0.8], ["speech": 0.8], ["speech": 0.8], ["speech": 0.8], ["speech": 0.8],
        ]
        for scores in windows {
            let frame = script.frame(scores)
            let output = detector.process(frame)
            #expect(!output.updates.contains { $0.event.kind.id == "siren" })
            log.note(frame, taxonomy: .appleV1, confirmedKindIDs: Set(detector.activeEvents.map(\.kind.id)))
        }
        let miss = try #require(log.misses.first)
        #expect(log.misses.count == 1)
        #expect(miss.kindID == "siren")
        #expect(miss.windows == 3)
        #expect(abs(miss.peak - 0.41) < 0.001)
        #expect(miss.competingLabel == "speech")
        #expect(miss.inputRMSDBFS == -30)
        #expect(log.reportLines().contains { $0.contains("siren") && $0.contains("0.41") && $0.contains("speech") })
    }

    @Test func aConfirmedSirenIsNotAMiss() {
        var script = FrameScript()
        var detector = SoundEventDetector(taxonomy: .appleV1, policy: .standard)
        var log = WarningNearMissLog()
        for scores in [["siren": 0.9], ["siren": 0.9], ["siren": 0.8], [:], [:], [:], [:], [:], [:], [:], [:], [:]] as [[SoundLabel: Double]] {
            let frame = script.frame(scores)
            _ = detector.process(frame)
            log.note(frame, taxonomy: .appleV1, confirmedKindIDs: Set(detector.activeEvents.map(\.kind.id)))
        }
        log.endSession()
        #expect(log.misses.isEmpty)
        #expect(log.confirmedRuns == 1)
    }

    @Test func otherKindsAndLowScoresAreIgnoredAndTheLogIsBounded() {
        var script = FrameScript()
        var log = WarningNearMissLog(capacity: 3)
        log.note(script.frame(["speech": 0.9, "dog_bark": 0.6, "siren": 0.1]), taxonomy: .appleV1, confirmedKindIDs: [])
        #expect(log.misses.isEmpty)
        for _ in 0..<6 {
            log.note(script.frame(["siren": 0.3]), taxonomy: .appleV1, confirmedKindIDs: [])
            for _ in 0..<6 { log.note(script.frame([:]), taxonomy: .appleV1, confirmedKindIDs: []) }
        }
        #expect(log.misses.count == 3)
    }
}
