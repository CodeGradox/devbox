import Foundation
import Observation
import Testing
@testable import DevBox
@testable import DevBoxCore

@MainActor
private final class BranchSettings: SettingsPersisting {
    var value = AppSettings()
    func load() throws -> AppSettings { value }
    func save(_ settings: AppSettings) throws { value = settings }
}

@MainActor
private final class BranchCredentials: CredentialsPersisting {
    func password(for id: UUID) throws -> String? { nil }
    func save(password: String, for id: UUID) throws {}
    func remove(for id: UUID) throws {}
}

private enum BranchTestFailure: Error { case expected }

private actor BranchOperations {
    private var listCalls: [String] = []
    private var fetchCalls: [String] = []
    private var deletions: [(String, Bool)] = []
    private var failFetch = false
    private var uncertainDeletion = false

    func list(_ project: ProjectRecord) -> [ManagedBranch] {
        listCalls.append(project.id)
        return [
            branchFixture("feature"),
            branchFixture("feature", remote: "origin"),
            branchFixture("main", protected: "The default branch is protected.")
        ]
    }

    func fetch(_ project: ProjectRecord) throws {
        fetchCalls.append(project.id)
        if failFetch { throw BranchTestFailure.expected }
    }

    func delete(_ branch: ManagedBranch, force: Bool) throws {
        deletions.append((branch.id, force))
        if uncertainDeletion {
            throw BranchManagementError.deletionOutcomeUnknown("Fetch & Prune to verify the remote state.")
        }
    }

    func counts() -> (lists: Int, fetches: Int, deletes: Int) {
        (listCalls.count, fetchCalls.count, deletions.count)
    }

    func deleted() -> [(String, Bool)] { deletions }
    func setFetchFailure() { failFetch = true }
    func setUncertainDeletion() { uncertainDeletion = true }
}

private func branchFixture(_ name: String, remote: String? = nil, protected: String? = nil) -> ManagedBranch {
    ManagedBranch(
        reference: remote.map { "refs/remotes/\($0)/\(name)" } ?? "refs/heads/\(name)",
        name: name, commit: String(repeating: "a", count: 40),
        committerName: "Branch Tests", committerEmail: "test@example.invalid",
        committedAt: Date(timeIntervalSince1970: 1_700_000_000),
        remoteName: remote, remoteBranchName: remote == nil ? nil : name,
        remoteURL: remote == nil ? nil : "/test/remote.git", protectedReason: protected
    )
}

@MainActor
private func branchStore(_ probe: BranchOperations, authenticate: @escaping @MainActor (String) async throws -> Void = { _ in }) -> AppStore {
    let persistence = BranchSettings()
    persistence.value.projects = [
        .init(id: "/test/a/.git", name: "A", path: "/test/a"),
        .init(id: "/test/b/.git", name: "B", path: "/test/b")
    ]
    return AppStore(
        persistence: persistence, credentials: BranchCredentials(),
        listManagedBranches: { await probe.list($0) },
        fetchManagedBranches: { try await probe.fetch($0) },
        deleteBranch: { branch, _, force in try await probe.delete(branch, force: force) },
        authenticate: authenticate
    )
}

@MainActor
private func waitForBranchLoad(_ store: AppStore) async {
    for await refreshing in Observations({ store.isRefreshing }) {
        if !refreshing { return }
    }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func branchInventoryIsCachedPerProjectAndRefreshNeverFetches() async throws {
    let probe = BranchOperations()
    let store = branchStore(probe)
    store.projectSection = .branches
    await waitForBranchLoad(store)
    let first = try #require(store.selectedProjectSession?.branchList)
    #expect(first.hasLoadedInventory)
    first.selection = ["refs/heads/feature"]
    #expect(store.canDeleteSelection)

    store.destination = .project("/test/b/.git")
    await waitForBranchLoad(store)
    #expect(first.selection.isEmpty)
    #expect(store.selectedProjectSession?.branchList !== first)
    store.destination = .project("/test/a/.git")
    await waitForBranchLoad(store)
    #expect(store.selectedProjectSession?.branchList === first)
    #expect(await probe.counts().lists == 2)
    store.refresh()
    await waitForBranchLoad(store)
    #expect(await probe.counts().lists == 3)
    #expect(await probe.counts().fetches == 0)
    #expect(first.lastFetchedAt == nil)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func explicitFetchUpdatesBranchesAndFailureDisablesDeletionUntilReload() async throws {
    let probe = BranchOperations()
    let store = branchStore(probe)
    store.projectSection = .branches
    await waitForBranchLoad(store)
    let list = try #require(store.selectedProjectSession?.branchList)
    store.fetchBranches()
    await waitForBranchLoad(store)
    #expect(await probe.counts().fetches == 1)
    #expect(await probe.counts().lists == 2)
    let fetchedAt = try #require(list.lastFetchedAt)

    await probe.setFetchFailure()
    list.selection = ["refs/heads/feature"]
    store.fetchBranches()
    await waitForBranchLoad(store)
    #expect(!list.hasLoadedInventory)
    #expect(!store.canDeleteSelection)
    #expect(store.loadError != nil)
    #expect(list.lastFetchedAt == fetchedAt)
    store.refresh()
    await waitForBranchLoad(store)
    #expect(list.hasLoadedInventory)
    #expect(store.loadError == nil)
    #expect(await probe.counts().fetches == 2)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func branchDeletionUsesFullRefsAndOnlyForcesLocalBranches() async throws {
    let probe = BranchOperations()
    var authenticated = 0
    let store = branchStore(probe) { _ in authenticated += 1 }
    store.projectSection = .branches
    await waitForBranchLoad(store)
    let list = try #require(store.selectedProjectSession?.branchList)
    list.selection = ["refs/heads/feature", "refs/remotes/origin/feature"]
    store.prepareDeletion()
    let request = try #require(store.deletionRequest)
    #expect(Set(request.entries.map(\.name)) == list.selection)
    await store.delete(request, forceBranches: true)
    #expect(authenticated == 1)
    #expect(store.deletionEntries.allSatisfy { $0.state == .completed })
    #expect(list.selection.isEmpty)
    #expect(list.hasLoadedInventory)
    let deleted = await probe.deleted()
    #expect(deleted.count == 2)
    #expect(deleted.first(where: { $0.0 == "refs/heads/feature" })?.1 == true)
    #expect(deleted.first(where: { $0.0 == "refs/remotes/origin/feature" })?.1 == false)
    list.selection = ["refs/heads/feature", "refs/remotes/origin/feature"]
    #expect(list.selectedBranches.isEmpty)
    #expect(await probe.counts().lists == 1)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func protectedBranchSelectionCannotOpenConfirmation() async throws {
    let probe = BranchOperations()
    let store = branchStore(probe)
    store.projectSection = .branches
    await waitForBranchLoad(store)
    let list = try #require(store.selectedProjectSession?.branchList)
    list.selection = ["refs/heads/feature", "refs/heads/main"]
    #expect(!store.canDeleteSelection)
    store.prepareDeletion()
    #expect(store.deletionRequest == nil)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func branchAuthenticationCancellationDoesNotDelete() async throws {
    let probe = BranchOperations()
    let store = branchStore(probe) { _ in throw BranchTestFailure.expected }
    store.projectSection = .branches
    await waitForBranchLoad(store)
    store.selectedProjectSession?.branchList.selection = ["refs/heads/feature"]
    store.prepareDeletion()
    let request = try #require(store.deletionRequest)
    await store.delete(request)
    #expect(await probe.counts().deletes == 0)
    #expect(store.deletionRequest?.id == request.id)
    #expect(store.deletionError?.contains("Nothing was deleted.") == true)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func uncertainBranchDeletionStopsBatchAndInvalidatesInventory() async throws {
    let probe = BranchOperations()
    let store = branchStore(probe)
    store.projectSection = .branches
    await waitForBranchLoad(store)
    let list = try #require(store.selectedProjectSession?.branchList)
    list.selection = ["refs/heads/feature", "refs/remotes/origin/feature"]
    store.prepareDeletion()
    let request = try #require(store.deletionRequest)
    await probe.setUncertainDeletion()
    await store.delete(request)
    #expect(await probe.counts().deletes == 1)
    #expect(!list.hasLoadedInventory)
    #expect(store.deletionEntries.first?.state.title == "Uncertain")
    #expect(store.deletionEntries.last?.state.title == "Not attempted")
    list.selection = ["refs/heads/feature", "refs/remotes/origin/feature"]
    #expect(list.selectedBranches.count == 2)
}

private actor SuspendedBranchList {
    private var continuation: CheckedContinuation<[ManagedBranch], Never>?
    private var ready: CheckedContinuation<Void, Never>?

    func load(_ project: ProjectRecord) async -> [ManagedBranch] {
        if project.name == "B" { return [branchFixture("from-b")] }
        return await withCheckedContinuation {
            continuation = $0
            ready?.resume()
            ready = nil
        }
    }

    func waitUntilSuspended() async {
        if continuation != nil { return }
        await withCheckedContinuation { ready = $0 }
    }

    func release() {
        continuation?.resume(returning: [branchFixture("stale-a")])
        continuation = nil
    }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func lateBranchLoadCannotReplaceAnotherProject() async throws {
    let persistence = BranchSettings()
    persistence.value.projects = [
        .init(id: "/test/a/.git", name: "A", path: "/test/a"),
        .init(id: "/test/b/.git", name: "B", path: "/test/b")
    ]
    let probe = SuspendedBranchList()
    let store = AppStore(
        persistence: persistence, credentials: BranchCredentials(),
        listManagedBranches: { await probe.load($0) }
    )
    store.projectSection = .branches
    await probe.waitUntilSuspended()
    store.destination = .project("/test/b/.git")
    await waitForBranchLoad(store)
    await probe.release()
    #expect(store.selectedProject?.name == "B")
    let list = try #require(store.selectedProjectSession?.branchList)
    list.selection = ["refs/heads/from-b", "refs/heads/stale-a"]
    #expect(list.selectedBranches.map(\.name) == ["from-b"])
}

private actor SuspendedFetch {
    private var continuation: CheckedContinuation<Void, Never>?
    private var ready: CheckedContinuation<Void, Never>?

    func fetch() async {
        await withCheckedContinuation {
            continuation = $0
            ready?.resume()
            ready = nil
        }
    }

    func waitUntilSuspended() async {
        if continuation != nil { return }
        await withCheckedContinuation { ready = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func changingProjectsDuringFetchDoesNotPublishObsoleteResults() async throws {
    let persistence = BranchSettings()
    persistence.value.projects = [
        .init(id: "/test/a/.git", name: "A", path: "/test/a"),
        .init(id: "/test/b/.git", name: "B", path: "/test/b")
    ]
    let probe = SuspendedFetch()
    let operations = BranchOperations()
    let store = AppStore(
        persistence: persistence, credentials: BranchCredentials(),
        listManagedBranches: { await operations.list($0) },
        fetchManagedBranches: { _ in await probe.fetch() }
    )
    store.projectSection = .branches
    await waitForBranchLoad(store)
    let a = try #require(store.selectedProjectSession?.branchList)
    store.fetchBranches()
    await probe.waitUntilSuspended()
    #expect(!a.hasLoadedInventory)
    store.destination = .project("/test/b/.git")
    await waitForBranchLoad(store)
    let b = try #require(store.selectedProjectSession?.branchList)
    await probe.release()
    // A canceled fetch may finish its subprocess, but must not label the next
    // project's inventory as freshly fetched or replace its current session.
    store.destination = .project("/test/a/.git")
    await waitForBranchLoad(store)
    #expect(store.selectedProjectSession?.branchList === a)
    #expect(a.hasLoadedInventory)
    #expect(a.lastFetchedAt == nil)
    #expect(b.hasLoadedInventory)
    #expect(b.lastFetchedAt == nil)
    #expect(await operations.counts().lists == 3)
}
