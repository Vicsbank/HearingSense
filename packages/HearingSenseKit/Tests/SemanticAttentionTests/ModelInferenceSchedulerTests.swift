import Foundation
@testable import SemanticAttention
import Testing

/// Records the order in which operations started.
private actor Order {
    private(set) var started: [String] = []
    private(set) var concurrent = 0
    private(set) var maximumConcurrent = 0

    func begin(_ name: String) {
        started.append(name)
        concurrent += 1
        maximumConcurrent = max(maximumConcurrent, concurrent)
    }

    func end() { concurrent -= 1 }
}

private func operation(_ name: String, _ order: Order, seconds: Double = 0.05) -> @Sendable () async throws -> String {
    {
        await order.begin(name)
        try await Task.sleep(for: .seconds(seconds))
        await order.end()
        return name
    }
}

/// Waits until the scheduler holds this many waiters, so a test controls arrival order.
private func waitForWaiters(_ scheduler: ModelInferenceScheduler, _ count: Int) async {
    for _ in 0 ..< 400 where await scheduler.waitingCount < count {
        try? await Task.sleep(for: .milliseconds(5))
    }
}

@Suite struct ModelInferenceSchedulerTests {
    @Test func oneRequestRunsAtATime() async throws {
        let scheduler = ModelInferenceScheduler()
        let order = Order()
        try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0 ..< 6 {
                group.addTask { try await scheduler.run(.background, operation: operation("b\(index)", order, seconds: 0.02)) }
            }
            for try await _ in group {}
        }
        #expect(await order.maximumConcurrent == 1)
        #expect(await scheduler.statistics[.background].completed == 6)
        #expect(await scheduler.statistics.maximumRunning == 1)
    }

    @Test func higherClassesGoFirst() async throws {
        let scheduler = ModelInferenceScheduler()
        let order = Order()
        async let blocker = scheduler.run(.background, operation: operation("running", order, seconds: 0.25))
        for _ in 0 ..< 200 where await scheduler.runningCount == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        async let background = scheduler.run(.background, operation: operation("background", order))
        await waitForWaiters(scheduler, 1)
        async let attention = scheduler.run(.attention, operation: operation("attention", order))
        await waitForWaiters(scheduler, 2)
        async let recap = scheduler.run(.userRequest, operation: operation("recap", order))
        await waitForWaiters(scheduler, 3)
        async let urgent = scheduler.run(.urgentCandidate, operation: operation("urgent", order))
        _ = try await (blocker, background, attention, recap, urgent)
        #expect(await order.started == ["running", "urgent", "recap", "attention", "background"])
    }

    @Test func aRecapIsNotStarvedByBackgroundWork() async throws {
        // Background evaluations keep arriving; the recap takes the very next turn.
        let scheduler = ModelInferenceScheduler()
        let order = Order()
        async let first = scheduler.run(.background, operation: operation("b0", order, seconds: 0.2))
        for _ in 0 ..< 200 where await scheduler.runningCount == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        async let second = scheduler.run(.background, operation: operation("b1", order))
        async let third = scheduler.run(.background, operation: operation("b2", order))
        await waitForWaiters(scheduler, 2)
        async let recap = scheduler.run(.userRequest, operation: operation("recap", order))
        _ = try await (first, second, third, recap)
        #expect(await order.started.prefix(2) == ["b0", "recap"])
        #expect(await scheduler.statistics[.userRequest].completed == 1)
    }

    @Test func backgroundWorkThatHasAgedIsServedOnce() async throws {
        var configuration = ModelInferenceScheduler.Configuration.standard
        configuration.agingInterval = 0.15
        let scheduler = ModelInferenceScheduler(configuration: configuration)
        let order = Order()
        async let blocker = scheduler.run(.attention, operation: operation("a0", order, seconds: 0.3))
        for _ in 0 ..< 200 where await scheduler.runningCount == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        async let old = scheduler.run(.background, operation: operation("old-background", order))
        await waitForWaiters(scheduler, 1)
        try await Task.sleep(for: .seconds(0.2))
        async let newer = scheduler.run(.attention, operation: operation("a1", order))
        _ = try await (blocker, old, newer)
        #expect(await order.started == ["a0", "old-background", "a1"])
        #expect(await scheduler.statistics[.background].aged == 1)
    }

    @Test func aFullClassRejectsTheNewRequestAndCountsIt() async throws {
        var configuration = ModelInferenceScheduler.Configuration.standard
        configuration.capacity[.background] = 1
        let scheduler = ModelInferenceScheduler(configuration: configuration)
        let order = Order()
        async let blocker = scheduler.run(.background, operation: operation("b0", order, seconds: 0.2))
        for _ in 0 ..< 200 where await scheduler.runningCount == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        async let waiting = scheduler.run(.background, operation: operation("b1", order))
        await waitForWaiters(scheduler, 1)
        await #expect(throws: ModelInferenceScheduler.SchedulerError.queueFull) {
            try await scheduler.run(.background, operation: operation("b2", order))
        }
        _ = try await (blocker, waiting)
        let statistics = await scheduler.statistics[.background]
        #expect(statistics.rejectedFull == 1)
        #expect(statistics.completed == 2)
        // A full background class does not turn away a recap.
        #expect(try await scheduler.run(.userRequest, operation: operation("recap", order)) == "recap")
    }

    @Test func aRequestThatWaitsTooLongExpires() async throws {
        let scheduler = ModelInferenceScheduler()
        let order = Order()
        async let blocker = scheduler.run(.background, operation: operation("b0", order, seconds: 0.3))
        for _ in 0 ..< 200 where await scheduler.runningCount == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        await #expect(throws: ModelInferenceScheduler.SchedulerError.expired) {
            try await scheduler.run(.background, maximumWait: 0.05, operation: operation("late", order))
        }
        _ = try await blocker
        #expect(await order.started == ["b0"])
        #expect(await scheduler.statistics[.background].expired == 1)
    }

    @Test func aSlowOperationTimesOutAndGivesItsTurnBack() async throws {
        let scheduler = ModelInferenceScheduler()
        let order = Order()
        await #expect(throws: ModelInferenceScheduler.SchedulerError.timedOut) {
            try await scheduler.run(.attention, timeout: 0.05, operation: operation("slow", order, seconds: 5))
        }
        #expect(try await scheduler.run(.attention, operation: operation("next", order)) == "next")
        #expect(await scheduler.statistics[.attention].timedOut == 1)
        #expect(await scheduler.runningCount == 0)
    }

    @Test func aCancelledWaiterLeavesTheQueue() async throws {
        let scheduler = ModelInferenceScheduler()
        let order = Order()
        async let blocker = scheduler.run(.background, operation: operation("b0", order, seconds: 0.25))
        for _ in 0 ..< 200 where await scheduler.runningCount == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        let waiter = Task { try await scheduler.run(.background, operation: operation("cancelled", order)) }
        await waitForWaiters(scheduler, 1)
        waiter.cancel()
        _ = await waiter.result
        _ = try await blocker
        #expect(await order.started == ["b0"])
        #expect(await scheduler.waitingCount == 0)
        #expect(await scheduler.statistics[.background].cancelled == 1)
    }

    @Test func anUrgentCandidateMayRunBesideARecapWhenAllowed() async throws {
        var configuration = ModelInferenceScheduler.Configuration.standard
        configuration.allowsUrgentBesideUserRequest = true
        let scheduler = ModelInferenceScheduler(configuration: configuration)
        let order = Order()
        async let recap = scheduler.run(.userRequest, operation: operation("recap", order, seconds: 0.3))
        for _ in 0 ..< 200 where await scheduler.runningCount == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        async let background = scheduler.run(.background, operation: operation("background", order))
        await waitForWaiters(scheduler, 1)
        async let urgent = scheduler.run(.urgentCandidate, operation: operation("urgent", order, seconds: 0.05))
        async let secondUrgent = scheduler.run(.urgentCandidate, operation: operation("urgent2", order, seconds: 0.05))
        _ = try await (recap, background, urgent, secondUrgent)
        let started = await order.started
        #expect(started.first == "recap")
        #expect(started.last == "background")
        // The two urgent candidates did not run beside each other: never more than two sessions.
        #expect(await order.maximumConcurrent == 2)
        #expect(await scheduler.statistics.maximumRunning == 2)
    }

    @Test func statisticsHoldWaitsAndRunsOnly() async throws {
        let scheduler = ModelInferenceScheduler()
        let order = Order()
        _ = try await scheduler.run(.attention, operation: operation("a", order, seconds: 0.03))
        let statistics = await scheduler.statistics[.attention]
        #expect(statistics.waits.count == 1)
        #expect(statistics.runs.first ?? 0 >= 0.02)
        #expect(statistics.submitted == 1)
    }
}
