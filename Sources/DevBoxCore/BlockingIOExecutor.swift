import Foundation
import Synchronization
import os

/// Bounded synchronous I/O outside Swift's cooperative task pool. Awaiting callers
/// suspend on a checked continuation; only OperationQueue workers block on disk or
/// process I/O. Operations aren't canceled through OperationQueue, so every queued
/// continuation is resumed exactly once, including canceled jobs.
final class BlockingIOExecutor: Sendable {
    static let shared = BlockingIOExecutor(maxConcurrentOperations: 4)
    private static let cancellationKey = "app.devbox.blocking-io.cancellation"
    private let queue: OperationQueue
    private let signposter = OSSignposter(subsystem: "app.devbox.DevBox", category: "Blocking I/O")

    enum Priority: Sendable {
        case interactive, normal, background

        var queuePriority: Operation.QueuePriority {
            switch self {
            case .interactive: .high
            case .normal: .normal
            case .background: .low
            }
        }
    }

    final class Cancellation: Sendable {
        private struct State: Sendable {
            var cancelled = false
            var nextHandlerID = 0
            var handlers: [Int: @Sendable () -> Void] = [:]
        }

        private let state = Mutex(State())

        func cancel() {
            let handlers = state.withLock { state -> [@Sendable () -> Void] in
                state.cancelled = true
                defer { state.handlers = [:] }
                return Array(state.handlers.values)
            }
            for handler in handlers { handler() }
        }

        func check() throws {
            if state.withLock({ $0.cancelled }) { throw CancellationError() }
        }

        /// Lets a blocked worker be woken by cancellation, for example by terminating
        /// the child process it waits on. Runs immediately if already canceled. Call the
        /// returned closure once the wait ends so a late cancel doesn't act on a finished job.
        func onCancel(_ handler: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
            let registration: Int? = state.withLock { state in
                guard !state.cancelled else { return nil }
                let id = state.nextHandlerID
                state.nextHandlerID += 1
                state.handlers[id] = handler
                return id
            }
            guard let registration else {
                handler()
                return {}
            }
            return { [self] in state.withLock { _ = $0.handlers.removeValue(forKey: registration) } }
        }
    }

    init(maxConcurrentOperations: Int) {
        precondition(maxConcurrentOperations > 0)
        queue = OperationQueue()
        queue.name = "DevBox blocking I/O"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = maxConcurrentOperations
    }

    /// Includes queued jobs and active workers, useful for diagnostics.
    var outstandingOperationCount: Int { queue.operationCount }

    func run<T: Sendable>(
        priority: Priority = .normal,
        _ operation: @escaping @Sendable (Cancellation) throws -> T
    ) async throws -> T {
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let job = BlockOperation { [signposter] in
                    let interval = signposter.beginInterval("Blocking operation")
                    defer { signposter.endInterval("Blocking operation", interval) }
                    let result = Result {
                        try cancellation.check()
                        return try Self.withCancellationContext(cancellation) {
                            try operation(cancellation)
                        }
                    }
                    // A completed destructive operation remains a success even if
                    // cancellation arrives afterward. Callers suppress stale UI results.
                    continuation.resume(with: result)
                }
                // Reorder queued work only. Running jobs keep their slots until
                // completion/cancellation is observed; there is no preemption.
                job.queuePriority = priority.queuePriority
                queue.addOperation(job)
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// This context is strictly synchronous and never spans an await. It allows
    /// shared Git helpers to honor cancellation without plumbing a token through
    /// every command/parser. Restore nested contexts before reusing a worker.
    private static func withCancellationContext<T>(
        _ cancellation: Cancellation, operation: () throws -> T
    ) rethrows -> T {
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[cancellationKey]
        dictionary[cancellationKey] = cancellation
        defer {
            if let previous { dictionary[cancellationKey] = previous }
            else { dictionary.removeObject(forKey: cancellationKey) }
        }
        return try operation()
    }

    static func checkCancellation() throws {
        try Task.checkCancellation()
        try currentCancellation?.check()
    }

    /// The token of the job running on this worker thread, if any.
    static var currentCancellation: Cancellation? {
        Thread.current.threadDictionary[cancellationKey] as? Cancellation
    }

    /// Capture the worker's token once for a hot traversal loop, rather than
    /// accessing Foundation's thread dictionary for every filesystem entry.
    static func cancellationCheck() -> @Sendable () throws -> Void {
        let cancellation = Thread.current.threadDictionary[cancellationKey] as? Cancellation
        return {
            try Task.checkCancellation()
            try cancellation?.check()
        }
    }
}
