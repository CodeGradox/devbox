import Observation
import Foundation
import Testing
@testable import DevBox
@testable import DevBoxCore

@MainActor
private final class SessionSettings: SettingsPersisting {
    var value = AppSettings()
    func load() throws -> AppSettings { value }
    func save(_ settings: AppSettings) throws { value = settings }
}

@MainActor
private final class SessionCredentials: CredentialsPersisting {
    func password(for id: UUID) throws -> String? { nil }
    func save(password: String, for id: UUID) throws {}
    func remove(for id: UUID) throws {}
}

private enum SessionFailure: Error { case expected }

private actor SessionSizeProbe {
    private var calls: [String: Int] = [:]
    private var fails = false
    private var holdLinked = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var started: [CheckedContinuation<Void, Never>] = []

    func count(_ id: String) -> Int { calls[id, default: 0] }
    func failScans() { fails = true }
    func holdLinkedScans() { holdLinked = true }
    func waitForHeldScan() async {
        if !held.isEmpty { return }
        await withCheckedContinuation { started.append($0) }
    }
    func release() {
        holdLinked = false
        let pending = held
        held = []
        for waiter in pending { waiter.resume() }
    }

    func scan(_ record: WorktreeRecord) async throws -> DiskUsage {
        calls[record.id, default: 0] += 1
        if holdLinked && !record.isMain {
            await withCheckedContinuation { continuation in
                held.append(continuation)
                for waiter in started { waiter.resume() }
                started = []
            }
        }
        try Task.checkCancellation()
        if fails { throw SessionFailure.expected }
        let count = calls[record.id, default: 0]
        return DiskUsage(bytes: Int64(count * 4096), fileCount: count, unreadableCount: 0)
    }
}

private struct SessionRepositories {
    let root: URL
    let a: URL
    let b: URL

    init() throws {
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        root = project.appendingPathComponent(".build/test-temp/session-cache-\(UUID())")
        a = root.appendingPathComponent("a")
        b = root.appendingPathComponent("b")
        for repository in [a, b] {
            try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
            try Self.git(["init", "-b", "main"], at: repository)
            try Self.git(["-c", "user.name=Tests", "-c", "user.email=tests@example.invalid",
                          "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "Initial"],
                         at: repository)
        }
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    func addLinkedWorktree() throws {
        try Self.git(["worktree", "add", "-b", "feature", root.appendingPathComponent("linked").path],
                     at: a)
    }

    private static func git(_ arguments: [String], at repository: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repository.path, "-c", "core.hooksPath=/dev/null"] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw SessionFailure.expected }
    }
}

@MainActor
private func waitForSessionLoad(_ store: AppStore) async {
    for await refreshing in Observations({ store.isRefreshing }) {
        if !refreshing { break }
    }
    for await rows in Observations({ store.worktrees }) {
        if !rows.isEmpty && rows.allSatisfy({ !$0.isSizeBusy }) { return }
    }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func projectSessionRestoresSnapshotUntilExplicitRefreshAndDoesNotPersistIt() async throws {
    let fixture = try SessionRepositories()
    defer { fixture.cleanup() }
    let persistence = SessionSettings()
    let a = try await GitService().discoverProject(at: fixture.a.path)
    let b = try await GitService().discoverProject(at: fixture.b.path)
    persistence.value.projects = [a, b]
    let probe = SessionSizeProbe()
    let store = AppStore(persistence: persistence, credentials: SessionCredentials(),
                         sizeQueue: WorktreeSizeQueue(scan: { try await probe.scan($0) }))
    store.loadSelection()
    await waitForSessionLoad(store)
    let original = try #require(store.worktrees.first)
    #expect(original.status?.isClean == true)
    #expect(original.usage?.fileCount == 1)
    #expect(original.measuredAt != nil)

    store.worktreeSelection = [original.id]
    store.destination = .project(b.id)
    await waitForSessionLoad(store)
    #expect(store.worktreeSelection.isEmpty)
    try Data("external change".utf8).write(to: fixture.a.appendingPathComponent("untracked.txt"))
    store.worktreeSelection = Set(store.worktrees.map(\.id))
    store.destination = .project(a.id)
    await waitForSessionLoad(store)
    let cached = try #require(store.worktrees.first)
    #expect(store.worktreeSelection.isEmpty)
    #expect(cached.status?.isClean == true)
    #expect(cached.usage?.bytes == original.usage?.bytes)
    #expect(cached.measuredAt == original.measuredAt)
    #expect(await probe.count(original.id) == 1)

    // Repeated initial-load requests must also use the same session snapshot.
    store.loadSelection()
    await waitForSessionLoad(store)
    #expect(await probe.count(original.id) == 1)

    store.refresh()
    await waitForSessionLoad(store)
    let refreshed = try #require(store.worktrees.first)
    #expect(refreshed.status?.untracked == 1)
    #expect(refreshed.usage?.fileCount == 2)
    #expect(await probe.count(original.id) == 2)

    try Data("another external change".utf8).write(to: fixture.a.appendingPathComponent("another.txt"))
    let reopened = AppStore(persistence: persistence, credentials: SessionCredentials(),
                            sizeQueue: WorktreeSizeQueue(scan: { try await probe.scan($0) }))
    reopened.loadSelection()
    await waitForSessionLoad(reopened)
    let fresh = try #require(reopened.worktrees.first)
    #expect(fresh.status?.untracked == 2)
    #expect(fresh.usage?.fileCount == 3)
    #expect(await probe.count(original.id) == 3)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func projectRefreshPreservesVisibleRowsWhileAwaitingMeasurements() async throws {
    let fixture = try SessionRepositories()
    defer { fixture.cleanup() }
    try fixture.addLinkedWorktree()
    let persistence = SessionSettings()
    persistence.value.projects = [try await GitService().discoverProject(at: fixture.a.path)]
    let probe = SessionSizeProbe()
    let store = AppStore(persistence: persistence, credentials: SessionCredentials(),
                         sizeQueue: WorktreeSizeQueue(scan: { try await probe.scan($0) }))
    store.loadSelection()
    await waitForSessionLoad(store)
    let session = try #require(store.selectedProjectSession)
    let originalStates = session.rows
    let originalRows = store.worktrees
    let linked = try #require(originalRows.first { !$0.worktree.isMain })

    await probe.holdLinkedScans()
    store.refresh()

    // Before the load task can run, the previous inventory and content remain visible.
    #expect(store.selectedProjectSession === session)
    #expect(store.worktrees.map(\.id) == originalRows.map(\.id))
    #expect(zip(originalStates, session.rows).allSatisfy { $0 === $1 })
    for old in originalRows {
        let current = try #require(session.row(id: old.id)?.row)
        #expect(current.usage?.bytes == old.usage?.bytes)
        #expect(current.measuredAt == old.measuredAt)
        #expect(current.status?.isClean == old.status?.isClean)
    }

    await probe.waitForHeldScan()
    let pending = try #require(session.row(id: linked.id)?.row)
    #expect(pending.isSizeBusy)
    #expect(pending.usage?.bytes == linked.usage?.bytes)
    #expect(pending.measuredAt == linked.measuredAt)
    #expect(store.worktrees.map(\.id) == originalRows.map(\.id))
    #expect(zip(originalStates, session.rows).allSatisfy { $0 === $1 })

    await probe.release()
    await waitForSessionLoad(store)
    #expect(session.row(id: linked.id)?.row.usage?.fileCount == 2)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func rowMeasurementAndFailureRemainInProjectSessionAfterSwitching() async throws {
    let fixture = try SessionRepositories()
    defer { fixture.cleanup() }
    let persistence = SessionSettings()
    let a = try await GitService().discoverProject(at: fixture.a.path)
    let b = try await GitService().discoverProject(at: fixture.b.path)
    persistence.value.projects = [a, b]
    let probe = SessionSizeProbe()
    let store = AppStore(persistence: persistence, credentials: SessionCredentials(),
                         sizeQueue: WorktreeSizeQueue(scan: { try await probe.scan($0) }))
    store.loadSelection()
    await waitForSessionLoad(store)
    let id = try #require(store.worktrees.first?.id)
    store.refreshWorktreeSize(id)
    await waitForSessionLoad(store)
    let measured = try #require(store.worktrees.first)
    #expect(measured.usage?.fileCount == 2)
    store.destination = .project(b.id)
    await waitForSessionLoad(store)
    store.destination = .project(a.id)
    await waitForSessionLoad(store)
    #expect(store.worktrees.first?.usage?.fileCount == 2)
    #expect(store.worktrees.first?.measuredAt == measured.measuredAt)
    #expect(await probe.count(id) == 2)

    await probe.failScans()
    store.refreshWorktreeSize(id)
    await waitForSessionLoad(store)
    let failed = try #require(store.worktrees.first)
    #expect(failed.usageError != nil)
    store.destination = .project(b.id)
    await waitForSessionLoad(store)
    store.destination = .project(a.id)
    await waitForSessionLoad(store)
    let restored = try #require(store.worktrees.first)
    #expect(restored.usageError == failed.usageError)
    #expect(restored.usage?.bytes == measured.usage?.bytes)
    #expect(restored.measuredAt == measured.measuredAt)
    #expect(!restored.isSizeBusy)
    #expect(await probe.count(id) == 3)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func returningToProjectResumesOnlyUnfinishedSizeMeasurements() async throws {
    let fixture = try SessionRepositories()
    defer { fixture.cleanup() }
    try fixture.addLinkedWorktree()
    let persistence = SessionSettings()
    let a = try await GitService().discoverProject(at: fixture.a.path)
    let b = try await GitService().discoverProject(at: fixture.b.path)
    persistence.value.projects = [a, b]
    let probe = SessionSizeProbe()
    await probe.holdLinkedScans()
    let store = AppStore(persistence: persistence, credentials: SessionCredentials(),
                         sizeQueue: WorktreeSizeQueue(scan: { try await probe.scan($0) }))
    store.loadSelection()
    for await rows in Observations({ store.worktrees }) {
        if rows.contains(where: { $0.worktree.isMain && $0.measuredAt != nil }) { break }
    }
    for await refreshing in Observations({ store.isRefreshing }) {
        if !refreshing { break }
    }
    await probe.waitForHeldScan()
    let main = try #require(store.worktrees.first { $0.worktree.isMain })
    let linked = try #require(store.worktrees.first { !$0.worktree.isMain })
    #expect(linked.isSizeBusy)
    #expect(linked.measuredAt == nil)
    store.destination = .project(b.id)
    await probe.release()
    await waitForSessionLoad(store)
    store.destination = .project(a.id)
    await waitForSessionLoad(store)
    #expect(await probe.count(main.id) == 1)
    #expect(await probe.count(linked.id) == 2)
    #expect(store.worktrees.first { $0.id == main.id }?.measuredAt == main.measuredAt)
    #expect(store.worktrees.first { $0.id == linked.id }?.measuredAt != nil)
    #expect(store.worktrees.allSatisfy { !$0.isSizeBusy })
}

@Test(.timeLimit(.minutes(1))) @MainActor
func canceledDeletionDoesNotForgetPendingRemeasurement() async throws {
    let fixture = try SessionRepositories()
    defer { fixture.cleanup() }
    try fixture.addLinkedWorktree()
    let persistence = SessionSettings()
    let a = try await GitService().discoverProject(at: fixture.a.path)
    let b = try await GitService().discoverProject(at: fixture.b.path)
    persistence.value.projects = [a, b]
    let probe = SessionSizeProbe()
    let store = AppStore(persistence: persistence, credentials: SessionCredentials(),
                         sizeQueue: WorktreeSizeQueue(scan: { try await probe.scan($0) }))
    store.loadSelection()
    await waitForSessionLoad(store)
    let linked = try #require(store.worktrees.first { !$0.worktree.isMain })
    await probe.holdLinkedScans()
    store.refreshWorktreeSize(linked.id)
    await probe.waitForHeldScan()
    store.worktreeSelection = [linked.id]
    store.prepareDeletion()
    #expect(store.deletionRequest?.count == 1)
    store.deletionRequest = nil
    store.sheetDidDismiss()
    store.destination = .project(b.id)
    await probe.release()
    await waitForSessionLoad(store)
    store.destination = .project(a.id)
    await waitForSessionLoad(store)
    let updated = try #require(store.worktrees.first { $0.id == linked.id })
    #expect(await probe.count(linked.id) == 3)
    #expect(updated.usage?.fileCount == 3)
    #expect(updated.measuredAt != linked.measuredAt)
    #expect(!updated.sizeRefreshPending)
}
