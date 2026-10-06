import DevBoxCore
import Foundation

/// One app-wide limit for size scans, including scans that are winding down after
/// cancellation. The actual synchronous FTS traversal runs in GitService's worker.
/// Two scans leave capacity in the four-worker I/O executor for interactive Git
/// reads. Queue priorities alone cannot make room when all workers are occupied.
@MainActor
final class WorktreeSizeQueue {
    typealias Scan = @Sendable (WorktreeRecord) async throws -> DiskUsage
    typealias GitStorageScan = @Sendable (ProjectRecord) async throws -> DiskUsage

    private struct Job {
        let id = UUID()
        let key: String
        let operation: @Sendable () async throws -> DiskUsage
        let onStarted: @MainActor () -> Void
        let onFinished: @MainActor (Result<DiskUsage, any Error>) -> Void
    }

    private struct Running {
        let job: Job
        let task: Task<Void, Never>
    }

    private let limit: Int
    private let scan: Scan
    private let gitStorageScan: GitStorageScan
    private var pending: [Job] = []
    private var running: [UUID: Running] = [:]

    init(
        limit: Int = 2,
        scan: @escaping Scan = { try await GitService().diskUsage(worktree: $0) },
        gitStorageScan: @escaping GitStorageScan = { try await GitService().gitStorageUsage(project: $0) }
    ) {
        precondition(limit > 0)
        self.limit = limit
        self.scan = scan
        self.gitStorageScan = gitStorageScan
    }

    @discardableResult
    func enqueue(
        _ worktree: WorktreeRecord,
        onStarted: @escaping @MainActor () -> Void,
        onFinished: @escaping @MainActor (Result<DiskUsage, any Error>) -> Void
    ) -> Bool {
        enqueue(key: worktree.id, operation: { [scan] in try await scan(worktree) },
                onStarted: onStarted, onFinished: onFinished)
    }

    @discardableResult
    func enqueueGitStorage(
        _ project: ProjectRecord,
        onStarted: @escaping @MainActor () -> Void,
        onFinished: @escaping @MainActor (Result<DiskUsage, any Error>) -> Void
    ) -> Bool {
        enqueue(key: "git-storage:\(project.id)", operation: { [gitStorageScan] in
            try await gitStorageScan(project)
        }, onStarted: onStarted, onFinished: onFinished)
    }

    private func enqueue(
        key: String,
        operation: @escaping @Sendable () async throws -> DiskUsage,
        onStarted: @escaping @MainActor () -> Void,
        onFinished: @escaping @MainActor (Result<DiskUsage, any Error>) -> Void
    ) -> Bool {
        guard !pending.contains(where: { $0.key == key }),
              !running.values.contains(where: {
                  $0.job.key == key && !$0.task.isCancelled
              }) else { return false }
        pending.append(Job(key: key, operation: operation, onStarted: onStarted, onFinished: onFinished))
        startPending()
        return true
    }

    func cancelAll() {
        pending.removeAll()
        for item in running.values { item.task.cancel() }
        // Keep the occupied slots until FTS actually observes cancellation/exits.
    }

    func cancel(worktreeIDs: Set<String>) {
        pending.removeAll { worktreeIDs.contains($0.key) }
        for item in running.values where worktreeIDs.contains(item.job.key) {
            item.task.cancel()
        }
    }

    private func startPending() {
        while running.count < limit, !pending.isEmpty {
            // A canceled scan still owns its path until it exits. Let unrelated
            // jobs use spare slots, but never overlap two traversals of one tree.
            guard let index = pending.firstIndex(where: { job in
                !running.values.contains { $0.job.key == job.key }
            }) else { break }
            let job = pending.remove(at: index)
            let task = Task { [weak self] in
                let result: Result<DiskUsage, any Error>
                do {
                    try Task.checkCancellation()
                    result = .success(try await job.operation())
                } catch {
                    result = .failure(error)
                }
                self?.finished(job, result: result)
            }
            running[job.id] = Running(job: job, task: task)
            job.onStarted()
        }
    }

    private func finished(_ job: Job, result: Result<DiskUsage, any Error>) {
        guard let item = running.removeValue(forKey: job.id) else { return }
        if !item.task.isCancelled { job.onFinished(result) }
        startPending()
    }
}
