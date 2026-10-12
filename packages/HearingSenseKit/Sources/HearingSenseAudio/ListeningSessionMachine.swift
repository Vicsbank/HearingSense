import Foundation

/// Who asked for a change of the listening session. Recorded with the session; never decides.
public enum ListeningRequestSource: String, Hashable, Sendable, Codable {
    /// The buttons in the app.
    case app
    /// The "Toggle Hearing Sense" App Intent (the Action Button, a shortcut, Siri).
    case intent
    /// A debug launch argument or a timed test.
    case automation
}

/// Why a listening session is over.
public enum ListeningEndReason: String, Hashable, Sendable, Codable {
    case userStopped = "user_stopped"
    /// The microphone could not be started (permission, audio session, engine).
    case startFailed = "start_failed"
    /// Capture failed while running (route change that could not be recovered, media reset).
    case captureFailed = "capture_failed"
    /// A time limit of a timed test.
    case timeLimit = "time_limit"
    /// The record of an earlier launch said "on": that process is gone, so is its microphone.
    case processEnded = "process_ended"
}

/// What survives a relaunch: enough to know that a session was running when the app's process
/// ended. It holds no audio, no text and no sound events.
public struct ListeningSessionRecord: Hashable, Sendable, Codable {
    public var isOn: Bool
    public var sessionID: UUID?
    public var startedAt: Date?
    public var updatedAt: Date
    public var lastEndReason: ListeningEndReason?

    public init(isOn: Bool = false, sessionID: UUID? = nil, startedAt: Date? = nil, updatedAt: Date = .distantPast,
                lastEndReason: ListeningEndReason? = nil)
    {
        self.isOn = isOn
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.lastEndReason = lastEndReason
    }
}

/// The ON/OFF state machine of a listening session (Window 7).
///
/// One switch, one session: the Action Button's intent, the buttons in the app and the debug
/// arguments all send requests here, and the host starts or stops the microphone only when an
/// effect tells it to. A request that arrives while a start is still in progress is refused
/// instead of queued, so two requests can never produce two sessions.
///
/// A value type without a clock, a microphone or storage: inputs carry their time, the host
/// carries out the effects and stores `record` after every input.
public struct ListeningSessionMachine: Sendable {
    public enum Phase: String, Hashable, Sendable, Codable {
        case off
        /// A start was requested; the microphone is not confirmed yet (this includes the
        /// permission prompt).
        case starting
        case on
        /// iOS took the microphone away for now (a call, Siri). The session is still the same one.
        case interrupted

        public var isSessionOpen: Bool { self != .off }
    }

    public enum Input: Hashable, Sendable {
        /// ON when off, OFF when on.
        case toggle(ListeningRequestSource, at: Date)
        case start(ListeningRequestSource, at: Date)
        case stop(ListeningRequestSource, at: Date)
        /// The host reports: the microphone is running.
        case captureStarted(at: Date)
        /// The host reports: the session could not start or could not go on.
        case captureEnded(ListeningEndReason, at: Date)
        case interrupted(at: Date)
        /// The record a previous launch left behind, given once before anything else.
        case restored(ListeningSessionRecord, at: Date)

        public var date: Date {
            switch self {
            case .toggle(_, let date), .start(_, let date), .stop(_, let date): date
            case .captureStarted(let date), .interrupted(let date): date
            case .captureEnded(_, let date), .restored(_, let date): date
            }
        }
    }

    public enum RefusalReason: String, Hashable, Sendable, Codable {
        /// A start is in progress: the request is dropped, not queued.
        case startInProgress = "start_in_progress"
        case alreadyOn = "already_on"
        case alreadyOff = "already_off"
    }

    public enum Effect: Hashable, Sendable {
        /// Start the microphone for this new session and report `captureStarted` or `captureEnded`.
        case beginSession(UUID)
        /// Stop the microphone and everything that belongs to the session.
        case endSession(UUID, ListeningEndReason)
        /// Bring an interrupted session's microphone back (same session).
        case resumeSession(UUID)
        case refused(RefusalReason)
        /// The previous launch ended while listening. Nothing is restarted: the microphone only
        /// starts when the user asks.
        case previousSessionLost(ListeningSessionRecord)
    }

    public struct Statistics: Hashable, Sendable, Codable {
        public var sessionsStarted = 0
        public var sessionsEnded = 0
        public var requestsRefused = 0
        public var toggles = 0

        public init() {}
    }

    public private(set) var phase = Phase.off
    public private(set) var sessionID: UUID?
    public private(set) var startedAt: Date?
    public private(set) var requestedBy: ListeningRequestSource?
    public private(set) var lastEndReason: ListeningEndReason?
    public private(set) var statistics = Statistics()
    private var updatedAt = Date.distantPast
    private let makeID: @Sendable () -> UUID

    public init(makeID: @escaping @Sendable () -> UUID = { UUID() }) {
        self.makeID = makeID
    }

    public var isOn: Bool { phase.isSessionOpen }

    /// What to store after every input.
    public var record: ListeningSessionRecord {
        ListeningSessionRecord(isOn: isOn, sessionID: sessionID, startedAt: startedAt, updatedAt: updatedAt,
                               lastEndReason: lastEndReason)
    }

    @discardableResult
    public mutating func process(_ input: Input) -> [Effect] {
        let now = input.date
        updatedAt = now
        switch input {
        case .toggle(let source, _):
            statistics.toggles += 1
            return isOn ? requestStop(at: now) : requestStart(source, at: now)

        case .start(let source, _):
            return requestStart(source, at: now)

        case .stop:
            return requestStop(at: now)

        case .captureStarted:
            guard phase == .starting || phase == .interrupted else { return [] }
            phase = .on
            return []

        case .captureEnded(let reason, _):
            guard let id = sessionID, phase != .off else { return [] }
            close(reason)
            return [.endSession(id, reason)]

        case .interrupted:
            guard phase == .on || phase == .starting else { return [] }
            phase = .interrupted
            return []

        case .restored(let previous, _):
            guard phase == .off, previous.isOn else {
                lastEndReason = lastEndReason ?? previous.lastEndReason
                return []
            }
            lastEndReason = .processEnded
            return [.previousSessionLost(previous)]
        }
    }

    private mutating func requestStart(_ source: ListeningRequestSource, at now: Date) -> [Effect] {
        switch phase {
        case .off:
            let id = makeID()
            phase = .starting
            sessionID = id
            startedAt = now
            requestedBy = source
            statistics.sessionsStarted += 1
            return [.beginSession(id)]
        case .starting:
            return refuse(.startInProgress)
        case .on:
            return refuse(.alreadyOn)
        case .interrupted:
            guard let id = sessionID else { return refuse(.alreadyOn) }
            return [.resumeSession(id)]
        }
    }

    private mutating func requestStop(at now: Date) -> [Effect] {
        switch phase {
        case .off:
            return refuse(.alreadyOff)
        case .starting:
            // The permission prompt or the audio session is still being answered; stopping now
            // would race with it. The request is dropped and can be repeated.
            return refuse(.startInProgress)
        case .on, .interrupted:
            guard let id = sessionID else { return refuse(.alreadyOff) }
            close(.userStopped)
            return [.endSession(id, .userStopped)]
        }
    }

    private mutating func refuse(_ reason: RefusalReason) -> [Effect] {
        statistics.requestsRefused += 1
        return [.refused(reason)]
    }

    private mutating func close(_ reason: ListeningEndReason) {
        phase = .off
        sessionID = nil
        startedAt = nil
        requestedBy = nil
        lastEndReason = reason
        statistics.sessionsEnded += 1
    }
}
