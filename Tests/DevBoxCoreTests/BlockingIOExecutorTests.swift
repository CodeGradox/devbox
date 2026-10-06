import Foundation
import Synchronization
import Testing
@testable import DevBoxCore

/// All waits on the condition happen inside dedicated I/O workers, never inside
/// an async task. Tests coordinate using continuations and asynchronous yields.
private final class IOGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var permits = 0
    private var arrivals = 0
    private var active = 0
    private var maximum = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    var peak: Int {
        condition.lock()
        defer { condition.unlock() }
        return maximum
    }

    func block() {
        condition.lock()
        active += 1
        arrivals += 1
        maximum = max(maximum, active)
        let ready = waiters.filter { arrivals >= $0.0 }
        waiters.removeAll { arrivals >= $0.0 }
        condition.unlock()
        for (_, waiter) in ready { waiter.resume() }
        condition.lock()
        while permits == 0 { condition.wait() }
        permits -= 1
        active -= 1
        condition.unlock()
    }

    func release(_ count: Int = 1) {
        condition.lock()
        permits += count
        condition.broadcast()
        condition.unlock()
    }

    func waitForArrivals(_ count: Int) async {
        await withCheckedContinuation { continuation in
            register(count, continuation)
        }
    }

    private func register(_ count: Int, _ continuation: CheckedContinuation<Void, Never>) {
        condition.lock()
        if arrivals >= count {
            condition.unlock()
            continuation.resume()
        } else {
            waiters.append((count, continuation))
            condition.unlock()
        }
    }
}

private enum IOErrorForTesting: Error { case expected }

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct BlockingIOExecutorTests {
    @Test
    func cappedWorkersLeaveMainActorResponsive() async throws {
        let executor = BlockingIOExecutor(maxConcurrentOperations: 2)
        let gate = IOGate()
        let tasks = (0..<3).map { index in
            Task {
                try await executor.run { _ in
                    #expect(!Thread.isMainThread)
                    gate.block()
                    return index
                }
            }
        }
        await gate.waitForArrivals(2)
        // Reaching this MainActor code while both workers are blocked proves that
        // awaiting run() suspended rather than blocking the UI executor.
        MainActor.assertIsolated()
        #expect(gate.peak == 2)
        gate.release()
        await gate.waitForArrivals(3)
        #expect(gate.peak == 2)
        gate.release(2)
        var values: [Int] = []
        for task in tasks { values.append(try await task.value) }
        #expect(values == [0, 1, 2])
    }

    @Test
    func queuedInteractiveReadsPrecedeOlderBackgroundWork() async throws {
        let executor = BlockingIOExecutor(maxConcurrentOperations: 1)
        let gate = IOGate()
        let order = Mutex<[String]>([])
        let blocker = Task { try await executor.run { _ in gate.block() } }
        await gate.waitForArrivals(1)
        let background = Task {
            try await executor.run(priority: .background) { _ in order.withLock { $0.append("scan") } }
        }
        while executor.outstandingOperationCount < 2 { await Task.yield() }
        let normal = Task {
            try await executor.run { _ in order.withLock { $0.append("normal") } }
        }
        while executor.outstandingOperationCount < 3 { await Task.yield() }
        let interactive = Task {
            try await executor.run(priority: .interactive) { _ in order.withLock { $0.append("status") } }
        }
        while executor.outstandingOperationCount < 4 { await Task.yield() }
        gate.release()
        try await blocker.value
        try await interactive.value
        try await normal.value
        try await background.value
        #expect(order.withLock { $0 } == ["status", "normal", "scan"])
    }

    @Test
    func canceledQueuedWorkDoesNotExecute() async throws {
        let executor = BlockingIOExecutor(maxConcurrentOperations: 1)
        let gate = IOGate()
        let executions = Mutex(0)
        let first = Task { try await executor.run { _ in gate.block() } }
        await gate.waitForArrivals(1)
        let second = Task {
            try await executor.run { _ in executions.withLock { $0 += 1 } }
        }
        while executor.outstandingOperationCount < 2 { await Task.yield() }
        second.cancel()
        #expect(executions.withLock { $0 } == 0)
        gate.release()
        try await first.value
        do {
            try await second.value
            Issue.record("Queued cancellation must throw")
        } catch is CancellationError {}
        #expect(executions.withLock { $0 } == 0)
    }

    @Test
    func workerCancellationContextIsScopedAndObserved() async throws {
        let executor = BlockingIOExecutor(maxConcurrentOperations: 1)
        let gate = IOGate()
        let first = Task {
            try await executor.run { _ in
                let check = BlockingIOExecutor.cancellationCheck()
                gate.block()
                try check()
            }
        }
        await gate.waitForArrivals(1)
        first.cancel()
        gate.release()
        do {
            try await first.value
            Issue.record("Running traversal must observe cancellation")
        } catch is CancellationError {}
        let result = try await executor.run { _ in
            try BlockingIOExecutor.checkCancellation()
            return 42
        }
        #expect(result == 42)
        try BlockingIOExecutor.checkCancellation()
    }

    @Test
    func successAfterSubmissionIsNotChangedIntoCancellation() async throws {
        let executor = BlockingIOExecutor(maxConcurrentOperations: 1)
        let gate = IOGate()
        let task = Task {
            try await executor.run { _ in
                gate.block()
                // Simulates an already-submitted destructive command completing.
                return "confirmed"
            }
        }
        await gate.waitForArrivals(1)
        task.cancel()
        gate.release()
        #expect(try await task.value == "confirmed")
    }

    @Test
    func thrownFailureReleasesWorkerAndContinuation() async throws {
        let executor = BlockingIOExecutor(maxConcurrentOperations: 1)
        do {
            let _: Int = try await executor.run { _ in throw IOErrorForTesting.expected }
            Issue.record("Expected operation failure")
        } catch IOErrorForTesting.expected {}
        let next = try await executor.run { _ in 123 }
        #expect(next == 123)
    }
}
