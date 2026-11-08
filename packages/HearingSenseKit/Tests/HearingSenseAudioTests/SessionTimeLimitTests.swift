import Foundation
import Testing
@testable import HearingSenseAudio

@Suite struct SessionTimeLimitTests {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func itIsDueFromTheDeadlineUntilItFired() {
        var limit = SessionTimeLimit(armedAt: start, duration: 300)
        #expect(limit.duration == 300)
        #expect(!limit.isDue(at: start.addingTimeInterval(299.9)))
        #expect(limit.allowsCapture(at: start.addingTimeInterval(299.9)))
        #expect(limit.isDue(at: start.addingTimeInterval(300)))
        #expect(!limit.allowsCapture(at: start.addingTimeInterval(300)))
        limit.fire(at: start.addingTimeInterval(300.2), trigger: .timer)
        #expect(limit.hasFired)
        #expect(!limit.isDue(at: start.addingTimeInterval(301)))
        #expect(abs((limit.lateness ?? -1) - 0.2) < 0.001)
    }

    /// The case the timer alone does not cover: an interruption ends after the deadline.
    @Test func nothingMayCaptureAfterTheDeadlineEvenAfterTheStop() {
        var limit = SessionTimeLimit(armedAt: start, duration: 300)
        limit.fire(at: start.addingTimeInterval(300), trigger: .timer)
        #expect(!limit.allowsCapture(at: start.addingTimeInterval(400)))
        #expect(!limit.allowsCapture(at: start.addingTimeInterval(4_000)))
    }

    @Test func onlyTheFirstTriggerIsRecorded() {
        var limit = SessionTimeLimit(armedAt: start, duration: 5)
        limit.fire(at: start.addingTimeInterval(5.1), trigger: .captureTick)
        limit.fire(at: start.addingTimeInterval(9), trigger: .timer)
        #expect(limit.trigger == .captureTick)
        #expect(limit.firedAt == start.addingTimeInterval(5.1))
    }

    @Test func heartbeatField() {
        var limit = SessionTimeLimit(armedAt: start, duration: 300)
        #expect(limit.heartbeat(at: start.addingTimeInterval(258.5)) == "in 42s")
        #expect(limit.heartbeat(at: start.addingTimeInterval(300.5)) == "due")
        limit.fire(at: start.addingTimeInterval(300), trigger: .timer)
        #expect(limit.heartbeat(at: start.addingTimeInterval(310)) == "fired+0.0s(timer)")
    }

    @Test func aNegativeDurationIsAlreadyOver() {
        let limit = SessionTimeLimit(armedAt: start, duration: -3)
        #expect(limit.isDue(at: start))
        #expect(!limit.allowsCapture(at: start))
    }
}
