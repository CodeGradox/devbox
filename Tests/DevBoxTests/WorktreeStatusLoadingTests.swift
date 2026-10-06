import Foundation
import Observation
import Testing
@testable import DevBox
@testable import DevBoxCore

@MainActor
private final class StatusSettings: SettingsPersisting {
    var value = AppSettings()
    func load() throws -> AppSettings { value }
    func save(_ settings: AppSettings) throws { value = settings }
}

@MainActor
private final class StatusCredentials: CredentialsPersisting {
    func password(for id: UUID) throws -> String? {
        Issue.record("Status loading must not read credentials")
        return nil
    }
    func save(password: String, for id: UUID) throws {}
    func remove(for id: UUID) throws {}
}

private enum StatusFailure: Error, LocalizedError {
    case expected
    var errorDescription: String? { "Expected status failure" }
}

/// Deliberately ignores cancellation while held, like an already-running Git
/// process. This exercises response fencing as well as submission cancellation.
private actor StatusGate {
    private var records: [WorktreeRecord] = []
    private var pending: [Int: CheckedContinuation<GitStatus, Error>] = [:]
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var maximumActive = 0

    func load(_ record: WorktreeRecord) async throws -> GitStatus {
        let index = records.count
        records.append(record)
        return try await withCheckedThrowingContinuation { continuation in
            pending[index] = continuation
            maximumActive = max(maximumActive, pending.count)
            let ready = waiters.filter { records.count >= $0.0 }
            waiters.removeAll { records.count >= $0.0 }
            for (_, waiter) in ready { waiter.resume() }
        }
    }

    func waitForStarts(_ count: Int) async {
        if records.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func started() -> [WorktreeRecord] { records }

    func finish(_ index: Int, modified: Int = 0, fail: Bool = false) {
        guard let continuation = pending.removeValue(forKey: index) else {
            Issue.record("Missing held status operation \(index)")
            return
        }
        if fail {
            continuation.resume(throwing: StatusFailure.expected)
        } else {
            continuation.resume(returning: GitStatus(staged: 0, modified: modified, untracked: 0, conflicted: 0))
        }
    }
}

@MainActor
private func statusStore(_ gate: StatusGate) -> AppStore {
    let settings = StatusSettings()
    settings.value.projects = ["a", "b"].map {
        ProjectRecord(id: $0, name: $0, path: "/status-tests/\($0)")
    }
    return AppStore(
        persistence: settings, credentials: StatusCredentials(),
        sizeQueue: WorktreeSizeQueue(
            scan: { _ in throw StatusFailure.expected },
            gitStorageScan: { _ in throw StatusFailure.expected }
        ),
        inspectBranches: { _, _ in throw StatusFailure.expected },
        loadGitStatus: { try await gate.load($0) },
        editorLauncher: inertEditorLauncher()
    )
}

private func statusRecords(_ count: Int, prefix: String = "a") -> [WorktreeRecord] {
    (0..<count).map {
        WorktreeRecord(path: "/status-tests/\(prefix)/\($0)", branch: "branch-\($0)", head: "abc", isMain: false)
    }
}

/// Seed the inventory synchronously before the initial discovery task can run,
/// then exercise the normal cached-row resumption path. No host Git/editor I/O.
@MainActor
private func seedStatusInventory(_ store: AppStore, _ records: [WorktreeRecord]) throws {
    store.loadSelection()
    let session = try #require(store.selectedProjectSession)
    session.reconcile(records, refresh: true)
    store.loadSelection()
}

@MainActor
private func waitForStatus(_ store: AppStore, id: String) async {
    for await rows in Observations({ store.worktrees }) {
        if let row = rows.first(where: { $0.id == id }), !row.needsStatusLoad { return }
    }
}

@MainActor
private func waitForStatuses(_ store: AppStore) async {
    for await refreshing in Observations({ store.isRefreshing }) {
        if !refreshing { return }
    }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func worktreeStatusesUseTwoSlotsAndPublishEachCompletion() async throws {
    let gate = StatusGate()
    let store = statusStore(gate)
    let records = statusRecords(12)
    try seedStatusInventory(store, records)
    // Neither operation has completed: a sequential loader cannot get here.
    await gate.waitForStarts(2)
    #expect(await gate.started().count == 2)
    #expect(store.worktrees.allSatisfy { $0.status == nil })

    // Finish out of order; the first, held row must not block publication.
    let started = await gate.started()
    await gate.finish(1, modified: 7)
    await waitForStatus(store, id: started[1].id)
    #expect(store.worktrees.first { $0.id == started[1].id }?.status?.modified == 7)
    #expect(store.worktrees.first { $0.id == started[0].id }?.status == nil)
    #expect(store.isRefreshing)
    await gate.waitForStarts(3)
    #expect(await gate.started().count == 3)

    // A per-row failure consumes only its own slot, not its sibling's.
    await gate.finish(0, fail: true)
    await waitForStatus(store, id: started[0].id)
    #expect(store.worktrees.first { $0.id == started[0].id }?.statusError == "Expected status failure")
    for index in 2..<records.count {
        await gate.waitForStarts(index + 1)
        let calls = await gate.started()
        await gate.finish(index, modified: index)
        await waitForStatus(store, id: calls[index].id)
    }
    await waitForStatuses(store)
    #expect(await gate.started().count == records.count)
    #expect(await gate.maximumActive == 2)
    #expect(store.worktrees.allSatisfy { !$0.needsStatusLoad })
}

@Test(.timeLimit(.minutes(1))) @MainActor
func worktreeStatusesSkipInvalidAndAlreadyCachedRows() async throws {
    let gate = StatusGate()
    let store = statusStore(gate)
    let valid = statusRecords(3)
    let invalid = [
        WorktreeRecord(path: "/status-tests/missing", branch: nil, head: "", isMain: false, exists: false),
        WorktreeRecord(path: "/status-tests/bare", branch: nil, head: "", isMain: true, isBare: true)
    ]
    store.loadSelection()
    let session = try #require(store.selectedProjectSession)
    session.reconcile(valid + invalid, refresh: false)
    session.updateRow(valid[0].id) {
        $0.status = GitStatus(staged: 0, modified: 42, untracked: 0, conflicted: 0)
    }
    store.loadSelection()
    await gate.waitForStarts(2)
    #expect(Set(await gate.started().map(\.id)) == Set(valid.dropFirst().map(\.id)))
    await gate.finish(0)
    await gate.finish(1)
    await waitForStatuses(store)
    #expect(await gate.started().count == 2)
    #expect(store.worktrees.first { $0.id == valid[0].id }?.status?.modified == 42)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func cancelledStatusBatchCannotOverwriteAnotherProjectOrResumeItsQueue() async throws {
    let gate = StatusGate()
    let store = statusStore(gate)
    let old = statusRecords(8)
    try seedStatusInventory(store, old)
    let oldSession = try #require(store.selectedProjectSession)
    await gate.waitForStarts(2)
    store.destination = .project("b")
    let replacement = statusRecords(2, prefix: "b")
    try seedStatusInventory(store, replacement)
    await gate.waitForStarts(4)
    await gate.finish(0, modified: 99)
    await gate.finish(1, fail: true)
    await gate.finish(2, modified: 3)
    await gate.finish(3, modified: 3)
    await waitForStatuses(store)
    #expect(Set(store.worktrees.map(\.id)) == Set(replacement.map(\.id)))
    #expect(store.worktrees.allSatisfy { $0.status?.modified == 3 && $0.statusError == nil })
    #expect(oldSession.snapshots.allSatisfy { $0.status == nil && $0.statusError == nil })
    #expect(await gate.started().count == 4)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func staleStatusBatchCannotOverwriteRefreshedRowsOrResurrectDeletedRows() async throws {
    let gate = StatusGate()
    let store = statusStore(gate)
    let records = statusRecords(6)
    try seedStatusInventory(store, records)
    await gate.waitForStarts(2)
    let session = try #require(store.selectedProjectSession)
    // Restart on the same cached inventory, fencing the old generation.
    store.loadSelection()
    await gate.waitForStarts(4)
    let calls = await gate.started()
    session.removeConfirmedWorktrees(ids: [calls[2].id])
    await gate.finish(2, modified: 5)
    await gate.finish(3, modified: 5)
    await waitForStatus(store, id: calls[3].id)
    // Old success/error responses arrive after the replacement row is visible,
    // while the new batch still has work outstanding.
    await gate.finish(0, modified: 99)
    await gate.finish(1, fail: true)
    for index in 4..<8 {
        await gate.waitForStarts(index + 1)
        await gate.finish(index, modified: 5)
    }
    await waitForStatuses(store)
    #expect(await gate.started().count == 8)
    #expect(store.worktrees.count == 5)
    #expect(!store.worktrees.contains { $0.id == calls[2].id })
    #expect(store.worktrees.allSatisfy { $0.status?.modified == 5 && $0.statusError == nil })
}
