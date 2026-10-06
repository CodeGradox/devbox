import DevBoxCore
import Foundation
import Observation

enum GitHubPullRequestEntry: Equatable, Sendable {
    case loading
    case loaded(GitHubPullRequest?, Date)
    case failed(String)
}

struct GitHubPullRequestFailureSummary: Hashable, Identifiable {
    let repository: String
    let message: String
    let branchCount: Int
    var id: Self { self }
}

/// Account-local, in-memory results. A local branch and its tracking ref share a
/// request. Filtering and revisiting projects reuse results until Refresh PRs.
@MainActor @Observable
final class GitHubPullRequestCache {
    private(set) var entries: [GitHubBranch: GitHubPullRequestEntry] = [:]
    private(set) var isLoading = false
    private(set) var rateLimitRetryAt: Date?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var client = GitHubPullRequestService()
    private let repositories: (@Sendable (String, String) async throws -> [String])?
    private let lookup: (@Sendable ([GitHubBranch], [String], String) async throws -> GitHubPullRequestBatch)?
    private let now: @Sendable () -> Date

    init(
        repositories: (@Sendable (String, String) async throws -> [String])? = nil,
        lookup: (@Sendable ([GitHubBranch], [String], String) async throws -> GitHubPullRequestBatch)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.repositories = repositories
        self.lookup = lookup
        self.now = now
    }

    func failures(for branches: Set<GitHubBranch>) -> [GitHubPullRequestFailureSummary] {
        var grouped: [String: [String: Int]] = [:]
        for branch in branches {
            guard case .failed(let message) = entries[branch] else { continue }
            grouped[branch.repository, default: [:]][message, default: 0] += 1
        }
        return grouped.keys.sorted().flatMap { repository in
            grouped[repository, default: [:]].keys.sorted().map { message in
                GitHubPullRequestFailureSummary(
                    repository: repository, message: message,
                    branchCount: grouped[repository]?[message] ?? 0
                )
            }
        }
    }

    func clear() {
        cancelLoading()
        entries.removeAll()
        rateLimitRetryAt = nil
        client = GitHubPullRequestService()
    }

    func cancelLoading() {
        generation = UUID()
        task?.cancel()
        task = nil
        isLoading = false
        entries = entries.filter { $0.value != .loading }
    }

    func load(_ branches: Set<GitHubBranch>, session: GitHubSession, force: Bool = false) {
        cancelLoading()
        guard session.user != nil else { return }
        if let rateLimitRetryAt, rateLimitRetryAt > now() {
            let message = GitHubPullRequestError.rateLimitExceeded(retryAt: rateLimitRetryAt).localizedDescription
            for branch in branches where entries[branch] == nil { entries[branch] = .failed(message) }
            return
        }
        rateLimitRetryAt = nil
        let pending = branches.filter { force || entries[$0] == nil }
        guard !pending.isEmpty else { return }
        let generation = generation
        for branch in pending { entries[branch] = .loading }
        isLoading = true
        // One account-local client coordinates pagination backoff across batches.
        let client = client
        let repositories = repositories ?? { try await client.repositories(for: $0, accessToken: $1) }
        let lookup = lookup ?? { try await client.pullRequests(for: $0, repositories: $1, accessToken: $2) }
        task = Task {
            defer {
                if generation == self.generation {
                    entries = entries.filter { $0.value != .loading }
                    isLoading = false
                    task = nil
                }
            }
            let groups = Dictionary(grouping: pending, by: \.repository)
            for repository in groups.keys.sorted() {
                guard generation == self.generation, !Task.isCancelled,
                      let branches = groups[repository] else { return }
                let candidates: [String]
                do {
                    candidates = try await session.authorized { [repositories] in
                        try await repositories(repository, $0)
                    }
                } catch {
                    guard generation == self.generation, !Task.isCancelled else { return }
                    if let retryAt = Self.retryDate(for: error, now: now()) {
                        recordRateLimit(until: retryAt)
                        failPendingForRateLimit()
                        return
                    }
                    for branch in branches { entries[branch] = .failed(GitHubSession.message(for: error)) }
                    continue
                }
                guard generation == self.generation, !Task.isCancelled else { return }
                var rateLimited = false
                let ordered = branches.sorted { $0.name < $1.name }
                let batchSize = GitHubPullRequestService.maximumBatchSize
                let batches = stride(from: 0, to: ordered.count, by: batchSize).map {
                    Array(ordered[$0..<min($0 + batchSize, ordered.count)])
                }
                await withTaskGroup(of: BatchResult.self) { group in
                    var remaining = batches.makeIterator()
                    func enqueue(_ batch: [GitHubBranch]) {
                        group.addTask { [lookup, now] in
                            do {
                                let response = try await session.authorized {
                                    try await lookup(batch, candidates, $0)
                                }
                                return Self.batchResult(for: batch, response: response, checkedAt: now())
                            } catch {
                                let message = await GitHubSession.message(for: error)
                                return BatchResult(
                                    entries: Dictionary(uniqueKeysWithValues: batch.map { ($0, .failed(message)) }),
                                    retryAt: Self.retryDate(for: error, now: now())
                                )
                            }
                        }
                    }
                    // Two bounded GraphQL operations, not one HTTP call per branch.
                    for _ in 0..<2 {
                        if let batch = remaining.next() { enqueue(batch) }
                    }
                    for await result in group {
                        guard generation == self.generation, !Task.isCancelled else {
                            group.cancelAll()
                            return
                        }
                        // Publish successes before handling a partial batch throttle.
                        for (branch, entry) in result.entries { entries[branch] = entry }
                        if let retryAt = result.retryAt {
                            rateLimited = true
                            recordRateLimit(until: retryAt)
                        }
                        // Drain already-started work: it may contain valid results
                        // or a later deadline. Do not enqueue another batch.
                        if !rateLimited, let batch = remaining.next() { enqueue(batch) }
                    }
                }
                guard generation == self.generation, !Task.isCancelled else { return }
                if rateLimited {
                    failPendingForRateLimit()
                    return
                }
            }
        }
    }

    private func recordRateLimit(until retryAt: Date) {
        rateLimitRetryAt = max(rateLimitRetryAt ?? retryAt, retryAt)
    }

    private func failPendingForRateLimit() {
        guard let deadline = rateLimitRetryAt else { return }
        let message = GitHubPullRequestError.rateLimitExceeded(retryAt: deadline).localizedDescription
        for (branch, entry) in entries where entry == .loading {
            entries[branch] = .failed(message)
        }
    }

    private nonisolated static func retryDate(for error: Error, now: Date) -> Date? {
        if case .rateLimitExceeded(let retryAt) = error as? GitHubPullRequestError {
            return retryAt > now ? retryAt : now.addingTimeInterval(60)
        }
        if (error as? GitHubAPIError) == .rateLimited || (error as? GitHubPullRequestError) == .rateLimited {
            return now.addingTimeInterval(60)
        }
        return nil
    }

    private nonisolated static func batchResult(
        for branches: [GitHubBranch],
        response: GitHubPullRequestBatch,
        checkedAt: Date
    ) -> BatchResult {
        var entries: [GitHubBranch: GitHubPullRequestEntry] = [:]
        var retryAt = response.retryAt
        for branch in branches {
            // Missing results are a protocol failure, never a successful "No PR".
            switch response.results[branch] ?? .failure(.invalidResponse) {
            case .success(let request):
                entries[branch] = .loaded(request, checkedAt)
            case .failure(let error):
                entries[branch] = .failed(error.localizedDescription)
                if let date = retryDate(for: error, now: checkedAt) {
                    retryAt = max(retryAt ?? date, date)
                }
            }
        }
        return BatchResult(entries: entries, retryAt: retryAt)
    }

    private struct BatchResult: Sendable {
        let entries: [GitHubBranch: GitHubPullRequestEntry]
        let retryAt: Date?
    }
}
