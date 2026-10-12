import Foundation
import Testing
@testable import HearingSenseAudio

/// Window 7: the ON/OFF switch of the listening session.
@Suite struct ListeningSessionMachineTests {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    private func sessions(_ effects: [ListeningSessionMachine.Effect]) -> [UUID] {
        effects.compactMap { if case .beginSession(let id) = $0 { id } else { nil } }
    }

    @Test func aToggleTurnsItOnAndTheNextOneOff() {
        var machine = ListeningSessionMachine()
        let on = machine.process(.toggle(.intent, at: at(0)))
        let id = sessions(on).first
        #expect(id != nil)
        #expect(machine.phase == .starting)
        #expect(machine.isOn)
        machine.process(.captureStarted(at: at(0.4)))
        #expect(machine.phase == .on)
        #expect(machine.requestedBy == .intent)

        let off = machine.process(.toggle(.intent, at: at(60)))
        #expect(off == [.endSession(id!, .userStopped)])
        #expect(machine.phase == .off)
        #expect(!machine.isOn)
        #expect(machine.sessionID == nil)
        #expect(machine.lastEndReason == .userStopped)
        #expect(machine.statistics.sessionsStarted == 1)
        #expect(machine.statistics.sessionsEnded == 1)
    }

    /// Acceptance test 3: repeated calls never give two sessions.
    @Test func requestsDuringAStartAreRefusedNotQueued() {
        var machine = ListeningSessionMachine()
        var begun = sessions(machine.process(.toggle(.intent, at: at(0))))
        // The permission prompt is still open and the button is pressed again, twice.
        #expect(machine.process(.toggle(.intent, at: at(0.2))) == [.refused(.startInProgress)])
        #expect(machine.process(.start(.app, at: at(0.3))) == [.refused(.startInProgress)])
        #expect(machine.process(.stop(.app, at: at(0.35))) == [.refused(.startInProgress)])
        machine.process(.captureStarted(at: at(1)))
        begun += sessions(machine.process(.start(.app, at: at(2))))
        #expect(begun.count == 1)
        #expect(machine.phase == .on)
        #expect(machine.statistics.sessionsStarted == 1)
        #expect(machine.statistics.requestsRefused == 4)
    }

    @Test func manyTogglesAlternateAndEveryStartIsANewSession() {
        var machine = ListeningSessionMachine()
        var ids: Set<UUID> = []
        var open = 0
        for step in 0 ..< 40 {
            for effect in machine.process(.toggle(.intent, at: at(Double(step)))) {
                switch effect {
                case .beginSession(let id):
                    ids.insert(id)
                    open += 1
                    machine.process(.captureStarted(at: at(Double(step) + 0.1)))
                case .endSession:
                    open -= 1
                default:
                    Issue.record("unexpected effect \(effect)")
                }
                #expect(open == 0 || open == 1)
            }
        }
        #expect(ids.count == 20)
        #expect(open == 0)
        #expect(machine.phase == .off)
    }

    @Test func aFailedStartClosesTheSession() {
        var machine = ListeningSessionMachine()
        let id = sessions(machine.process(.start(.app, at: at(0)))).first!
        #expect(machine.process(.captureEnded(.startFailed, at: at(0.5))) == [.endSession(id, .startFailed)])
        #expect(machine.phase == .off)
        #expect(machine.lastEndReason == .startFailed)
        // Reported twice (two error paths in the host): the second one changes nothing.
        #expect(machine.process(.captureEnded(.startFailed, at: at(0.6))).isEmpty)
        #expect(machine.statistics.sessionsEnded == 1)
        // And it can be started again.
        #expect(sessions(machine.process(.toggle(.intent, at: at(5)))).count == 1)
    }

    @Test func anInterruptionKeepsTheSessionAndAStartResumesIt() {
        var machine = ListeningSessionMachine()
        let id = sessions(machine.process(.start(.app, at: at(0)))).first!
        machine.process(.captureStarted(at: at(1)))
        machine.process(.interrupted(at: at(30)))
        #expect(machine.phase == .interrupted)
        #expect(machine.isOn)
        #expect(machine.sessionID == id)
        #expect(machine.process(.start(.app, at: at(40))) == [.resumeSession(id)])
        machine.process(.captureStarted(at: at(41)))
        #expect(machine.phase == .on)
        #expect(machine.statistics.sessionsStarted == 1)
    }

    /// Acceptance test 11: the switch turns the whole session off, also while it is interrupted.
    @Test func aToggleWhileInterruptedTurnsItOff() {
        var machine = ListeningSessionMachine()
        let id = sessions(machine.process(.toggle(.intent, at: at(0)))).first!
        machine.process(.captureStarted(at: at(1)))
        machine.process(.interrupted(at: at(30)))
        #expect(machine.process(.toggle(.intent, at: at(35))) == [.endSession(id, .userStopped)])
        #expect(machine.phase == .off)
    }

    @Test func stoppingWhileOffAndStartingWhileOnAreRefused() {
        var machine = ListeningSessionMachine()
        #expect(machine.process(.stop(.app, at: at(0))) == [.refused(.alreadyOff)])
        machine.process(.start(.app, at: at(1)))
        machine.process(.captureStarted(at: at(2)))
        #expect(machine.process(.start(.intent, at: at(3))) == [.refused(.alreadyOn)])
    }

    @Test func theRecordSurvivesEncodingAndSaysWhetherASessionWasOpen() throws {
        var machine = ListeningSessionMachine()
        #expect(!machine.record.isOn)
        machine.process(.toggle(.intent, at: at(0)))
        machine.process(.captureStarted(at: at(1)))
        let stored = try JSONEncoder().encode(machine.record)
        let record = try JSONDecoder().decode(ListeningSessionRecord.self, from: stored)
        #expect(record.isOn)
        #expect(record.sessionID == machine.sessionID)
        #expect(record.startedAt == at(0))
        #expect(record.updatedAt == at(1))
        machine.process(.toggle(.intent, at: at(9)))
        #expect(!machine.record.isOn)
        #expect(machine.record.lastEndReason == .userStopped)
    }

    /// The app was terminated while listening: the next launch knows, and starts nothing by itself.
    @Test func aRecordThatSaysOnIsReportedAsLostAndNothingRestarts() {
        let lost = ListeningSessionRecord(isOn: true, sessionID: UUID(), startedAt: at(-3_600), updatedAt: at(-60))
        var machine = ListeningSessionMachine()
        #expect(machine.process(.restored(lost, at: at(0))) == [.previousSessionLost(lost)])
        #expect(machine.phase == .off)
        #expect(!machine.record.isOn)
        #expect(machine.lastEndReason == .processEnded)
        // A clean record restores quietly.
        var other = ListeningSessionMachine()
        #expect(other.process(.restored(ListeningSessionRecord(lastEndReason: .userStopped), at: at(0))).isEmpty)
        #expect(other.lastEndReason == .userStopped)
    }
}
