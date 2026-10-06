import Foundation
import Observation
import Synchronization
import Testing
@testable import DevBox
import DevBoxCore

@MainActor
private func waitForGitHubCache(_ cache: GitHubPullRequestCache) async {
    for await loading in Observations({ cache.isLoading }) {
        if !loading { return }
    }
}

private final class GitHubCacheClock: Sendable {
    private let storage = Mutex(githubTestDate)
    var date: Date { storage.withLock { $0 } }
    func set(_ date: Date) { storage.withLock { $0 = date } }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func githubCacheRateLimitStopsRemainingRepositoryRequests() async {
    let calls = GitHubTestCalls()
    let cache = GitHubPullRequestCache(
        repositories: { repo, _ in
            await calls.record(repo)
            throw GitHubAPIError.rateLimited
        },
        lookup: { _, _, _ in
            Issue.record("Metadata rate limit must prevent lookups")
            return GitHubPullRequestBatch(results: [:])
        }, now: { githubTestDate }
    )
    let session = testGitHubSession(credentials: TestGitHubCredentials(githubTestToken), cache: cache)
    await session.restore()
    let branches: Set = [
        GitHubBranch(repository: "a/project", name: "main"),
        GitHubBranch(repository: "b/project", name: "main")
    ]
    cache.load(branches, session: session)
    await waitForGitHubCache(cache)
    #expect(await calls.values == ["a/project"])
    #expect(cache.entries.count == 2)
    let retryAt = githubTestDate.addingTimeInterval(60)
    #expect(cache.rateLimitRetryAt == retryAt)
    #expect(cache.entries.values.allSatisfy {
        $0 == .failed(GitHubPullRequestError.rateLimitExceeded(retryAt: retryAt).localizedDescription)
    })
    #expect(session.user == githubTestUser)
}

private actor GitHubLookupProbe {
    private(set) var repositories: [String] = []
    private(set) var branches: [GitHubBranch] = []
    private(set) var batchSizes: [Int] = []
    private(set) var maximumActive = 0
    private var active = 0
    private var blocked = true
    private var held: [CheckedContinuation<Void, Never>] = []
    private var started: [CheckedContinuation<Void, Never>] = []

    func metadata(_ repository: String) -> [String] {
        repositories.append(repository)
        return [repository, "upstream/project"]
    }
    func lookup(
        _ batch: [GitHubBranch], candidates: [String]
    ) async -> GitHubPullRequestBatch {
        #expect(batch.allSatisfy { candidates == [$0.repository, "upstream/project"] })
        branches.append(contentsOf: batch)
        batchSizes.append(batch.count)
        active += 1
        maximumActive = max(maximumActive, active)
        if blocked {
            await withCheckedContinuation { continuation in
                held.append(continuation)
                if held.count == 2 {
                    started.forEach { $0.resume() }
                    started.removeAll()
                }
            }
        }
        active -= 1
        return GitHubPullRequestBatch(results: Dictionary(uniqueKeysWithValues: batch.map { ($0, .success(nil)) }))
    }
    func waitForTwo() async {
        if held.count >= 2 { return }
        await withCheckedContinuation { started.append($0) }
    }
    func release() {
        blocked = false
        held.forEach { $0.resume() }
        held.removeAll()
    }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func githubCacheDeduplicatesGroupsMetadataAndBoundsConcurrency() async {
    let probe = GitHubLookupProbe()
    let cache = GitHubPullRequestCache(
        repositories: { repo, _ in await probe.metadata(repo) },
        lookup: { branches, candidates, _ in await probe.lookup(branches, candidates: candidates) },
        now: { githubTestDate }
    )
    let session = testGitHubSession(credentials: TestGitHubCredentials(githubTestToken), cache: cache)
    await session.restore()
    var targets = Set((0..<100).map { GitHubBranch(repository: "owner/project", name: "branch-\($0)") })
    targets.insert(GitHubBranch(repository: "OWNER/PROJECT", name: "branch-0"))
    targets.insert(GitHubBranch(repository: "zother/project", name: "main"))
    cache.load(targets, session: session)
    await probe.waitForTwo()
    #expect(await probe.branches.count == 50)
    #expect(await probe.maximumActive == 2)
    await probe.release()
    await waitForGitHubCache(cache)
    #expect(await probe.maximumActive == 2)
    #expect(await probe.repositories.sorted() == ["owner/project", "zother/project"])
    #expect(await probe.batchSizes.sorted() == [1, 25, 25, 25, 25])
    #expect(await probe.branches.count == 101)
    #expect(cache.entries.count == 101)
    #expect(cache.entries.values.allSatisfy { $0 == .loaded(nil, githubTestDate) })
    cache.load(targets, session: session)
    #expect(!cache.isLoading)
    #expect(await probe.branches.count == 101)
    cache.load(targets, session: session, force: true)
    await waitForGitHubCache(cache)
    #expect(await probe.branches.count == 202)
    #expect(await probe.repositories.count == 4)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func githubFailureSummaryGroupsVisibleBranchesByRepositoryAndCause() async {
    let first = GitHubBranch(repository: "owner/project", name: "first")
    let second = GitHubBranch(repository: "owner/project", name: "second")
    let other = GitHubBranch(repository: "other/project", name: "main")
    let absent = GitHubBranch(repository: "owner/project", name: "absent")
    let cache = GitHubPullRequestCache(
        repositories: { repo, _ in [repo] },
        lookup: { branches, _, _ in
            GitHubPullRequestBatch(results: Dictionary(uniqueKeysWithValues: branches.map {
                ($0, $0 == absent ? .success(nil) : .failure(.notFound))
            }))
        }, now: { githubTestDate }
    )
    let session = testGitHubSession(credentials: TestGitHubCredentials(githubTestToken), cache: cache)
    await session.restore()
    let targets: Set = [first, second, other, absent]
    cache.load(targets, session: session)
    await waitForGitHubCache(cache)
    #expect(cache.failures(for: targets) == [
        .init(repository: "other/project", message: GitHubPullRequestError.notFound.localizedDescription, branchCount: 1),
        .init(repository: "owner/project", message: GitHubPullRequestError.notFound.localizedDescription, branchCount: 2)
    ])
    #expect(cache.failures(for: [first, absent]) == [
        .init(repository: "owner/project", message: GitHubPullRequestError.notFound.localizedDescription, branchCount: 1)
    ])
    #expect(cache.failures(for: [absent]).isEmpty)
    session.signOut()
    #expect(cache.failures(for: targets).isEmpty)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func githubCacheDistinguishesAbsenceLookupFailureAndMetadataFailure() async {
    let absent = GitHubBranch(repository: "owner/project", name: "absent")
    let failed = GitHubBranch(repository: "owner/project", name: "failed")
    let metadataFailed = GitHubBranch(repository: "private/project", name: "main")
    let calls = GitHubTestCalls()
    let cache = GitHubPullRequestCache(
        repositories: { repo, _ in
            if repo == metadataFailed.repository { throw GitHubAPIError.forbidden }
            return [repo]
        },
        lookup: { branches, _, _ in
            for branch in branches { await calls.record(branch.name) }
            return GitHubPullRequestBatch(results: Dictionary(uniqueKeysWithValues: branches.map {
                ($0, $0 == failed ? .failure(.network) : .success(nil))
            }))
        },
        now: { githubTestDate }
    )
    let session = testGitHubSession(credentials: TestGitHubCredentials(githubTestToken), cache: cache)
    await session.restore()
    let targets: Set = [absent, failed, metadataFailed]
    cache.load(targets, session: session)
    await waitForGitHubCache(cache)
    #expect(cache.entries[absent] == .loaded(nil, githubTestDate))
    #expect(cache.entries[failed] == .failed(GitHubPullRequestError.network.localizedDescription))
    #expect(cache.entries[metadataFailed] == .failed(GitHubAPIError.forbidden.localizedDescription))
    #expect(await calls.values.sorted() == ["absent", "failed"])
    cache.load(targets, session: session)
    #expect(!cache.isLoading)
    #expect(await calls.values.count == 2)
    cache.load(targets, session: session, force: true)
    await waitForGitHubCache(cache)
    #expect(await calls.values.count == 4)
    session.signOut()
    #expect(cache.entries.isEmpty)
    cache.load(targets, session: session)
    #expect(cache.entries.isEmpty)
    #expect(!cache.isLoading)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func githubCacheSwitchingWorkRemovesPendingEntriesAndPreservesCompletedResults() async {
    let old = GitHubBranch(repository: "owner/project", name: "old")
    let current = GitHubBranch(repository: "owner/project", name: "current")
    let gate = GitHubTestGate<GitHubPullRequest?>()
    let cache = GitHubPullRequestCache(
        repositories: { repo, _ in [repo] },
        lookup: { branches, _, _ in
            if branches.contains(old) { return GitHubPullRequestBatch(results: [old: .success(await gate.enter())]) }
            return GitHubPullRequestBatch(results: Dictionary(uniqueKeysWithValues: branches.map { ($0, .success(nil)) }))
        }, now: { githubTestDate }
    )
    let session = testGitHubSession(credentials: TestGitHubCredentials(githubTestToken), cache: cache)
    await session.restore()
    cache.load([old], session: session)
    await gate.waitForEntry()
    #expect(cache.entries[old] == .loading)
    cache.load([current], session: session)
    #expect(cache.entries[old] == nil)
    await waitForGitHubCache(cache)
    #expect(cache.entries[current] == .loaded(nil, githubTestDate))
    await gate.release(nil)
    cache.cancelLoading()
    #expect(cache.entries[current] == .loaded(nil, githubTestDate))
    #expect(cache.entries[old] == nil)
    cache.clear()
    #expect(cache.entries.isEmpty)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func githubBatchKeepsPartialSuccessAndHonorsCooldownForForcedRefresh() async {
    let clock = GitHubCacheClock()
    let retryAt = githubTestDate.addingTimeInterval(900)
    let good = GitHubBranch(repository: "owner/project", name: "good")
    let throttled = GitHubBranch(repository: "owner/project", name: "throttled")
    let later = GitHubBranch(repository: "zother/project", name: "later")
    let newlyVisible = GitHubBranch(repository: "zother/project", name: "new")
    let metadataCalls = GitHubTestCalls()
    let batchCalls = GitHubTestCalls()
    let request = GitHubPullRequest(
        number: 12, title: "A matching PR", url: URL(string: "https://github.com/owner/project/pull/12")!,
        state: .open, createdAt: githubTestDate
    )
    let cache = GitHubPullRequestCache(
        repositories: { repository, _ in
            await metadataCalls.record(repository)
            return [repository]
        },
        lookup: { branches, _, _ in
            await batchCalls.record("batch")
            return GitHubPullRequestBatch(results: Dictionary(uniqueKeysWithValues: branches.map { branch in
                if branch == throttled && clock.date < retryAt {
                    return (branch, .failure(.rateLimitExceeded(retryAt: retryAt)))
                }
                return (branch, .success(branch == good ? request : nil))
            }))
        }, now: { clock.date }
    )
    let session = testGitHubSession(credentials: TestGitHubCredentials(githubTestToken), cache: cache)
    await session.restore()
    let branches: Set = [good, throttled, later]
    cache.load(branches, session: session)
    await waitForGitHubCache(cache)
    #expect(cache.entries[good] == .loaded(request, githubTestDate))
    #expect(cache.entries[throttled] == .failed(GitHubPullRequestError.rateLimitExceeded(retryAt: retryAt).localizedDescription))
    #expect(cache.entries[later] == cache.entries[throttled])
    #expect(cache.rateLimitRetryAt == retryAt)
    #expect(await metadataCalls.values == ["owner/project"])
    #expect(await batchCalls.values.count == 1)

    // Neither manual refresh nor revealing an uncached row bypasses GitHub's deadline.
    clock.set(retryAt.addingTimeInterval(-1))
    cache.load(branches.union([newlyVisible]), session: session, force: true)
    #expect(!cache.isLoading)
    #expect(cache.entries[good] == .loaded(request, githubTestDate))
    #expect(cache.entries[newlyVisible] == cache.entries[throttled])
    #expect(await batchCalls.values.count == 1)
    #expect(await metadataCalls.values.count == 1)

    clock.set(retryAt)
    cache.load(branches, session: session, force: true)
    await waitForGitHubCache(cache)
    #expect(cache.rateLimitRetryAt == nil)
    #expect(cache.entries[throttled] == .loaded(nil, retryAt))
    #expect(cache.entries[later] == .loaded(nil, retryAt))
    #expect(await batchCalls.values.count == 3)
    #expect(session.user == githubTestUser)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func githubBatchPublishesCompletedChunkWhileAnotherIsPending() async {
    let branches = (0..<50).map {
        GitHubBranch(repository: "owner/project", name: String(format: "branch-%03d", $0))
    }
    let gate = GitHubTestGate<Void>()
    let cache = GitHubPullRequestCache(
        repositories: { repository, _ in [repository] },
        lookup: { batch, _, _ in
            if batch.contains(branches[25]) { await gate.enter() }
            return GitHubPullRequestBatch(results: Dictionary(uniqueKeysWithValues: batch.map { ($0, .success(nil)) }))
        }, now: { githubTestDate }
    )
    let session = testGitHubSession(credentials: TestGitHubCredentials(githubTestToken), cache: cache)
    await session.restore()
    cache.load(Set(branches), session: session)
    await gate.waitForEntry()
    for await entry in Observations({ cache.entries[branches[0]] }) {
        if case .loaded = entry { break }
    }
    #expect(cache.isLoading)
    #expect(branches.prefix(25).allSatisfy { cache.entries[$0] == .loaded(nil, githubTestDate) })
    #expect(branches.suffix(25).allSatisfy { cache.entries[$0] == .loading })
    await gate.release(())
    await waitForGitHubCache(cache)
    #expect(cache.entries.values.allSatisfy { $0 == .loaded(nil, githubTestDate) })
}

@Test(.timeLimit(.minutes(1))) @MainActor
func githubBatchMissingOutcomeIsFailureAndExtraOutcomeIsIgnored() async {
    let absent = GitHubBranch(repository: "owner/project", name: "absent")
    let missing = GitHubBranch(repository: "owner/project", name: "missing")
    let extra = GitHubBranch(repository: "other/project", name: "unrequested")
    let cache = GitHubPullRequestCache(
        repositories: { repository, _ in [repository] },
        lookup: { _, _, _ in GitHubPullRequestBatch(results: [absent: .success(nil), extra: .success(nil)]) },
        now: { githubTestDate }
    )
    let session = testGitHubSession(credentials: TestGitHubCredentials(githubTestToken), cache: cache)
    await session.restore()
    cache.load([absent, missing], session: session)
    await waitForGitHubCache(cache)
    #expect(cache.entries[absent] == .loaded(nil, githubTestDate))
    #expect(cache.entries[missing] == .failed(GitHubPullRequestError.invalidResponse.localizedDescription))
    #expect(cache.entries[extra] == nil)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func githubBatchTransportFailureFailsItsTargetsWithoutSigningOut() async {
    let branches = (0..<3).map { GitHubBranch(repository: "owner/project", name: "branch-\($0)") }
    let cache = GitHubPullRequestCache(
        repositories: { repository, _ in [repository] },
        lookup: { _, _, _ in throw GitHubPullRequestError.network },
        now: { githubTestDate }
    )
    let session = testGitHubSession(credentials: TestGitHubCredentials(githubTestToken), cache: cache)
    await session.restore()
    cache.load(Set(branches), session: session)
    await waitForGitHubCache(cache)
    #expect(cache.entries.count == 3)
    #expect(cache.entries.values.allSatisfy { $0 == .failed(GitHubPullRequestError.network.localizedDescription) })
    #expect(cache.rateLimitRetryAt == nil)
    #expect(session.user == githubTestUser)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func githubCacheDrainsInFlightSuccessAndKeepsLongestDeadline() async {
    let branches = (0..<75).map {
        GitHubBranch(repository: "owner/project", name: String(format: "branch-%03d", $0))
    }
    let firstDeadline = githubTestDate.addingTimeInterval(60)
    let lastDeadline = githubTestDate.addingTimeInterval(120)
    let gate = GitHubTestGate<GitHubPullRequestBatch>()
    let calls = GitHubTestCalls()
    let cache = GitHubPullRequestCache(
        repositories: { repository, _ in [repository] },
        lookup: { batch, _, _ in
            await calls.record("batch")
            if batch.contains(branches[0]) {
                await gate.waitForEntry()
                return GitHubPullRequestBatch(
                    results: Dictionary(uniqueKeysWithValues: batch.map { ($0, .success(nil)) }),
                    retryAt: firstDeadline
                )
            }
            if batch.contains(branches[25]) { return await gate.enter() }
            Issue.record("No third batch may start after throttling")
            return GitHubPullRequestBatch(results: [:])
        }, now: { githubTestDate }
    )
    let session = testGitHubSession(credentials: TestGitHubCredentials(githubTestToken), cache: cache)
    await session.restore()
    cache.load(Set(branches), session: session)
    for await deadline in Observations({ cache.rateLimitRetryAt }) {
        if deadline != nil { break }
    }
    #expect(cache.isLoading)
    #expect(branches.prefix(25).allSatisfy { cache.entries[$0] == .loaded(nil, githubTestDate) })
    #expect(branches[25..<50].allSatisfy { cache.entries[$0] == .loading })
    await gate.release(GitHubPullRequestBatch(
        results: Dictionary(uniqueKeysWithValues: branches[25..<50].map { ($0, .success(nil)) }),
        retryAt: lastDeadline
    ))
    await waitForGitHubCache(cache)
    #expect(await calls.values.count == 2)
    #expect(branches.prefix(50).allSatisfy { cache.entries[$0] == .loaded(nil, githubTestDate) })
    #expect(branches.suffix(25).allSatisfy {
        cache.entries[$0] == .failed(GitHubPullRequestError.rateLimitExceeded(retryAt: lastDeadline).localizedDescription)
    })
    #expect(cache.rateLimitRetryAt == lastDeadline)
    session.signOut()
    #expect(cache.rateLimitRetryAt == nil)
    #expect(cache.entries.isEmpty)
}
