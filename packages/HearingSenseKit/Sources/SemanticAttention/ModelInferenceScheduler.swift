import Foundation

/// The one place that decides who may use the on-device language model next (Window 6.1).
///
/// Goal matching and the recap both need the same model. Left alone they start sessions side by
/// side, slow each other down and, in the worst case, a recap the user asked for fails because
/// routine goal matching had the model. Every model request therefore takes a turn here first.
///
/// - At most `maximumConcurrent` requests run at a time (one by default).
/// - Four classes. Spoken and acoustic warnings (the attention engine's phrase rule, Apple's
///   sound classifier) never come here: they do not use the language model and never wait for it.
/// - A higher class goes first. A lower class that has waited `agingInterval` is served once
///   before the classes above it, so routine work cannot be starved for ever.
/// - Waiting is bounded per class. What happens to the oldest waiter when a class is full is the
///   caller's decision (`run` throws `.queueFull` to the *new* request; callers that must not
///   lose work keep their own bounded, merged backlog and ask for one turn at a time).
/// - A waiter can be cancelled; a request that runs longer than its timeout is abandoned and
///   its turn is given back.
///
/// The scheduler sees no text: operations are opaque closures, statistics are counts and times.
public actor ModelInferenceScheduler {
    public enum Priority: Int, Sendable, CaseIterable, Comparable {
        /// A sentence that may be a warning but is not caught by the phrase rule. First in line.
        case urgentCandidate
        /// Something the user asked for and is waiting for: the Action Button recap.
        case userRequest
        /// A sentence that is likely to matter for a goal.
        case attention
        /// Routine evaluation of ordinary speech.
        case background

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public enum SchedulerError: Error, Equatable {
        /// The class already has as many waiters as it may have.
        case queueFull
        /// The request waited longer than it was allowed to.
        case expired
        /// The operation did not finish within its timeout.
        case timedOut
    }

    public struct Configuration: Hashable, Sendable {
        public var maximumConcurrent = 1
        /// Waiters per class.
        public var capacity: [Priority: Int] = [.urgentCandidate: 4, .userRequest: 2, .attention: 8, .background: 8]
        /// A waiter this old is served once ahead of the classes above it.
        public var agingInterval: TimeInterval = 6
        /// While something the user asked for runs, one urgent candidate may run beside it.
        public var allowsUrgentBesideUserRequest = false

        public init() {}

        public static let standard = Configuration()
    }

    public struct ClassStatistics: Hashable, Sendable, Codable {
        public var submitted = 0
        public var completed = 0
        public var rejectedFull = 0
        public var expired = 0
        public var cancelled = 0
        public var timedOut = 0
        public var failed = 0
        /// Served ahead of a higher class because it had waited `agingInterval`.
        public var aged = 0
        public var waits: [TimeInterval] = []
        public var runs: [TimeInterval] = []
        public var maximumWaiting = 0
    }

    public struct Statistics: Hashable, Sendable, Codable {
        public var classes: [String: ClassStatistics] = [:]
        public var maximumRunning = 0

        public subscript(priority: Priority) -> ClassStatistics {
            get { classes[String(describing: priority)] ?? ClassStatistics() }
            set { classes[String(describing: priority)] = newValue }
        }
    }

    private struct Waiter {
        var id: UInt64
        var priority: Priority
        var enqueued: Date
        var continuation: CheckedContinuation<Void, any Error>
    }

    public let configuration: Configuration
    private var waiting: [Waiter] = []
    private var running: [UInt64: Priority] = [:]
    private var nextID: UInt64 = 0
    public private(set) var statistics = Statistics()
    /// Samples kept per class for the percentiles; older ones are discarded.
    private let sampleLimit = 2_000

    public init(configuration: Configuration = .standard) {
        self.configuration = configuration
    }

    public var waitingCount: Int { waiting.count }
    public var runningCount: Int { running.count }

    public func waitingCount(_ priority: Priority) -> Int { waiting.count { $0.priority == priority } }

    /// Waits for a turn, runs the operation and gives the turn back.
    ///
    /// - Parameters:
    ///   - maximumWait: the request is dropped with `.expired` if its turn has not come by then.
    ///   - timeout: the operation is abandoned with `.timedOut` after this long.
    public func run<Value: Sendable>(
        _ priority: Priority, maximumWait: TimeInterval? = nil, timeout: TimeInterval? = nil,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let id = nextID
        nextID += 1
        statistics[priority].submitted += 1
        let enqueued = Date()
        if canStart(priority) {
            running[id] = priority
        } else {
            guard waitingCount(priority) < configuration.capacity[priority, default: 4] else {
                statistics[priority].rejectedFull += 1
                throw SchedulerError.queueFull
            }
            let expiry: Task<Void, Never>? = maximumWait.map { limit in
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(limit))
                    await self?.remove(id, error: SchedulerError.expired)
                }
            }
            defer { expiry?.cancel() }
            do {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                        waiting.append(Waiter(id: id, priority: priority, enqueued: enqueued, continuation: continuation))
                        statistics[priority].maximumWaiting = max(statistics[priority].maximumWaiting, waitingCount(priority))
                    }
                } onCancel: {
                    Task { await self.remove(id, error: CancellationError()) }
                }
            } catch let error as SchedulerError {
                statistics[priority].expired += error == .expired ? 1 : 0
                throw error
            } catch {
                statistics[priority].cancelled += 1
                throw error
            }
            // `grantNext` has already entered this request in `running`.
        }
        statistics.maximumRunning = max(statistics.maximumRunning, running.count)
        record(&statistics[priority].waits, Date().timeIntervalSince(enqueued))
        let started = Date()
        defer {
            record(&statistics[priority].runs, Date().timeIntervalSince(started))
            running[id] = nil
            grantNext()
        }
        do {
            let value = try await Self.withTimeout(timeout, operation)
            statistics[priority].completed += 1
            return value
        } catch SchedulerError.timedOut {
            statistics[priority].timedOut += 1
            throw SchedulerError.timedOut
        } catch is CancellationError {
            statistics[priority].cancelled += 1
            throw CancellationError()
        } catch {
            statistics[priority].failed += 1
            throw error
        }
    }

    public func resetStatistics() {
        statistics = Statistics()
    }

    // MARK: - Turns

    private func canStart(_ priority: Priority) -> Bool {
        if running.count < configuration.maximumConcurrent {
            // Nobody of the same or a higher class may be overtaken.
            return !waiting.contains { $0.priority <= priority }
        }
        return isUrgentException(priority)
    }

    /// One urgent candidate beside a running user request, when the configuration allows it.
    private func isUrgentException(_ priority: Priority) -> Bool {
        configuration.allowsUrgentBesideUserRequest && priority == .urgentCandidate
            && running.count == configuration.maximumConcurrent
            && running.values.contains(.userRequest) && !running.values.contains(.urgentCandidate)
    }

    private func grantNext() {
        while !waiting.isEmpty {
            let hasFreeTurn = running.count < configuration.maximumConcurrent
            let index: Int
            if hasFreeTurn {
                index = nextIndex()
            } else if let urgent = waiting.firstIndex(where: { $0.priority == .urgentCandidate }),
                      isUrgentException(.urgentCandidate)
            {
                index = urgent
            } else {
                return
            }
            let waiter = waiting.remove(at: index)
            running[waiter.id] = waiter.priority
            waiter.continuation.resume()
        }
    }

    /// The highest class first, the oldest within a class; but a waiter that has aged goes
    /// before a higher class (never before an urgent candidate).
    private func nextIndex() -> Int {
        let now = Date()
        if !waiting.contains(where: { $0.priority == .urgentCandidate }),
           let aged = waiting.enumerated()
           .filter({ now.timeIntervalSince($0.element.enqueued) >= configuration.agingInterval })
           .min(by: { $0.element.enqueued < $1.element.enqueued }),
           waiting.contains(where: { $0.priority < aged.element.priority })
        {
            statistics[aged.element.priority].aged += 1
            return aged.offset
        }
        var best = 0
        for (offset, waiter) in waiting.enumerated() where waiter.priority < waiting[best].priority { best = offset }
        return best
    }

    private func remove(_ id: UInt64, error: any Error) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: error)
    }

    private func record(_ samples: inout [TimeInterval], _ value: TimeInterval) {
        if samples.count >= sampleLimit { samples.removeFirst(samples.count - sampleLimit + 1) }
        samples.append(value)
    }

    private static func withTimeout<Value: Sendable>(
        _ timeout: TimeInterval?, _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        guard let timeout else { return try await operation() }
        return try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw SchedulerError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw SchedulerError.timedOut }
            return first
        }
    }
}
