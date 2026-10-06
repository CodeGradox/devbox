import Foundation
import Synchronization

public struct GitHubBranch: Sendable, Hashable {
    public let repository: String
    public let name: String

    public init(repository: String, name: String) {
        self.repository = repository.lowercased()
        self.name = name
    }

    public init?(branchURL: URL) {
        guard let c = URLComponents(url: branchURL, resolvingAgainstBaseURL: false),
              c.scheme == "https", c.host?.lowercased() == "github.com",
              c.user == nil, c.password == nil, c.port == nil,
              c.query == nil, c.fragment == nil else { return nil }
        let parts = c.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 5, parts[0].isEmpty, parts[3] == "tree",
              let owner = String(parts[1]).removingPercentEncoding,
              let repo = String(parts[2]).removingPercentEncoding,
              validRepository("\(owner)/\(repo)"),
              let name = parts[4...].joined(separator: "/").removingPercentEncoding,
              validBranchName(name) else { return nil }
        self.init(repository: "\(owner)/\(repo)", name: name)
    }
}

public struct GitHubPullRequest: Sendable, Hashable {
    public enum State: String, Sendable { case open, closed, merged }
    public let number: Int
    public let title: String
    public let url: URL
    public let state: State
    public let createdAt: Date

    public init(number: Int, title: String, url: URL, state: State, createdAt: Date) {
        self.number = number
        self.title = title
        self.url = url
        self.state = state
        self.createdAt = createdAt
    }
}

public enum GitHubPullRequestError: Error, LocalizedError, Sendable, Equatable {
    case unauthorized, forbidden, notFound, installationPermissions, rateLimited, server, invalidResponse, network
    case rateLimitExceeded(retryAt: Date)

    public var errorDescription: String? {
        switch self {
        case .unauthorized: "GitHub authentication expired or was rejected. Sign in again."
        case .forbidden: "GitHub denied repository access (FORBIDDEN). Check the App's repository permissions and any organization approval or SSO requirements."
        case .notFound: "GitHub could not find or grant access to this repository (NOT_FOUND). Check the Git remote URL and install the GitHub App on this repository. Signing in alone does not grant repository access."
        case .installationPermissions: "GitHub denied App access (HTTP 403). Install or approve the App for this repository with Pull requests: Read-only, then refresh PRs."
        case .rateLimited: "GitHub's request limit was reached. Try again later."
        case .rateLimitExceeded(let retryAt): "GitHub's request limit was reached. Try again after \(retryAt.ISO8601Format())."
        case .server: "GitHub is temporarily unavailable. Try again later."
        case .invalidResponse: "GitHub returned an invalid response."
        case .network: "Unable to connect to GitHub. Check your connection and try again."
        }
    }
}

/// Budget exhaustion can accompany a completely successful response. Carry the
/// deadline independently so callers can retain results without sending more work.
public struct GitHubPullRequestBatch: Sendable {
    public let results: [GitHubBranch: Result<GitHubPullRequest?, GitHubPullRequestError>]
    public let retryAt: Date?

    public init(
        results: [GitHubBranch: Result<GitHubPullRequest?, GitHubPullRequestError>],
        retryAt: Date? = nil
    ) {
        self.results = results
        self.retryAt = retryAt
    }
}

/// Implementations must not follow redirects.
public protocol GitHubPullRequestTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

private struct GitHubSessionTransport: GitHubPullRequestTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await GitHubHTTPTransport.send(request)
    }
}

public struct GitHubPullRequestService: Sendable {
    public static let maximumBatchSize = 25
    private let transport: any GitHubPullRequestTransport
    private let now: @Sendable () -> Date
    private let rateLimit = GraphQLRateLimit()

    public init() {
        transport = GitHubSessionTransport()
        now = { Date() }
    }
    public init(transport: any GitHubPullRequestTransport, now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.now = now
    }

    public func repositories(for repository: String, accessToken: String) async throws -> [String] {
        guard validRepository(repository) else { throw GitHubPullRequestError.invalidResponse }
        let (data, _) = try await send(path: "/repos/\(repository)", accessToken: accessToken)
        struct Metadata: Decodable {
            struct Parent: Decodable { let full_name: String }
            let fork: Bool
            let parent: Parent?
        }
        let metadata: Metadata = try decode(data)
        var result = [repository.lowercased()]
        if metadata.fork {
            guard let parent = metadata.parent, validRepository(parent.full_name) else {
                throw GitHubPullRequestError.invalidResponse
            }
            if !result.contains(parent.full_name.lowercased()) { result.append(parent.full_name.lowercased()) }
        }
        return result
    }

    /// Each candidate must be resolved before a branch can claim its globally newest PR.
    public func pullRequests(
        for branches: [GitHubBranch], repositories: [String], accessToken: String
    ) async throws -> GitHubPullRequestBatch {
        var seen = Set<GitHubBranch>()
        let branches = branches.filter { seen.insert($0).inserted }
        guard branches.count <= Self.maximumBatchSize,
              branches.allSatisfy({ validRepository($0.repository) && validBranchName($0.name) }),
              !repositories.isEmpty, repositories.allSatisfy(validRepository) else {
            throw GitHubPullRequestError.invalidResponse
        }
        let repositories = Set(repositories.map { $0.lowercased() }).sorted()
        guard repositories.count <= 2 else { throw GitHubPullRequestError.invalidResponse }
        var retryAt: Date?
        var candidates = repositories.indices.flatMap { r in
            branches.indices.map { Candidate(repository: r, branch: $0) }
        }
        while candidates.contains(where: { $0.result == nil }) {
            try Task.checkCancellation()
            let pending = candidates.indices.filter { candidates[$0].result == nil }
            // A sibling batch may have exhausted the shared budget while this
            // operation was receiving a page. Keep matches, but don't fetch again.
            if let date = rateLimit.deadline(after: now()) {
                retryAt = max(retryAt ?? date, date)
                for i in pending { candidates[i].result = .failure(.rateLimitExceeded(retryAt: date)) }
                break
            }
            var declarations: [String] = []
            var variables: [String: Any] = [:]
            var fields: [String] = []
            for r in repositories.indices {
                let indices = pending.filter { candidates[$0].repository == r }
                guard !indices.isEmpty else { continue }
                let parts = repositories[r].split(separator: "/").map(String.init)
                declarations += ["$owner\(r): String!", "$repo\(r): String!"]
                variables["owner\(r)"] = parts[0]
                variables["repo\(r)"] = parts[1]
                var connections: [String] = []
                for i in indices {
                    let b = candidates[i].branch
                    let key = "r\(r)b\(b)"
                    declarations += ["$head\(key): String!", "$cursor\(key): String"]
                    variables["head\(key)"] = branches[b].name
                    variables["cursor\(key)"] = candidates[i].cursor.map { $0 as Any } ?? NSNull()
                    connections.append("""
                    b\(b): pullRequests(headRefName: $head\(key), states: [OPEN,CLOSED,MERGED], orderBy: {field: CREATED_AT,direction: DESC}, first: 10, after: $cursor\(key)) {
                      nodes { number title state createdAt headRefName headRepository { nameWithOwner } }
                      pageInfo { hasNextPage endCursor }
                    }
                    """)
                }
                fields.append("r\(r): repository(owner: $owner\(r), name: $repo\(r)) { \(connections.joined(separator: "\n")) }")
            }
            let body = try JSONSerialization.data(withJSONObject: [
                "query": "query(\(declarations.joined(separator: ","))) { \(fields.joined(separator: "\n")) }",
                "variables": variables
            ])
            let data: Data
            let response: HTTPURLResponse
            do {
                (data, response) = try await send(path: "/graphql", accessToken: accessToken, body: body)
            } catch let error as GitHubPullRequestError {
                if error == .unauthorized { throw error }
                if case .rateLimitExceeded(let date) = error {
                    retryAt = max(retryAt ?? date, date)
                    rateLimit.record(date)
                }
                for i in pending { candidates[i].result = .failure(error) }
                break
            }
            var throttled = response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0"
                || response.value(forHTTPHeaderField: "Retry-After") != nil
            if throttled {
                let date = retryDeadline(response)
                retryAt = max(retryAt ?? date, date)
                rateLimit.record(date)
            }
            guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                for i in pending { candidates[i].result = .failure(.invalidResponse) }
                break
            }
            let payload = envelope["data"] as? [String: Any]
            var scoped: [Int: GitHubPullRequestError] = [:]
            var global: GitHubPullRequestError?
            if let rawErrors = envelope["errors"] {
                guard let errors = rawErrors as? [[String: Any]] else {
                    for i in pending { candidates[i].result = .failure(.invalidResponse) }
                    break
                }
                for error in errors {
                    let classification = graphError(error, response: response)
                    if classification == .unauthorized { throw classification }
                    if case .rateLimitExceeded(let date) = classification {
                        throttled = true
                        retryAt = max(retryAt ?? date, date)
                        rateLimit.record(date)
                    }
                    let path = error["path"] as? [Any]
                    let affected = pending.filter { i in
                        guard let repo = path?.first as? String, repo == "r\(candidates[i].repository)" else { return false }
                        return path!.count == 1 || (path![1] as? String) == "b\(candidates[i].branch)"
                    }
                    if affected.isEmpty {
                        // A later rate error must not make earlier unknown errors safe to ignore.
                        if global == nil || global.map(isRateLimit) == true { global = classification }
                    } else {
                        for i in affected { scoped[i] = classification }
                    }
                }
            }
            for i in pending {
                if let error = scoped[i] {
                    candidates[i].result = .failure(error)
                    continue
                }
                // Unscoped non-rate errors cannot safely be attributed to any field.
                if let global, !isRateLimit(global) {
                    candidates[i].result = .failure(global)
                    continue
                }
                let candidate = candidates[i]
                do {
                    guard let repo = payload?["r\(candidate.repository)"] as? [String: Any],
                          let value = repo["b\(candidate.branch)"],
                          JSONSerialization.isValidJSONObject(value) else {
                        throw global ?? GitHubPullRequestError.invalidResponse
                    }
                    let connection: Connection = try decode(JSONSerialization.data(withJSONObject: value))
                    let models = try connection.nodes.map { try $0.model(repository: repositories[candidate.repository]) }
                    let matches = zip(connection.nodes, models).filter {
                        $0.0.headRepository?.nameWithOwner.lowercased() == branches[candidate.branch].repository
                            && $0.0.headRefName == branches[candidate.branch].name
                    }.map(\.1)
                    if let newest = matches.max(by: { $0.createdAt < $1.createdAt }) {
                        candidates[i].result = .success(newest)
                    } else if !connection.pageInfo.hasNextPage {
                        candidates[i].result = .success(nil)
                    } else {
                        guard let cursor = connection.pageInfo.endCursor, !cursor.isEmpty,
                              candidates[i].cursors.insert(cursor).inserted,
                              candidates[i].cursors.count < 100 else {
                            throw GitHubPullRequestError.invalidResponse
                        }
                        candidates[i].cursor = cursor
                    }
                } catch {
                    candidates[i].result = .failure(global ?? (error as? GitHubPullRequestError) ?? .invalidResponse)
                }
            }
            // Keep completed partial data, but never issue another page under a global throttle.
            if throttled {
                for i in candidates.indices where candidates[i].result == nil {
                    candidates[i].result = .failure(.rateLimitExceeded(retryAt: retryDeadline(response)))
                }
            }
        }
        let results: [GitHubBranch: Result<GitHubPullRequest?, GitHubPullRequestError>] =
            Dictionary(uniqueKeysWithValues: branches.indices.map { b in
            let results = candidates.filter { $0.branch == b }.compactMap(\.result)
            // A rate outcome must remain visible to the caller's shared backoff policy.
            for result in results {
                if case .failure(let error) = result, isRateLimit(error) { return (branches[b], .failure(error)) }
            }
            for result in results {
                if case .failure(let error) = result { return (branches[b], .failure(error)) }
            }
            let latest = results.compactMap { try? $0.get() }.max { $0.createdAt < $1.createdAt }
            return (branches[b], .success(latest))
        })
        return GitHubPullRequestBatch(results: results, retryAt: retryAt)
    }

    private func graphError(_ error: [String: Any], response: HTTPURLResponse) -> GitHubPullRequestError {
        let ext = error["extensions"] as? [String: Any]
        let code = (error["type"] as? String ?? ext?["code"] as? String ?? ext?["type"] as? String ?? "").uppercased()
        switch code {
        case "UNAUTHENTICATED", "UNAUTHORIZED", "BAD_CREDENTIALS": return .unauthorized
        case "FORBIDDEN": return .forbidden
        case "NOT_FOUND": return .notFound
        case "RATE_LIMITED", "RATE_LIMIT", "RATE_LIMIT_EXCEEDED":
            return .rateLimitExceeded(retryAt: retryDeadline(response))
        default: return .invalidResponse
        }
    }

    private func retryDeadline(_ response: HTTPURLResponse) -> Date {
        let current = now()
        var dates: [Date] = []
        if let value = response.value(forHTTPHeaderField: "Retry-After") {
            if let seconds = Double(value), seconds.isFinite, seconds >= 0 {
                dates.append(current.addingTimeInterval(seconds))
            } else {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
                if let date = formatter.date(from: value) { dates.append(date) }
            }
        }
        if let value = response.value(forHTTPHeaderField: "X-RateLimit-Reset"),
           let seconds = Double(value), seconds.isFinite {
            dates.append(Date(timeIntervalSince1970: seconds))
        }
        return dates.filter { $0 > current }.max() ?? current.addingTimeInterval(60)
    }

    private func send(
        path: String, accessToken: String, body: Data? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        guard !accessToken.isEmpty, !accessToken.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw GitHubPullRequestError.unauthorized
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.path = path
        guard let url = components.url else { throw GitHubPullRequestError.invalidResponse }
        var request = URLRequest(url: url)
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("DevBox", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw (error as? GitHubPullRequestError) ?? .network
        }
        try Task.checkCancellation()
        guard response.url == request.url else { throw GitHubPullRequestError.invalidResponse }
        switch response.statusCode {
        case 200: return (data, response)
        case 401: throw GitHubPullRequestError.unauthorized
        case 403:
            if response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0"
                || response.value(forHTTPHeaderField: "Retry-After") != nil {
                throw GitHubPullRequestError.rateLimitExceeded(retryAt: retryDeadline(response))
            }
            // Inspect only known classifications; never expose GitHub's message to UI.
            let message = (try? JSONDecoder().decode(APIError.self, from: data))?.message.lowercased() ?? ""
            if message.contains("rate limit") { throw GitHubPullRequestError.rateLimitExceeded(retryAt: retryDeadline(response)) }
            if message.contains("integration") || message.contains("installation") {
                throw GitHubPullRequestError.installationPermissions
            }
            throw GitHubPullRequestError.forbidden
        case 404: throw GitHubPullRequestError.notFound
        case 429: throw GitHubPullRequestError.rateLimitExceeded(retryAt: retryDeadline(response))
        case 500...599: throw GitHubPullRequestError.server
        default: throw GitHubPullRequestError.invalidResponse
        }
    }
}

/// Shared by copies of a service client, but never by different account clients.
/// No token or repository data is retained here.
private final class GraphQLRateLimit: Sendable {
    private let storage = Mutex<Date?>(nil)

    func deadline(after now: Date) -> Date? {
        storage.withLock { date in
            if let deadline = date, deadline > now { return deadline }
            date = nil
            return nil
        }
    }

    func record(_ date: Date) {
        storage.withLock { $0 = max($0 ?? date, date) }
    }
}

private struct APIError: Decodable { let message: String }

private func isRateLimit(_ error: GitHubPullRequestError) -> Bool {
    if case .rateLimitExceeded = error { return true }
    return false
}

private struct Candidate {
    let repository: Int
    let branch: Int
    var cursor: String?
    var cursors: Set<String> = []
    var result: Result<GitHubPullRequest?, GitHubPullRequestError>?
}

private struct Connection: Decodable {
    struct PageInfo: Decodable {
        let hasNextPage: Bool
        let endCursor: String?
    }
    let nodes: [PullRequestResponse]
    let pageInfo: PageInfo
}

private struct PullRequestResponse: Decodable {
    struct Repository: Decodable { let nameWithOwner: String }
    let number: Int
    let title: String
    let state: String
    let createdAt: String
    let headRefName: String
    let headRepository: Repository?

    private enum CodingKeys: String, CodingKey {
        case number, title, state, createdAt, headRefName, headRepository
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        number = try values.decode(Int.self, forKey: .number)
        title = try values.decode(String.self, forKey: .title)
        state = try values.decode(String.self, forKey: .state)
        createdAt = try values.decode(String.self, forKey: .createdAt)
        headRefName = try values.decode(String.self, forKey: .headRefName)
        // A deleted head repository is a legitimate null, but a missing field is malformed.
        guard values.contains(.headRepository) else { throw GitHubPullRequestError.invalidResponse }
        headRepository = try values.decodeIfPresent(Repository.self, forKey: .headRepository)
    }

    func model(repository: String) throws -> GitHubPullRequest {
        let formatter = ISO8601DateFormatter()
        var date = formatter.date(from: createdAt)
        if date == nil {
            formatter.formatOptions.insert(.withFractionalSeconds)
            date = formatter.date(from: createdAt)
        }
        guard number > 0, let date, let state = GitHubPullRequest.State(rawValue: state.lowercased()),
              validBranchName(headRefName), headRepository.map({ validRepository($0.nameWithOwner) }) ?? true,
              let url = URL(string: "https://github.com/\(repository)/pull/\(number)") else {
            throw GitHubPullRequestError.invalidResponse
        }
        // Construct the canonical link rather than trusting a server-provided URL.
        return GitHubPullRequest(
            number: number, title: title, url: url,
            state: state, createdAt: date
        )
    }
}

private func decode<T: Decodable>(_ data: Data) throws -> T {
    do { return try JSONDecoder().decode(T.self, from: data) }
    catch { throw GitHubPullRequestError.invalidResponse }
}

private func validRepository(_ value: String) -> Bool {
    let parts = value.split(separator: "/", omittingEmptySubsequences: false)
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
    return parts.count == 2 && parts.allSatisfy {
        !$0.isEmpty && $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy(allowed.contains)
    }
}

private func validBranchName(_ value: String) -> Bool {
    !value.isEmpty && !value.hasPrefix("/") && !value.hasSuffix("/")
        && !value.contains("//") && !value.contains("..") && !value.contains("@{")
        && !value.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0) || " ~^:?*[\\".unicodeScalars.contains($0)
        }
}
