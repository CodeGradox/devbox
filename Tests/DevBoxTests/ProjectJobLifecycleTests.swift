import Foundation
import Observation
import Testing
@testable import DevBox
@testable import DevBoxCore

@MainActor
private final class LifecycleSettings: SettingsPersisting {
    var value = AppSettings(projects: ["a", "b"].map {
        ProjectRecord(id: $0, name: $0, path: "/lifecycle-tests/\($0)")
    })
    func load() throws -> AppSettings { value }
    func save(_ settings: AppSettings) throws { value = settings }
}

/// Intentionally ignores cancellation until released, like an already-running
/// subprocess. This tests result fencing, not just cooperative mocks.
private actor LifecycleGate<Value: Sendable> {
    private var pending: [Int: CheckedContinuation<Value, Never>] = [:]
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var starts = 0
    private(set) var canceledCompletions = 0

    func run() async -> Value {
        let index = starts
        starts += 1
        let value = await withCheckedContinuation { continuation in
            pending[index] = continuation
            let ready = waiters.filter { starts >= $0.0 }
            waiters.removeAll { starts >= $0.0 }
            for (_, waiter) in ready { waiter.resume() }
        }
        if Task.isCancelled { canceledCompletions += 1 }
        return value
    }

    func waitForStarts(_ count: Int) async {
        if starts >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func finish(_ index: Int = 0, with value: Value) {
        pending.removeValue(forKey: index)?.resume(returning: value)
    }
}

private let lifecycleRecord = WorktreeRecord(
    path: "/lifecycle-tests/a/topic", branch: "topic", head: "abc", isMain: false
)
private let lifecycleStatus = GitStatus(staged: 0, modified: 7, untracked: 0, conflicted: 0)
private let lifecycleUsage = DiskUsage(bytes: 123, fileCount: 4, unreadableCount: 0)
private let lifecycleBranch = ManagedBranch(
    reference: "refs/heads/topic", name: "topic", commit: "abc", committerName: "", committerEmail: ""
)
private let lifecycleTargets = [
    BranchTarget(reference: "refs/heads/a", label: "a"),
    BranchTarget(reference: "refs/heads/b", label: "b")
]

private actor LifecycleInputs {
    private(set) var projects: [ProjectRecord] = []
    private(set) var rows: [[WorktreeRecord]] = []
    func record(_ project: ProjectRecord, _ records: [WorktreeRecord] = []) {
        projects.append(project)
        rows.append(records)
    }
}

@MainActor
private func waitForLifecycle(_ value: @escaping @MainActor () -> Bool) async {
    for await finished in Observations({ value() }) {
        if finished { return }
    }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func tabsPreserveWorktreeJobsAndIndependentLoadingState() async throws {
    let status = LifecycleGate<GitStatus>()
    let size = LifecycleGate<DiskUsage>()
    let inspection = LifecycleGate<BranchInspection>()
    let branches = LifecycleGate<[ManagedBranch]>()
    let store = AppStore(
        persistence: LifecycleSettings(),
        sizeQueue: WorktreeSizeQueue(scan: { _ in await size.run() }, gitStorageScan: { _ in lifecycleUsage }),
        inspectBranches: { _, _ in await inspection.run() },
        listManagedBranches: { _ in await branches.run() },
        listWorktrees: { _ in [lifecycleRecord] },
        loadGitStatus: { _ in await status.run() },
        editorLauncher: inertEditorLauncher()
    )
    store.loadSelection()
    let session = try #require(store.selectedProjectSession)
    await status.waitForStarts(1)
    await size.waitForStarts(1)
    await inspection.waitForStarts(1)
    store.worktreeSelection = [lifecycleRecord.id]
    let revision = session.worktreeLoading.revision
    store.projectSection = .branches
    await branches.waitForStarts(1)
    #expect(store.isRefreshing)
    for _ in 0..<5 {
        store.projectSection = .worktrees
        store.projectSection = .branches
    }
    #expect(session.worktreeLoading.revision == revision)
    #expect(store.worktreeSelection == [lifecycleRecord.id])
    #expect(await status.starts == 1)
    #expect(await size.starts == 1)
    #expect(await inspection.starts == 1)
    #expect(await branches.starts == 1)

    await status.finish(with: lifecycleStatus)
    await size.finish(with: lifecycleUsage)
    await inspection.finish(with: BranchInspection(targetLabel: "main", byWorktreeID: [:]))
    await waitForLifecycle { !session.worktreeLoading.isLoading && !session.isMeasuringSizes
        && !session.inspectionLoading.isLoading }
    #expect(store.isRefreshing, "A hidden tab finishing cannot clear the visible branch loader.")
    #expect(session.row(id: lifecycleRecord.id)?.row.status?.modified == 7)
    #expect(session.row(id: lifecycleRecord.id)?.row.usage?.bytes == 123)
    #expect(await status.canceledCompletions == 0)
    #expect(await size.canceledCompletions == 0)
    #expect(await inspection.canceledCompletions == 0)
    await branches.finish(with: [lifecycleBranch])
    await waitForLifecycle { !session.branchLoading.isLoading }
    session.branchList.selection = [lifecycleBranch.reference]
    store.projectSection = .worktrees
    #expect(!store.isRefreshing)
    store.projectSection = .branches
    #expect(session.branchList.selection == [lifecycleBranch.reference])
    #expect(await branches.starts == 1)
    store.destination = nil
}

@Test(.timeLimit(.minutes(1))) @MainActor
func branchRefreshDoesNotCancelHiddenWorktreeJobs() async throws {
    let status = LifecycleGate<GitStatus>()
    let size = LifecycleGate<DiskUsage>()
    let store = AppStore(
        persistence: LifecycleSettings(),
        sizeQueue: WorktreeSizeQueue(scan: { _ in await size.run() }, gitStorageScan: { _ in lifecycleUsage }),
        inspectBranches: { _, _ in BranchInspection(targetLabel: "main", byWorktreeID: [:]) },
        listManagedBranches: { _ in [lifecycleBranch] },
        listWorktrees: { _ in [lifecycleRecord] },
        loadGitStatus: { _ in await status.run() },
        editorLauncher: inertEditorLauncher()
    )
    store.loadSelection()
    let session = try #require(store.selectedProjectSession)
    await status.waitForStarts(1)
    await size.waitForStarts(1)
    let revision = session.worktreeLoading.revision
    store.projectSection = .branches
    await waitForLifecycle { !store.isRefreshing }
    store.refresh()
    await waitForLifecycle { !store.isRefreshing }
    #expect(session.worktreeLoading.revision == revision)
    await status.finish(with: lifecycleStatus)
    await size.finish(with: lifecycleUsage)
    await waitForLifecycle { !session.worktreeLoading.isLoading && !session.isMeasuringSizes }
    #expect(await status.canceledCompletions == 0)
    #expect(await size.canceledCompletions == 0)
    #expect(session.row(id: lifecycleRecord.id)?.row.status?.modified == 7)
    store.destination = nil
}

@Test(.timeLimit(.minutes(1))) @MainActor
func worktreeReconciliationReverifiesAnInFlightBranchSnapshot() async throws {
    let inventory = LifecycleGate<[WorktreeRecord]>()
    let branches = LifecycleGate<[ManagedBranch]>()
    let store = AppStore(
        persistence: LifecycleSettings(),
        sizeQueue: WorktreeSizeQueue(scan: { _ in lifecycleUsage }, gitStorageScan: { _ in lifecycleUsage }),
        inspectBranches: { _, _ in BranchInspection(targetLabel: "main", byWorktreeID: [:]) },
        listManagedBranches: { _ in await branches.run() },
        listWorktrees: { _ in await inventory.run() },
        loadGitStatus: { _ in lifecycleStatus },
        editorLauncher: inertEditorLauncher()
    )
    store.loadSelection()
    let session = try #require(store.selectedProjectSession)
    await inventory.waitForStarts(1)
    store.projectSection = .branches
    await branches.waitForStarts(1)
    await inventory.finish(with: [lifecycleRecord])
    await waitForLifecycle { !session.worktreeLoading.isLoading }
    await branches.finish(with: [lifecycleBranch])
    await branches.waitForStarts(2)
    #expect(!session.branchList.hasLoadedInventory)
    #expect(store.isRefreshing)
    await branches.finish(1, with: [ManagedBranch(
        reference: lifecycleBranch.reference, name: "topic", commit: "def",
        committerName: "", committerEmail: "", protectedReason: "Checked out in a worktree."
    )])
    await waitForLifecycle { !session.branchLoading.isLoading }
    #expect(session.branchList.rows.first?.branch.commit == "def")
    #expect(session.branchList.rows.first?.branch.protectedReason != nil)
    #expect(await branches.canceledCompletions == 0)
    store.destination = nil
}

@Test(.timeLimit(.minutes(1))) @MainActor
func mergeTargetChangeReverifiesInFlightBranchProtection() async throws {
    let inputs = LifecycleInputs()
    let branches = LifecycleGate<[ManagedBranch]>()
    let store = AppStore(
        persistence: LifecycleSettings(),
        sizeQueue: WorktreeSizeQueue(scan: { _ in lifecycleUsage }, gitStorageScan: { _ in lifecycleUsage }),
        inspectBranches: { project, _ in
            BranchInspection(targetLabel: project.mergeTarget ?? "main", availableTargets: lifecycleTargets, byWorktreeID: [:])
        },
        listManagedBranches: { project in await inputs.record(project); return await branches.run() },
        listWorktrees: { _ in [lifecycleRecord] },
        loadGitStatus: { _ in lifecycleStatus },
        editorLauncher: inertEditorLauncher()
    )
    store.loadSelection()
    let session = try #require(store.selectedProjectSession)
    await waitForLifecycle { !session.worktreeLoading.isLoading && !session.inspectionLoading.isLoading }
    store.projectSection = .branches
    await branches.waitForStarts(1)
    store.projectSection = .worktrees
    store.changeMergeTarget("refs/heads/b")
    store.projectSection = .branches
    await branches.finish(with: [lifecycleBranch])
    await branches.waitForStarts(2)
    #expect(!session.branchList.hasLoadedInventory)
    #expect(await inputs.projects.last?.mergeTarget == "refs/heads/b")
    await branches.finish(1, with: [ManagedBranch(
        reference: "refs/heads/b", name: "b", commit: "abc",
        committerName: "", committerEmail: "", protectedReason: "Merge target"
    )])
    await waitForLifecycle { !session.branchLoading.isLoading }
    #expect(session.branchList.rows.first?.branch.protectedReason == "Merge target")
    store.destination = nil
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true]) @MainActor
func inventoryRefreshUsesLatestMergeTargetAndFencesOldInspection(finishOldInspection: Bool) async throws {
    let inventory = LifecycleGate<[WorktreeRecord]>()
    let inspection = LifecycleGate<BranchInspection>()
    let inputs = LifecycleInputs()
    let store = AppStore(
        persistence: LifecycleSettings(),
        sizeQueue: WorktreeSizeQueue(scan: { _ in lifecycleUsage }, gitStorageScan: { _ in lifecycleUsage }),
        inspectBranches: { project, records in
            await inputs.record(project, records)
            return await inspection.run()
        },
        listWorktrees: { _ in await inventory.run() },
        loadGitStatus: { _ in lifecycleStatus },
        editorLauncher: inertEditorLauncher()
    )
    store.loadSelection()
    let session = try #require(store.selectedProjectSession)
    await inventory.waitForStarts(1)
    session.updateOverview {
        $0.branches = BranchInspection(targetLabel: "main", availableTargets: lifecycleTargets, byWorktreeID: [:])
    }
    store.changeMergeTarget("refs/heads/b")
    await inspection.waitForStarts(1)
    let oldInspectionTask = session.inspectionLoading.task
    if finishOldInspection {
        await inspection.finish(with: BranchInspection(targetLabel: "pre-inventory", byWorktreeID: [:]))
        await waitForLifecycle { !session.inspectionLoading.isLoading }
    }
    await inventory.finish(with: [lifecycleRecord])
    await inspection.waitForStarts(2)
    #expect(await inputs.projects.last?.mergeTarget == "refs/heads/b")
    #expect(await inputs.rows.last?.map(\.id) == [lifecycleRecord.id])
    await inspection.finish(1, with: BranchInspection(targetLabel: "current", byWorktreeID: [:]))
    await waitForLifecycle { !session.inspectionLoading.isLoading }
    if !finishOldInspection {
        await inspection.finish(with: BranchInspection(targetLabel: "obsolete", byWorktreeID: [:]))
    }
    await oldInspectionTask?.value
    #expect(session.overview.branches?.targetLabel == "current")
    store.destination = nil
}

private enum LifecycleFailure: Error { case partialFetch }

@Test(.timeLimit(.minutes(1)), arguments: [false, true]) @MainActor
func fetchDefersMergeInspectionUntilRefsSettle(fails: Bool) async throws {
    let fetch = LifecycleGate<Bool>()
    let inspection = LifecycleGate<BranchInspection>()
    let store = AppStore(
        persistence: LifecycleSettings(),
        sizeQueue: WorktreeSizeQueue(scan: { _ in lifecycleUsage }, gitStorageScan: { _ in lifecycleUsage }),
        inspectBranches: { _, _ in await inspection.run() },
        listManagedBranches: { _ in [lifecycleBranch] },
        fetchManagedBranches: { _ in if await fetch.run() { throw LifecycleFailure.partialFetch } },
        listWorktrees: { _ in [lifecycleRecord] },
        loadGitStatus: { _ in lifecycleStatus },
        editorLauncher: inertEditorLauncher()
    )
    store.loadSelection()
    let session = try #require(store.selectedProjectSession)
    await inspection.waitForStarts(1)
    await inspection.finish(with: BranchInspection(targetLabel: "before-fetch", byWorktreeID: [:]))
    await waitForLifecycle { !session.inspectionLoading.isLoading && !session.worktreeLoading.isLoading }
    store.projectSection = .branches
    await waitForLifecycle { !session.branchLoading.isLoading }
    store.fetchBranches()
    await fetch.waitForStarts(1)
    store.projectSection = .worktrees
    #expect(session.overview.branches == nil)
    #expect(await inspection.starts == 1, "Do not inspect refs in the middle of Fetch & Prune.")
    #expect(!store.canDeleteSelection)
    await fetch.finish(with: fails)
    await inspection.waitForStarts(2)
    await inspection.finish(1, with: BranchInspection(targetLabel: "after-fetch", byWorktreeID: [:]))
    await waitForLifecycle { !session.inspectionLoading.isLoading }
    #expect(session.overview.branches?.targetLabel == "after-fetch")
    #expect(!session.isFetchingBranches)
    store.destination = nil
}

@Test(.timeLimit(.minutes(1))) @MainActor
func leavingProjectCancelsReadsAndRejectsLateResults() async throws {
    let status = LifecycleGate<GitStatus>()
    let size = LifecycleGate<DiskUsage>()
    let inspection = LifecycleGate<BranchInspection>()
    let store = AppStore(
        persistence: LifecycleSettings(),
        sizeQueue: WorktreeSizeQueue(scan: { _ in await size.run() }, gitStorageScan: { _ in lifecycleUsage }),
        inspectBranches: { project, _ in
            project.id == "a" ? await inspection.run() : BranchInspection(targetLabel: "b", byWorktreeID: [:])
        },
        listWorktrees: { $0.id == "a" ? [lifecycleRecord] : [] },
        loadGitStatus: { _ in await status.run() },
        editorLauncher: inertEditorLauncher()
    )
    store.loadSelection()
    let oldSession = try #require(store.selectedProjectSession)
    await status.waitForStarts(1)
    await size.waitForStarts(1)
    await inspection.waitForStarts(1)
    store.destination = .project("b")
    let newSession = try #require(store.selectedProjectSession)
    await waitForLifecycle { !newSession.worktreeLoading.isLoading && !newSession.inspectionLoading.isLoading }
    await status.finish(with: lifecycleStatus)
    await size.finish(with: lifecycleUsage)
    await inspection.finish(with: BranchInspection(targetLabel: "obsolete", byWorktreeID: [:]))
    // Returning starts new work. Held completions from the old activation must
    // not satisfy that new request or replace its cached rows.
    store.destination = .project("a")
    await status.waitForStarts(2)
    await size.waitForStarts(2)
    await inspection.waitForStarts(2)
    #expect(oldSession.row(id: lifecycleRecord.id)?.row.status == nil)
    #expect(oldSession.row(id: lifecycleRecord.id)?.row.usage == nil)
    #expect(newSession.rows.isEmpty)
    #expect(newSession.overview.branches?.targetLabel == "b")
    await status.finish(1, with: lifecycleStatus)
    await size.finish(1, with: lifecycleUsage)
    await inspection.finish(1, with: BranchInspection(targetLabel: "current", byWorktreeID: [:]))
    await waitForLifecycle { !oldSession.worktreeLoading.isLoading && !oldSession.isMeasuringSizes
        && !oldSession.inspectionLoading.isLoading }
    #expect(await status.canceledCompletions == 1)
    #expect(await size.canceledCompletions == 1)
    #expect(await inspection.canceledCompletions == 1)
    #expect(oldSession.overview.branches?.targetLabel == "current")
    store.destination = nil
}

@Test(.timeLimit(.minutes(1))) @MainActor
func deletionFencesTheOtherTabsInFlightInventory() async throws {
    let branches = LifecycleGate<[ManagedBranch]>()
    let store = AppStore(
        persistence: LifecycleSettings(),
        sizeQueue: WorktreeSizeQueue(scan: { _ in lifecycleUsage }, gitStorageScan: { _ in lifecycleUsage }),
        inspectBranches: { _, _ in BranchInspection(targetLabel: "main", byWorktreeID: [:]) },
        listManagedBranches: { _ in await branches.run() },
        removeWorktree: { _, _ in },
        listWorktrees: { _ in [lifecycleRecord] },
        loadGitStatus: { _ in lifecycleStatus },
        editorLauncher: inertEditorLauncher(),
        authenticate: { _ in }
    )
    store.loadSelection()
    let session = try #require(store.selectedProjectSession)
    await waitForLifecycle { !session.worktreeLoading.isLoading }
    store.projectSection = .branches
    await branches.waitForStarts(1)
    let oldBranchTask = session.branchLoading.task
    store.projectSection = .worktrees
    store.worktreeSelection = [lifecycleRecord.id]
    store.prepareDeletion()
    let request = try #require(store.deletionRequest)
    await store.delete(request)
    await branches.finish(with: [lifecycleBranch])
    await oldBranchTask?.value
    #expect(session.rows.isEmpty)
    #expect(session.branchList.rows.isEmpty)
    #expect(!session.branchList.hasLoadedInventory)
    #expect(await branches.canceledCompletions == 1)
    store.destination = nil
}

@MainActor
private final class LifecycleGitHubCredentials: GitHubCredentialsPersisting {
    func load() throws -> GitHubToken? { GitHubToken(accessToken: "fixture-only") }
    func save(_ token: GitHubToken) throws {}
    func remove() throws {}
}

@Test(.timeLimit(.minutes(1))) @MainActor
func pullRequestsContinueWhenBranchesTabDisappears() async throws {
    let requests = LifecycleGate<GitHubPullRequestBatch>()
    let branch = ManagedBranch(
        reference: "refs/heads/topic", name: "topic", commit: "abc",
        committerName: "", committerEmail: "",
        githubURL: URL(string: "https://github.com/example/repo/tree/topic")
    )
    let cache = GitHubPullRequestCache(
        repositories: { repository, _ in [repository] },
        lookup: { _, _, _ in await requests.run() }
    )
    let github = GitHubSession(
        credentials: LifecycleGitHubCredentials(), pullRequests: cache,
        loadUser: { _ in GitHubUser(login: "fixture", id: 1) }, openBrowser: { _ in }
    )
    await github.restore()
    let store = AppStore(
        persistence: LifecycleSettings(), github: github,
        sizeQueue: WorktreeSizeQueue(scan: { _ in lifecycleUsage }, gitStorageScan: { _ in lifecycleUsage }),
        inspectBranches: { _, _ in BranchInspection(targetLabel: "main", byWorktreeID: [:]) },
        listManagedBranches: { _ in [branch] },
        listWorktrees: { _ in [] },
        editorLauncher: inertEditorLauncher()
    )
    store.projectSection = .branches
    await requests.waitForStarts(1)
    store.projectSection = .worktrees
    // Wait for the hidden worktree inventory's dependent invalidation/reload.
    await waitForLifecycle { !store.isRefreshing }
    let key = try #require(GitHubBranch(branchURL: branch.githubURL!))
    await requests.finish(with: GitHubPullRequestBatch(results: [key: .success(nil)]))
    await waitForLifecycle { !cache.isLoading }
    #expect(await requests.starts == 1)
    #expect(await requests.canceledCompletions == 0)
    guard case .loaded = cache.entries[key] else {
        Issue.record("A hidden tab's PR result must stay cached.")
        return
    }
    store.destination = nil
}
