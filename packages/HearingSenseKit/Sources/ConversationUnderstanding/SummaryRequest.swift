import Foundation

/// Content-free, request-local diagnostics and one monotonic budget for the entire pipeline.
/// Never put prompts, output, errors or content fingerprints in this object.
public final class SummaryRequest: @unchecked Sendable {
    public enum Operation: String, Sendable { case summary, update }
    public enum Stage: String, Sendable {
        case availability, queue, load, firstOutput, primary, fallback, generation
        case check, restatement, rewrite, verification, retention, save, publication, cleanup
    }
    public enum Outcome: String, Sendable {
        case started, completed, failed, unavailable, noChange, rejected, cancelled
        case deadlineExpired, cancellationRequested, staleDropped, suspended
    }
    public struct Event: Sendable, Codable {
        public let stage: String
        public let outcome: String
        public let elapsed: TimeInterval
        public let duration: TimeInterval
    }
    public struct Snapshot: Sendable {
        public let stage: Stage
        public let elapsed: TimeInterval
        public let outcome: Outcome?
        public let events: [Event]
        public let savedRecordID: UUID?
        public let acceptedRevision: Int?
    }
    @TaskLocal public static var current: SummaryRequest?
    public let id = UUID()
    public let operation: Operation
    public let sourceRevision: Int
    private let started = ContinuousClock.now
    private let deadline: ContinuousClock.Instant
    public let checkReserve: TimeInterval
    private let lock = NSLock()
    private var stage = Stage.availability
    private var terminal: Outcome?
    private var terminalElapsed: TimeInterval?
    private var events: [Event] = []
    private var savedRecordID: UUID?
    private var acceptedRevision: Int?
    public init(operation: Operation, sourceRevision: Int, budget: TimeInterval = 66, checkReserve: TimeInterval = 10) {
        self.operation = operation
        self.sourceRevision = sourceRevision
        self.checkReserve = checkReserve
        deadline = ContinuousClock.now.advanced(by: .seconds(budget))
    }
    public var remaining: TimeInterval { max(0, Self.seconds(ContinuousClock.now.duration(to: deadline))) }
    public func budget(maximum: TimeInterval, reservingChecks: Bool = false) -> TimeInterval {
        max(0, min(maximum, remaining - (reservingChecks ? checkReserve : 0)))
    }
    public func check() throws {
        try Task.checkCancellation()
        guard remaining > 0, snapshot.outcome == nil else { throw CancellationError() }
    }
    public func record(_ stage: Stage, _ outcome: Outcome = .started, duration: TimeInterval = 0) {
        lock.lock(); defer { lock.unlock() }
        // Cleanup may finish after the visible request; its outcome must not change.
        if terminal == nil { self.stage = stage }
        if events.count == 128 { events.removeFirst() }
        events.append(Event(stage: stage.rawValue, outcome: outcome.rawValue,
                            elapsed: Self.seconds(started.duration(to: .now)), duration: duration))
    }
    @discardableResult public func finish(_ outcome: Outcome) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard terminal == nil else { return false }
        terminal = outcome
        terminalElapsed = Self.seconds(started.duration(to: .now))
        return true
    }
    public func markSaved(recordID: UUID, revision: Int) {
        lock.lock(); defer { lock.unlock() }
        savedRecordID = recordID
        acceptedRevision = revision
    }
    public var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(stage: stage, elapsed: terminalElapsed ?? Self.seconds(started.duration(to: .now)), outcome: terminal, events: events,
                        savedRecordID: savedRecordID, acceptedRevision: acceptedRevision)
    }
    public static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

/// Serializes the *actual* operation, including cancellation cleanup. A caller's deadline may
/// expire sooner, but the next model/load/release never starts until this permit is released.
public actor SummaryExecutionGate {
    private var busy = false
    private var waiters: [(UUID, CheckedContinuation<Void, any Error>)] = []
    public init() {}
    public func perform<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        let id = UUID()
        try await withTaskCancellationHandler {
            if busy {
                try await withCheckedThrowingContinuation { waiters.append((id, $0)) }
            } else { busy = true }
        } onCancel: { Task { await self.cancelWaiter(id) } }
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }
    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(throwing: CancellationError())
    }
    private func release() {
        if waiters.isEmpty { busy = false }
        else { waiters.removeFirst().1.resume() }
    }
}

/// Races a visible deadline without waiting for an uncooperative child. Native operations must
/// own an execution-gate permit until their cleanup finishes; timing out does not free it.
public enum SummaryDeadline {
    private final class Race<T: Sendable>: @unchecked Sendable {
        let lock = NSLock()
        var continuation: CheckedContinuation<T, any Error>?
        var result: Result<T, any Error>?
        var tasks: [Task<Void, Never>] = []
        func install(_ continuation: CheckedContinuation<T, any Error>) {
            lock.lock()
            if let result { lock.unlock(); continuation.resume(with: result) }
            else { self.continuation = continuation; lock.unlock() }
        }
        func add(_ task: Task<Void, Never>) {
            lock.lock()
            if result != nil { lock.unlock(); task.cancel() }
            else { tasks.append(task); lock.unlock() }
        }
        func resolve(_ result: Result<T, any Error>) {
            lock.lock()
            guard self.result == nil else { lock.unlock(); return }
            self.result = result
            let continuation = self.continuation
            self.continuation = nil
            let tasks = self.tasks
            self.tasks = []
            lock.unlock()
            for task in tasks { task.cancel() }
            continuation?.resume(with: result)
        }
    }
    public static func run<T: Sendable>(seconds: TimeInterval,
                                       operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        guard seconds > 0 else { throw CancellationError() }
        let race = Race<T>()
        let request = SummaryRequest.current
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.install(continuation)
                race.add(Task {
                    do { race.resolve(.success(try await operation())) }
                    catch { race.resolve(.failure(error)) }
                })
                race.add(Task {
                    do {
                        try await Task.sleep(for: .seconds(seconds))
                        request?.record(request?.snapshot.stage ?? .generation, .deadlineExpired)
                        race.resolve(.failure(CancellationError()))
                    } catch { }
                })
            }
        } onCancel: {
            request?.record(request?.snapshot.stage ?? .generation, .cancellationRequested)
            race.resolve(.failure(CancellationError()))
        }
    }
}
