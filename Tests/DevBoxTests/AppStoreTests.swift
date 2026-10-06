import Observation
import Foundation
import Testing
@testable import DevBox
@testable import DevBoxCore

@MainActor
private final class MemorySettings: SettingsPersisting {
    var value = AppSettings()
    var failRead = false
    var failWrite = false
    var writes = 0
    func load() throws -> AppSettings {
        if failRead { throw TestFailure.expected }
        return value
    }
    func save(_ settings: AppSettings) throws {
        writes += 1
        if failWrite { throw TestFailure.expected }
        value = settings
    }
}

@MainActor
private final class MemoryCredentials: CredentialsPersisting {
    var values: [UUID: String] = [:]
    var writes = 0
    var readError: Error?
    var removeError: Error?
    var saveGate: GitHubTestGate<Void>?
    func password(for id: UUID) throws -> String? {
        if let readError { throw readError }
        return values[id]
    }
    func save(password: String, for id: UUID) async throws {
        writes += 1
        if let gate = saveGate {
            saveGate = nil
            await gate.enter()
        }
        values[id] = password
    }
    func remove(for id: UUID) throws {
        if let removeError { throw removeError }
        values.removeValue(forKey: id)
    }
}

private enum TestFailure: Error { case expected }

@Test(.timeLimit(.minutes(1))) @MainActor
func connectionSaveMergesConcurrentSettingsAndRejectsOverlappingCredentialEdits() async throws {
    let persistence = MemorySettings()
    let credentials = MemoryCredentials()
    let project = ProjectRecord(id: "unrelated", name: "Unrelated", path: "/unused")
    persistence.value.projects = [project]
    let original = SavedConnection(name: "Original", settings: .init())
    persistence.value.connections = [original]
    credentials.values[original.id] = "synthetic-old"
    let gate = GitHubTestGate<Void>()
    credentials.saveGate = gate
    let store = AppStore(persistence: persistence, credentials: credentials,
                         listDatabases: { _, _ in [] }, loadStatistics: { _, _ in [:] },
                         editorLauncher: inertEditorLauncher())
    var changed = original
    changed.name = "Changed"
    let save = Task { try await store.saveConnection(changed, password: "synthetic-new") }
    await gate.waitForEntry()
    store.forgetProject(project)
    await #expect(throws: (any Error).self) {
        try await store.saveConnection(original, password: "overlapping")
    }
    await store.forgetConnection(original)
    #expect(store.settings.connections == [original])
    await gate.release(())
    try await save.value
    #expect(store.settings.projects.isEmpty)
    #expect(persistence.value.projects.isEmpty)
    #expect(store.settings.connections == [changed])
    #expect(persistence.value.connections == [changed])
    #expect(credentials.values[original.id] == "synthetic-new")
    #expect(credentials.writes == 1)
}

@Test @MainActor
func connectionReadDenialNeverBecomesMissingPasswordOrAllowsMutation() async {
    let persistence = MemorySettings()
    let credentials = MemoryCredentials()
    let connection = SavedConnection(name: "Existing", settings: .init())
    persistence.value.connections = [connection]
    credentials.values[connection.id] = "synthetic-old"
    credentials.readError = TestFailure.expected
    let store = AppStore(persistence: persistence, credentials: credentials, editorLauncher: inertEditorLauncher())
    await #expect(throws: TestFailure.self) { try await store.password(for: connection.id) }
    await #expect(throws: TestFailure.self) {
        try await store.saveConnection(connection, password: "synthetic-new")
    }
    await store.forgetConnection(connection)
    #expect(store.settings.connections == [connection])
    #expect(credentials.values[connection.id] == "synthetic-old")
    #expect(persistence.writes == 0)
    #expect(credentials.writes == 0)
}

@Test @MainActor
func connectionRemovalPreservesSettingsOnKeychainFailureAndRestoresSecretOnSettingsFailure() async {
    let persistence = MemorySettings()
    let credentials = MemoryCredentials()
    let connection = SavedConnection(name: "Existing", settings: .init())
    persistence.value.connections = [connection]
    credentials.values[connection.id] = "synthetic-old"
    let store = AppStore(persistence: persistence, credentials: credentials, editorLauncher: inertEditorLauncher())
    credentials.removeError = TestFailure.expected
    await store.forgetConnection(connection)
    #expect(store.settings.connections == [connection])
    #expect(persistence.writes == 0)
    credentials.removeError = nil
    persistence.failWrite = true
    await store.forgetConnection(connection)
    #expect(store.settings.connections == [connection])
    #expect(persistence.value.connections == [connection])
    #expect(credentials.values[connection.id] == "synthetic-old")
    #expect(store.errorMessage != nil)
}

@Test @MainActor
func failedSettingsWriteRestoresPreviousPassword() async throws {
    let persistence = MemorySettings()
    let credentials = MemoryCredentials()
    let original = SavedConnection(name: "Original", settings: .init())
    persistence.value.connections = [original]
    credentials.values[original.id] = "old test password"
    persistence.failWrite = true
    let store = AppStore(persistence: persistence, credentials: credentials, editorLauncher: inertEditorLauncher())
    var updated = original
    updated.name = "Changed"
    await #expect(throws: TestFailure.self) {
        try await store.saveConnection(updated, password: "new test password")
    }
    #expect(credentials.values[original.id] == "old test password")
    #expect(store.settings.connections == [original])
    #expect(persistence.value.connections == [original])
}

@Test @MainActor
func failedNewConnectionWriteRemovesOrphanCredential() async {
    let persistence = MemorySettings()
    let credentials = MemoryCredentials()
    persistence.failWrite = true
    let store = AppStore(persistence: persistence, credentials: credentials, editorLauncher: inertEditorLauncher())
    let connection = SavedConnection(name: "New", settings: .init())
    await #expect(throws: TestFailure.self) {
        try await store.saveConnection(connection, password: "test password")
    }
    #expect(credentials.values.isEmpty)
    #expect(store.settings.connections.isEmpty)
}

@Test @MainActor
func unreadableSettingsAreNeverOverwritten() async {
    let persistence = MemorySettings()
    let credentials = MemoryCredentials()
    persistence.failRead = true
    let store = AppStore(persistence: persistence, credentials: credentials, editorLauncher: inertEditorLauncher())
    #expect(store.errorMessage != nil)
    await #expect(throws: (any Error).self) {
        try await store.saveConnection(.init(name: "New", settings: .init()), password: "")
    }
    #expect(persistence.writes == 0)
    #expect(credentials.writes == 0)
}

@Test @MainActor
func destinationChangeClearsBothSelections() {
    let store = AppStore(persistence: MemorySettings(), credentials: MemoryCredentials(), editorLauncher: inertEditorLauncher())
    store.worktreeSelection = ["/previous-project/worktree"]
    store.databaseSelection = ["previous_database"]
    store.destination = .project("another-project")
    #expect(store.worktreeSelection.isEmpty)
    #expect(store.databaseSelection.isEmpty)
}

@Test @MainActor
func authenticationFailureDoesNotStartDeletionOrCloseConfirmation() async {
    let persistence = MemorySettings()
    let credentials = MemoryCredentials()
    var authenticationCalls = 0
    let store = AppStore(persistence: persistence, credentials: credentials, editorLauncher: inertEditorLauncher(), authenticate: { _ in
        authenticationCalls += 1
        throw TestFailure.expected
    })
    // This record does not identify a real database. No credentials or server are used.
    let connection = SavedConnection(name: "Test", settings: .init())
    let request = DeletionRequest(items: .databases(connection, [.init(name: "never_contacted")]))
    store.deletionRequest = request
    await store.delete(request)
    #expect(authenticationCalls == 1)
    #expect(store.deletionRequest?.id == request.id)
    #expect(store.deletionError?.contains("Nothing was deleted.") == true)
    #expect(!store.isDeleting)
    #expect(store.isModalPresented)
    #expect(!store.canDeleteSelection)
}

@Test @MainActor
func staleConfirmationCannotRequestAuthentication() async {
    var authenticationCalls = 0
    let store = AppStore(persistence: MemorySettings(), credentials: MemoryCredentials(), editorLauncher: inertEditorLauncher(), authenticate: { _ in
        authenticationCalls += 1
    })
    let connection = SavedConnection(name: "Test", settings: .init())
    let request = DeletionRequest(items: .databases(connection, [.init(name: "never_contacted")]))
    await store.delete(request)
    #expect(authenticationCalls == 0)
    #expect(!store.isDeleting)
}

@Test @MainActor
func resultsWaitUntilConfirmationDismissal() async throws {
    let store = AppStore(
        persistence: MemorySettings(), credentials: MemoryCredentials(),
        editorLauncher: inertEditorLauncher(), authenticate: { _ in }
    )
    let connection = SavedConnection(name: "Test", settings: .init())
    let request = DeletionRequest(items: .databases(connection, [.init(name: "never_contacted")]))
    store.deletionRequest = request
    // No saved credential: records a per-item error without ever contacting MariaDB.
    await store.delete(request)
    #expect(store.activeSheet == nil)
    #expect(store.isModalPresented)
    store.sheetDidDismiss()
    guard case .results(let result) = store.activeSheet else {
        Issue.record("Results should be presented after confirmation dismissal.")
        return
    }
    #expect(result.entries.count == 1)
    #expect(result.entries[0].state.detail?.contains("Keychain") == true)
}

private actor StoreSizeProbe {
    private var calls: [String: Int] = [:]
    private var held = false
    private var fail = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func hold() { held = true }
    func failScans() { fail = true }
    func count(for id: String) -> Int { calls[id, default: 0] }
    func release() {
        held = false
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }

    func scan(_ record: WorktreeRecord) async throws -> DiskUsage {
        calls[record.id, default: 0] += 1
        let count = calls[record.id, default: 0]
        if held { await withCheckedContinuation { waiters.append($0) } }
        if fail { throw TestFailure.expected }
        return DiskUsage(bytes: Int64(count * 4096), fileCount: count, unreadableCount: 0)
    }
}

private struct StoreGitFixture {
    let root: URL
    let repository: URL

    init() throws {
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        root = project.appendingPathComponent(".build/test-temp/size-ui-\(UUID())")
        repository = root.appendingPathComponent("main")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try git(["init", "-b", "main"])
        try git(["-c", "user.name=Tests", "-c", "user.email=tests@example.invalid",
                 "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "Initial"])
        try git(["worktree", "add", "-b", "feature", root.appendingPathComponent("linked").path])
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    private func git(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repository.path, "-c", "core.hooksPath=/dev/null"] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw TestFailure.expected }
    }
}

@MainActor
private func waitForSizes(_ store: AppStore) async {
    for await rows in Observations({ store.worktrees }) {
        if !rows.isEmpty && rows.allSatisfy({ !$0.isSizeBusy }) { return }
    }
}

@MainActor
private func waitForGitStatus(_ store: AppStore) async {
    for await refreshing in Observations({ store.isRefreshing }) {
        if !refreshing { return }
    }
}

@MainActor
private var testEditorApplication: EditorApplication {
    EditorApplication(
        url: URL(fileURLWithPath: "/test/Editor.app"), name: "Test Editor",
        bundleIdentifier: "test.editor"
    )
}

@Test(.timeLimit(.minutes(1))) @MainActor
func openInEditorUsesRequestedWorktreeWithoutChangingSelectionOrBranches() async throws {
    let fixture = try StoreGitFixture()
    defer { fixture.cleanup() }
    let project = try await GitService().discoverProject(at: fixture.repository.path)
    let persistence = MemorySettings()
    persistence.value.projects = [project]
    persistence.value.preferredEditor = testEditorApplication
    var openedPaths: [String] = []
    let store = AppStore(
        persistence: persistence, credentials: MemoryCredentials(),
        editorLauncher: inertEditorLauncher(),
        openWorktreeInEditor: { path, editor in
            #expect(editor == testEditorApplication)
            openedPaths.append(path)
        }
    )
    store.refresh()
    await waitForGitStatus(store)
    await waitForSizes(store)
    let linked = try #require(store.worktrees.first { !$0.worktree.isMain })
    let main = try #require(store.worktrees.first { $0.worktree.isMain })
    let before = try await GitService().listWorktrees(project: project)
    store.worktreeSelection = [main.id]

    // Right-clicking a different row must open that row, not the current selection.
    #expect(store.canOpenInEditor([linked.id]))
    await store.openInEditor([linked.id])
    #expect(store.worktreeSelection == [main.id])
    // Protection against deletion must not prevent opening the main checkout.
    #expect(store.canOpenInEditor(store.worktreeSelection))
    await store.openInEditor(store.worktreeSelection)

    #expect(openedPaths == [linked.worktree.path, main.worktree.path])
    #expect(store.errorMessage == nil)
    #expect(persistence.writes == 0)
    #expect(try await GitService().listWorktrees(project: project) == before)

    store.projectSection = .branches
    await waitForGitStatus(store)
    #expect(store.worktreeSelection == [main.id])
    #expect(!store.canOpenInEditor([linked.id]))
    await store.openInEditor([linked.id])
    #expect(openedPaths == [linked.worktree.path, main.worktree.path])

    store.projectSection = .worktrees
    await waitForGitStatus(store)
    #expect(store.canOpenInEditor([linked.id]))
}

@Test(.timeLimit(.minutes(1))) @MainActor
func openInEditorRejectsInvalidSelectionsAndAllowsLockedOrDetachedWorktrees() async throws {
    let fixture = try StoreGitFixture()
    defer { fixture.cleanup() }
    let persistence = MemorySettings()
    persistence.value.projects = [try await GitService().discoverProject(at: fixture.repository.path)]
    persistence.value.preferredEditor = testEditorApplication
    var openedPaths: [String] = []
    let store = AppStore(
        persistence: persistence, credentials: MemoryCredentials(),
        editorLauncher: inertEditorLauncher(),
        openWorktreeInEditor: { path, _ in openedPaths.append(path) }
    )
    store.refresh()
    await waitForGitStatus(store)
    await waitForSizes(store)
    let session = try #require(store.selectedProjectSession)
    let records = [
        WorktreeRecord(path: "/test/locked", branch: "locked", head: "", isMain: false, isLocked: true),
        WorktreeRecord(path: "/test/detached", branch: nil, head: "1234", isMain: false),
        WorktreeRecord(path: "/test/missing", branch: "missing", head: "", isMain: false, exists: false),
        WorktreeRecord(path: "/test/bare", branch: nil, head: "", isMain: true, isBare: true)
    ]
    session.reconcile(records, refresh: false)
    let invalidSelections: [Set<String>] = [
        [], ["/test/unknown"], ["/test/missing"], ["/test/bare"],
        ["/test/locked", "/test/detached"], ["/test/locked", "/test/unknown"]
    ]
    for ids in invalidSelections {
        #expect(!store.canOpenInEditor(ids))
        await store.openInEditor(ids)
    }
    #expect(openedPaths.isEmpty)

    for record in records.prefix(2) {
        #expect(store.canOpenInEditor([record.id]))
        await store.openInEditor([record.id])
    }
    #expect(openedPaths == ["/test/locked", "/test/detached"])

    store.connectionEditor = .init()
    #expect(!store.canOpenInEditor(["/test/locked"]))
    await store.openInEditor(["/test/locked"])
    store.connectionEditor = nil
    session.removeConfirmedWorktrees(ids: ["/test/locked"])
    #expect(!store.canOpenInEditor(["/test/locked"]))
    await store.openInEditor(["/test/locked"])
    store.destination = nil
    #expect(!store.canOpenInEditor(["/test/detached"]))
    await store.openInEditor(["/test/detached"])
    #expect(openedPaths.count == 2)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func openInEditorShowsLaunchFailureWithWorktreePath() async throws {
    let fixture = try StoreGitFixture()
    defer { fixture.cleanup() }
    let persistence = MemorySettings()
    persistence.value.projects = [try await GitService().discoverProject(at: fixture.repository.path)]
    persistence.value.preferredEditor = testEditorApplication
    let store = AppStore(
        persistence: persistence, credentials: MemoryCredentials(),
        editorLauncher: inertEditorLauncher(),
        openWorktreeInEditor: { _, _ in
            throw NSError(domain: "EditorTest", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The editor could not be launched."
            ])
        }
    )
    store.refresh()
    await waitForGitStatus(store)
    await waitForSizes(store)
    let linked = try #require(store.worktrees.first { !$0.worktree.isMain })

    await store.openInEditor([linked.id])

    #expect(store.errorMessage?.contains(linked.worktree.path) == true)
    #expect(store.errorMessage?.contains("Test Editor") == true)
    #expect(store.errorMessage?.contains("The editor could not be launched.") == true)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func rowRefreshChangesOnlyItsMeasurementAndPreservesSelection() async throws {
    let fixture = try StoreGitFixture()
    defer { fixture.cleanup() }
    let persistence = MemorySettings()
    persistence.value.projects = [try await GitService().discoverProject(at: fixture.repository.path)]
    let probe = StoreSizeProbe()
    let queue = WorktreeSizeQueue(scan: { try await probe.scan($0) })
    let store = AppStore(persistence: persistence, credentials: MemoryCredentials(), sizeQueue: queue, editorLauncher: inertEditorLauncher())
    store.refresh()
    await waitForGitStatus(store)
    await waitForSizes(store)
    let linked = try #require(store.worktrees.first { !$0.worktree.isMain })
    let main = try #require(store.worktrees.first { $0.worktree.isMain })
    store.worktreeSelection = [linked.id]
    #expect(linked.usage?.fileCount == 1)

    store.refreshWorktreeSize(linked.id)
    #expect(store.worktrees.first { $0.id == linked.id }?.usage?.fileCount == 1)
    #expect(store.worktrees.first { $0.id == linked.id }?.isSizeBusy == true)
    #expect(!store.isRefreshing)
    await waitForSizes(store)
    #expect(store.worktreeSelection == [linked.id])
    #expect(store.worktrees.first { $0.id == linked.id }?.usage?.fileCount == 2)
    #expect(await probe.count(for: linked.id) == 2)
    #expect(await probe.count(for: main.id) == 1)

    await probe.failScans()
    store.refreshWorktreeSize(linked.id)
    await waitForSizes(store)
    let failed = try #require(store.worktrees.first { $0.id == linked.id })
    #expect(failed.usage?.fileCount == 2)
    #expect(failed.usageError != nil)
    #expect(!failed.isSizeBusy)
    #expect(store.canRefreshSize(failed))
}

@Test(.timeLimit(.minutes(1))) @MainActor
func slowSizeScansDoNotBlockGitRefreshOrDeletionConfirmation() async throws {
    let fixture = try StoreGitFixture()
    defer { fixture.cleanup() }
    let persistence = MemorySettings()
    persistence.value.projects = [try await GitService().discoverProject(at: fixture.repository.path)]
    let probe = StoreSizeProbe()
    await probe.hold()
    let queue = WorktreeSizeQueue(scan: { try await probe.scan($0) })
    let store = AppStore(persistence: persistence, credentials: MemoryCredentials(), sizeQueue: queue, editorLauncher: inertEditorLauncher())
    store.refresh()
    await waitForGitStatus(store)
    #expect(store.isMeasuringSizes)
    #expect(!store.isRefreshing)
    let linked = try #require(store.worktrees.first { !$0.worktree.isMain })
    store.worktreeSelection = [linked.id]
    #expect(store.canDeleteSelection)
    store.prepareDeletion()
    #expect(store.deletionRequest?.count == 1)
    #expect(store.worktrees.first { $0.id == linked.id }?.sizeState == .idle)
    await probe.release()
    await waitForSizes(store)
    #expect(store.worktrees.first { $0.id == linked.id }?.usage == nil)
    #expect(FileManager.default.fileExists(atPath: linked.worktree.path))
}
