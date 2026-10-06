import Foundation
import Testing
@testable import DevBox
@testable import DevBoxCore

/// Continuations deliberately ignore cancellation, like a synchronous traversal
/// that has not yet reached its next cancellation check.
private actor ControlledSizeScanner {
    private var scans: [String: CheckedContinuation<DiskUsage, any Error>] = [:]
    private var arrivals: [String: CheckedContinuation<Void, Never>] = [:]
    private(set) var peakConcurrency = 0

    func scan(_ worktree: WorktreeRecord) async throws -> DiskUsage {
        try await withCheckedThrowingContinuation { continuation in
            precondition(scans[worktree.id] == nil)
            scans[worktree.id] = continuation
            peakConcurrency = max(peakConcurrency, scans.count)
            arrivals.removeValue(forKey: worktree.id)?.resume()
        }
    }

    func waitForScan(_ id: String) async {
        if scans[id] != nil { return }
        await withCheckedContinuation { arrivals[id] = $0 }
    }

    func succeed(_ id: String, bytes: Int64 = 123) {
        scans.removeValue(forKey: id)!.resume(
            returning: DiskUsage(bytes: bytes, fileCount: 2, unreadableCount: 1)
        )
    }

    func fail(_ id: String) {
        scans.removeValue(forKey: id)!.resume(throwing: ScanFailure.expected)
    }
}

private enum ScanFailure: Error {
    case expected
}

/// Blocks actual I/O workers without blocking the test's MainActor.
private final class SizeWorkerGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var permits = 0
    private var arrivals = 0
    private var waiter: CheckedContinuation<Void, Never>?

    func block() {
        condition.lock()
        arrivals += 1
        if arrivals == 2 {
            let ready = waiter
            waiter = nil
            ready?.resume()
        }
        while permits == 0 { condition.wait() }
        permits -= 1
        condition.unlock()
    }

    func waitForTwo() async {
        await withCheckedContinuation { continuation in
            condition.lock()
            if arrivals >= 2 { continuation.resume() } else { waiter = continuation }
            condition.unlock()
        }
    }

    func releaseAll() {
        condition.lock()
        permits += 4
        condition.broadcast()
        condition.unlock()
    }
}

@MainActor
private final class SizeQueueEvents {
    var started: [String] = []
    var finished: [(String, Result<DiskUsage, any Error>)] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func enqueue(_ id: String, in queue: WorktreeSizeQueue, label: String? = nil) -> Bool {
        let label = label ?? id
        return queue.enqueue(
            WorktreeRecord(path: id, branch: nil, head: "test", isMain: false),
            onStarted: { self.started.append(label) },
            onFinished: { result in
                self.finished.append((label, result))
                let ready = self.waiters.filter { $0.0 <= self.finished.count }
                self.waiters.removeAll { $0.0 <= self.finished.count }
                for (_, continuation) in ready { continuation.resume() }
            }
        )
    }

    func waitForFinished(_ count: Int) async {
        if finished.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
}

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct WorktreeSizeQueueTests {
    @Test
    func defaultScansLeaveWorkersAvailableForInteractiveReads() async throws {
        let executor = BlockingIOExecutor(maxConcurrentOperations: 4)
        let gate = SizeWorkerGate()
        defer { gate.releaseAll() }
        let queue = WorktreeSizeQueue(scan: { _ in
            try await executor.run(priority: .background) { _ in
                gate.block()
                return DiskUsage(bytes: 10, fileCount: 1, unreadableCount: 0)
            }
        })
        let events = SizeQueueEvents()
        for id in ["a", "b", "c", "d"] { #expect(events.enqueue(id, in: queue)) }
        guard events.started == ["a", "b"] else {
            Issue.record("Background scans must not occupy all four I/O workers")
            gate.releaseAll()
            await events.waitForFinished(4)
            return
        }
        await gate.waitForTwo()
        // These finish while both scan workers are deliberately held. No timing
        // threshold or scheduler sleep is needed to prove interactive capacity.
        let reads = (0..<2).map { value in
            Task { try await executor.run(priority: .interactive) { _ in value } }
        }
        for (value, read) in reads.enumerated() { #expect(try await read.value == value) }
        #expect(events.finished.isEmpty)
        gate.releaseAll()
        await events.waitForFinished(4)
    }

    @Test
    func concurrencyCapAndPendingJobsAdvance() async throws {
        let scanner = ControlledSizeScanner()
        let queue = WorktreeSizeQueue(scan: { try await scanner.scan($0) })
        let events = SizeQueueEvents()
        for id in ["a", "b", "c", "d"] {
            #expect(events.enqueue(id, in: queue))
        }
        #expect(events.started == ["a", "b"])
        await scanner.waitForScan("a")
        await scanner.waitForScan("b")

        await scanner.succeed("b")
        await scanner.waitForScan("c")
        #expect(events.started == ["a", "b", "c"])
        #expect(events.finished.map(\.0) == ["b"])

        await scanner.succeed("a")
        await scanner.waitForScan("d")
        #expect(events.started == ["a", "b", "c", "d"])
        await scanner.succeed("c")
        await scanner.succeed("d")
        await events.waitForFinished(4)
        #expect(await scanner.peakConcurrency == 2)
        for (_, result) in events.finished {
            let usage = try result.get()
            #expect(usage.bytes == 123)
            #expect(usage.fileCount == 2)
            #expect(usage.unreadableCount == 1)
        }
    }

    @Test
    func duplicatesAreSuppressedWhileRunningAndPending() async {
        let scanner = ControlledSizeScanner()
        let queue = WorktreeSizeQueue(limit: 1, scan: { try await scanner.scan($0) })
        let events = SizeQueueEvents()
        #expect(events.enqueue("a", in: queue))
        await scanner.waitForScan("a")
        #expect(!events.enqueue("a", in: queue, label: "duplicate-running"))
        #expect(events.enqueue("b", in: queue))
        #expect(!events.enqueue("b", in: queue, label: "duplicate-pending"))
        await scanner.succeed("a")
        await scanner.waitForScan("b")
        await scanner.succeed("b")
        await events.waitForFinished(2)
        #expect(events.started == ["a", "b"])
        #expect(events.finished.map(\.0) == ["a", "b"])
        // Completion also clears the duplicate-suppression state.
        #expect(events.enqueue("a", in: queue))
        await scanner.waitForScan("a")
        await scanner.succeed("a")
        await events.waitForFinished(3)
    }

    @Test
    func cancelQueuedJobLeavesOtherJobsUntouched() async {
        let scanner = ControlledSizeScanner()
        let queue = WorktreeSizeQueue(limit: 1, scan: { try await scanner.scan($0) })
        let events = SizeQueueEvents()
        for id in ["a", "b", "c"] { #expect(events.enqueue(id, in: queue)) }
        await scanner.waitForScan("a")
        queue.cancel(worktreeIDs: ["b", "not-enqueued"])
        await scanner.succeed("a")
        await scanner.waitForScan("c")
        await scanner.succeed("c")
        await events.waitForFinished(2)
        #expect(events.started == ["a", "c"])
        #expect(events.finished.map(\.0) == ["a", "c"])
        #expect(events.enqueue("b", in: queue))
        await scanner.waitForScan("b")
        await scanner.succeed("b")
        await events.waitForFinished(3)
    }

    @Test(arguments: [false, true])
    func cancellationKeepsSlotUntilScanExitsAndAllowsReplacement(cancelAll: Bool) async throws {
        let scanner = ControlledSizeScanner()
        let queue = WorktreeSizeQueue(limit: 1, scan: { try await scanner.scan($0) })
        let events = SizeQueueEvents()
        #expect(events.enqueue("a", in: queue, label: "old"))
        await scanner.waitForScan("a")
        #expect(events.enqueue("b", in: queue, label: "discarded"))
        if cancelAll {
            queue.cancelAll()
        } else {
            queue.cancel(worktreeIDs: ["a", "b"])
        }
        #expect(events.enqueue("a", in: queue, label: "replacement"))
        #expect(events.enqueue("c", in: queue))
        #expect(events.started == ["old"])
        #expect(events.finished.isEmpty)

        await scanner.succeed("a", bytes: 1)
        await scanner.waitForScan("a")
        #expect(events.started == ["old", "replacement"])
        #expect(events.finished.isEmpty)
        await scanner.succeed("a", bytes: 456)
        await scanner.waitForScan("c")
        #expect(events.finished.map(\.0) == ["replacement"])
        let usage = try #require(events.finished.first).1.get()
        #expect(usage.bytes == 456)
        await scanner.succeed("c")
        await events.waitForFinished(2)
        #expect(events.started == ["old", "replacement", "c"])
        #expect(events.finished.map(\.0) == ["replacement", "c"])
        #expect(await scanner.peakConcurrency == 1)
    }

    @Test
    func replacementWaitsForSamePathEvenWithSpareSlots() async {
        let scanner = ControlledSizeScanner()
        let queue = WorktreeSizeQueue(limit: 4, scan: { try await scanner.scan($0) })
        let events = SizeQueueEvents()
        #expect(events.enqueue("a", in: queue, label: "old"))
        await scanner.waitForScan("a")
        queue.cancelAll()
        #expect(events.enqueue("a", in: queue, label: "replacement"))
        #expect(events.enqueue("b", in: queue))
        #expect(events.started == ["old", "b"])
        await scanner.waitForScan("b")
        await scanner.succeed("a")
        await scanner.waitForScan("a")
        #expect(events.started == ["old", "b", "replacement"])
        #expect(events.finished.isEmpty)
        await scanner.succeed("a")
        await scanner.succeed("b")
        await events.waitForFinished(2)
        #expect(events.finished.map(\.0).sorted() == ["b", "replacement"])
        #expect(await scanner.peakConcurrency == 2)
    }

    @Test
    func sharedGitStorageUsesTheSameConcurrencyBudget() async {
        let scanner = ControlledSizeScanner()
        let project = ProjectRecord(id: "/project/.git", name: "Project", path: "/project")
        let queue = WorktreeSizeQueue(
            limit: 2,
            scan: { try await scanner.scan($0) },
            gitStorageScan: { _ in
                try await scanner.scan(.init(path: "metadata", branch: nil, head: "", isMain: true))
            }
        )
        let events = SizeQueueEvents()
        #expect(events.enqueue("a", in: queue))
        let accepted = queue.enqueueGitStorage(project, onStarted: {
            events.started.append("metadata")
        }, onFinished: {
            events.finished.append(("metadata", $0))
        })
        #expect(accepted)
        let duplicate = queue.enqueueGitStorage(project, onStarted: {}, onFinished: { _ in })
        #expect(!duplicate)
        #expect(events.enqueue("b", in: queue))
        #expect(events.started == ["a", "metadata"])
        await scanner.waitForScan("a")
        await scanner.waitForScan("metadata")
        await scanner.succeed("metadata")
        await scanner.waitForScan("b")
        #expect(events.started == ["a", "metadata", "b"])
        await scanner.succeed("a")
        await scanner.succeed("b")
        await events.waitForFinished(3)
        #expect(await scanner.peakConcurrency == 2)
    }

    @Test
    func failureIsReportedAndReleasesSlot() async throws {
        let scanner = ControlledSizeScanner()
        let queue = WorktreeSizeQueue(limit: 1, scan: { try await scanner.scan($0) })
        let events = SizeQueueEvents()
        #expect(events.enqueue("a", in: queue))
        #expect(events.enqueue("b", in: queue))
        await scanner.waitForScan("a")
        await scanner.fail("a")
        await scanner.waitForScan("b")
        #expect(events.finished.map(\.0) == ["a"])
        let result = try #require(events.finished.first).1
        switch result {
        case .success:
            Issue.record("Expected the scanner failure to reach onFinished")
        case .failure(let error):
            #expect(error is ScanFailure)
        }
        await scanner.succeed("b")
        await events.waitForFinished(2)
        #expect(events.started == ["a", "b"])
        #expect(events.finished.map(\.0) == ["a", "b"])
    }
}
