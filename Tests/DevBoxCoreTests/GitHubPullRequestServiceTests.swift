import Foundation
import Testing
@testable import DevBoxCore

private actor PullRequestTransport: GitHubPullRequestTransport {
    struct Reply: Sendable {
        var body: String
        var status = 200
        var headers: [String: String] = [:]
        var url: URL?
    }
    var replies: [Reply]
    var requests: [URLRequest] = []
    init(_ replies: [Reply]) { self.replies = replies }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.notConnectedToInternet) }
        let reply = replies.removeFirst()
        return (Data(reply.body.utf8), HTTPURLResponse(
            url: reply.url ?? request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers
        )!)
    }
}

private let feature = GitHubBranch(repository: "fork/repo", name: "feature")
private let clock = Date(timeIntervalSince1970: 1_700_000_000)
private func pull(_ number: Int, repo: String = "fork/repo", ref: String = "feature",
                  state: String = "OPEN", day: Int = 1) -> String {
    let value: [String: Any] = [
        "number": number, "title": "PR \(number)", "state": state,
        "createdAt": String(format: "2025-01-%02dT00:00:00Z", day),
        "headRefName": ref, "headRepository": ["nameWithOwner": repo]
    ]
    return String(decoding: try! JSONSerialization.data(withJSONObject: value), as: UTF8.self)
}
private func connection(_ nodes: [String] = [], cursor: String? = nil) -> String {
    let page: [String: Any] = ["hasNextPage": cursor != nil, "endCursor": cursor.map { $0 as Any } ?? NSNull()]
    return #"{"nodes":["# + nodes.joined(separator: ",") + #"],"pageInfo":"#
        + String(decoding: try! JSONSerialization.data(withJSONObject: page), as: UTF8.self) + "}"
}
private func envelope(_ fields: String, errors: String? = nil) -> String {
    #"{"data":{"# + fields + "}" + (errors.map { #","errors":"# + $0 } ?? "") + "}"
}
private func requestBody(_ request: URLRequest) throws -> [String: Any] {
    let data = try #require(request.httpBody)
    let object = try JSONSerialization.jsonObject(with: data)
    return try #require(object as? [String: Any])
}

@Test func githubBranchURLPreservesEscapingAndCase() throws {
    let branch = try #require(GitHubBranch(branchURL: URL(
        string: "https://github.com/Owner/Repo/tree/feature%2F%23%25%E9%9B%AA"
    )!))
    #expect(branch == GitHubBranch(repository: "OWNER/REPO", name: "feature/#%雪"))
    #expect(branch != GitHubBranch(repository: "owner/repo", name: "Feature/#%雪"))
    #expect(GitHubBranch(branchURL: URL(string: "https://github.com/o/r/tree/a/b")!)?.name == "a/b")
    #expect(GitHubBranch(branchURL: URL(string: "https://github.com/o/r/tree/a%252Fb")!)?.name == "a%2Fb")
}

@Test(arguments: [
    "http://github.com/o/r/tree/main", "https://evil.example/o/r/tree/main",
    "https://github.com.evil.example/o/r/tree/main", "https://user@github.com/o/r/tree/main",
    "https://github.com:443/o/r/tree/main", "https://github.com/o/r/tree/main?x=y",
    "https://github.com/o/r/tree/main#fragment", "https://github.com/o/r/commit/main",
    "https://github.com/o/r/tree/", "https://github.com/o%2Fx/r/tree/main",
    "https://github.com/o/../tree/main", "https://github.com/o/r/tree/a%00b"
])
func githubBranchRejectsUntrustedURLs(_ string: String) {
    #expect(GitHubBranch(branchURL: URL(string: string)!) == nil)
}

@Test func githubMetadataAddsValidatedParent() async throws {
    let transport = PullRequestTransport([
        .init(body: #"{"fork":true,"parent":{"full_name":"Parent/Repo"}}"#),
        .init(body: #"{"fork":false}"#),
        .init(body: #"{"fork":true,"parent":{"full_name":"../evil"}}"#)
    ])
    let service = GitHubPullRequestService(transport: transport)
    #expect(try await service.repositories(for: "Fork/Repo", accessToken: "synthetic") == ["fork/repo", "parent/repo"])
    #expect(try await service.repositories(for: "Fork/Repo", accessToken: "synthetic") == ["fork/repo"])
    await #expect(throws: GitHubPullRequestError.invalidResponse) {
        try await service.repositories(for: "Fork/Repo", accessToken: "synthetic")
    }
}

@Test(arguments: [#"{"fork":true}"#, #"{"fork":true,"parent":null}"#])
func githubForkWithoutParentCannotClaimAbsence(_ body: String) async {
    let service = GitHubPullRequestService(transport: PullRequestTransport([.init(body: body)]))
    await #expect(throws: GitHubPullRequestError.invalidResponse) {
        try await service.repositories(for: "fork/repo", accessToken: "synthetic")
    }
}

@Test func githubTwentyFiveBranchesUseOneSecurePostAndVariables() async throws {
    let branches = (0..<25).map { GitHubBranch(repository: "fork/repo", name: "feature/\($0)#%雪&+\"") }
    let fields = branches.indices.map { "\"b\($0)\":\(connection())" }.joined(separator: ",")
    let transport = PullRequestTransport([.init(body: envelope("\"r0\":{\(fields)}"))])
    let results = try await GitHubPullRequestService(transport: transport).pullRequests(
        for: branches + [branches[0]], repositories: ["fork/repo"], accessToken: "synthetic"
    )
    #expect(results.results.count == 25)
    #expect(results.retryAt == nil)
    for branch in branches { #expect(try results.results[branch]?.get() == nil) }
    let requests = await transport.requests
    #expect(requests.count == 1)
    let request = try #require(requests.first)
    #expect(request.url?.absoluteString == "https://api.github.com/graphql")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(request.httpShouldHandleCookies == false)
    #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
    let body = try requestBody(request)
    let variables = try #require(body["variables"] as? [String: Any])
    let query = try #require(body["query"] as? String)
    for b in branches.indices {
        #expect(variables["headr0b\(b)"] as? String == branches[b].name)
        #expect(!query.contains(branches[b].name))
    }
    #expect(query.contains("states: [OPEN,CLOSED,MERGED]"))
    #expect(query.contains("first: 10"))
}

@Test func githubNewestAcrossCandidatesAndAllStates() async throws {
    let transport = PullRequestTransport([.init(body: envelope("""
    "r0":{"b0":\(connection([pull(1), pull(2, state: "CLOSED", day: 3)]))},
    "r1":{"b0":\(connection([pull(3, state: "MERGED", day: 5)]))}
    """))])
    let results = try await GitHubPullRequestService(transport: transport).pullRequests(
        for: [feature], repositories: ["parent/repo", "fork/repo"], accessToken: "synthetic"
    )
    let value = try results.results[feature]?.get()
    let pr = try #require(value)
    #expect(pr.number == 3)
    #expect(pr.state == .merged)
    #expect(pr.url.absoluteString == "https://github.com/parent/repo/pull/3")
}

@Test func githubExactHeadPaginationOnlyPendingAliases() async throws {
    let other = GitHubBranch(repository: "fork/repo", name: "done")
    let transport = PullRequestTransport([
        .init(body: envelope("""
        "r0":{"b0":\(connection([pull(1, repo: "other/repo"), pull(2, ref: "Feature")], cursor: "next")),
        "b1":\(connection())}
        """)),
        .init(body: envelope(#""r0":{"b0":"# + connection([pull(3, repo: "FORK/REPO", state: "CLOSED")]) + "}"))
    ])
    let results = try await GitHubPullRequestService(transport: transport).pullRequests(
        for: [feature, other], repositories: ["parent/repo"], accessToken: "synthetic"
    )
    #expect(try results.results[feature]?.get()?.number == 3)
    #expect(try results.results[other]?.get() == nil)
    let requests = await transport.requests
    #expect(requests.count == 2)
    let body = try requestBody(requests[1])
    #expect(!(body["query"] as! String).contains("b1:"))
    #expect((body["variables"] as! [String: Any])["cursorr0b0"] as? String == "next")
}

@Test(arguments: ["FORBIDDEN", "NOT_FOUND"])
func githubPartialFieldErrorsAreScoped(_ code: String) async throws {
    let other = GitHubBranch(repository: "fork/repo", name: "other")
    let transport = PullRequestTransport([.init(body: envelope(
        #""r0":{"b0":null,"b1":"# + connection([pull(2, ref: "other")]) + "}",
        errors: #"[{"type":""# + code + #"","message":"untrusted synthetic","path":["r0","b0","nodes",0,"title"]}]"#
    ))])
    let results = try await GitHubPullRequestService(transport: transport).pullRequests(
        for: [feature, other], repositories: ["fork/repo"], accessToken: "synthetic"
    )
    #expect(results.results[feature] == .failure(code == "FORBIDDEN" ? .forbidden : .notFound))
    #expect(try results.results[other]?.get()?.number == 2)
}

@Test func githubCandidateFailureCannotClaimNewest() async throws {
    let transport = PullRequestTransport([.init(body: envelope(
        #""r0":{"b0":"# + connection([pull(1)]) + #"},"r1":null"#,
        errors: #"[{"type":"NOT_FOUND","path":["r1"]}]"#
    ))])
    let results = try await GitHubPullRequestService(transport: transport).pullRequests(
        for: [feature], repositories: ["fork/repo", "parent/repo"], accessToken: "synthetic"
    )
    #expect(results.results[feature] == .failure(.notFound))
}

@Test(arguments: [
    #"{"data":{"r0":null}}"#, #"{"data":{"r0":{"b0":null}}}"#,
    #"{"data":{"r0":{"b0":{"nodes":[]}}}}"#, #"{"data":null}"#, "not json",
    #"{"data":{"r0":{"b0":{"nodes":[null],"pageInfo":{"hasNextPage":false}}}}}"#,
    #"{"data":{"r0":{"b0":{"nodes":[],"pageInfo":{"hasNextPage":true,"endCursor":null}}}}}"#
])
func githubMalformedIsNeverNoPR(_ body: String) async throws {
    let service = GitHubPullRequestService(transport: PullRequestTransport([.init(body: body)]))
    let results = try await service.pullRequests(for: [feature], repositories: ["fork/repo"], accessToken: "synthetic")
    #expect(results.results[feature] == .failure(.invalidResponse))
}

@Test func githubRepeatingCursorFailsClosed() async throws {
    let body = envelope(#""r0":{"b0":"# + connection(cursor: "repeat") + "}")
    let transport = PullRequestTransport([.init(body: body), .init(body: body)])
    let results = try await GitHubPullRequestService(transport: transport).pullRequests(
        for: [feature], repositories: ["fork/repo"], accessToken: "synthetic"
    )
    #expect(results.results[feature] == .failure(.invalidResponse))
    #expect(await transport.requests.count == 2)
}

@Test func githubGraphQLAuthenticationThrows() async {
    let service = GitHubPullRequestService(transport: PullRequestTransport([
        .init(body: #"{"errors":[{"extensions":{"code":"UNAUTHENTICATED"},"message":"synthetic"}]}"#)
    ]))
    await #expect(throws: GitHubPullRequestError.unauthorized) {
        try await service.pullRequests(for: [feature], repositories: ["fork/repo"], accessToken: "synthetic")
    }
}

@Test func githubGlobalThrottlePreservesCompletedDataAndStopsPagination() async throws {
    let other = GitHubBranch(repository: "fork/repo", name: "other")
    let transport = PullRequestTransport([.init(body: envelope(
        #""r0":{"b0":"# + connection([pull(1)]) + #","b1":"# + connection(cursor: "next") + "}",
        errors: #"[{"type":"RATE_LIMITED","message":"synthetic"}]"#
    ), headers: ["Retry-After": "120"])])
    let results = try await GitHubPullRequestService(transport: transport, now: { clock }).pullRequests(
        for: [feature, other], repositories: ["fork/repo"], accessToken: "synthetic"
    )
    #expect(try results.results[feature]?.get()?.number == 1)
    #expect(results.results[other] == .failure(.rateLimitExceeded(retryAt: clock.addingTimeInterval(120))))
    #expect(results.retryAt == clock.addingTimeInterval(120))
    #expect(await transport.requests.count == 1)
}

@Test func githubHTTPFailuresAndDeadlinesAreSanitized() async throws {
    let cases: [(Int, String, [String: String], GitHubPullRequestError)] = [
        (401, "synthetic", [:], .unauthorized),
        (403, "synthetic", [:], .forbidden),
        (403, #"{"message":"Resource not accessible by integration synthetic"}"#, [:], .installationPermissions),
        (403, "synthetic", ["X-RateLimit-Remaining": "0"], .rateLimitExceeded(retryAt: clock.addingTimeInterval(60))),
        (403, #"{"message":"secondary rate limit synthetic"}"#, [:], .rateLimitExceeded(retryAt: clock.addingTimeInterval(60))),
        (429, "synthetic", ["Retry-After": "120", "X-RateLimit-Reset": "1700000300"], .rateLimitExceeded(retryAt: clock.addingTimeInterval(300))),
        (429, "synthetic", ["Retry-After": "Tue, 14 Nov 2023 22:15:20 GMT"], .rateLimitExceeded(retryAt: clock.addingTimeInterval(120))),
        (404, "synthetic", [:], .notFound),
        (503, "synthetic", [:], .server),
        (302, "synthetic", ["Location": "https://evil.example"], .invalidResponse)
    ]
    for (status, body, headers, error) in cases {
        let service = GitHubPullRequestService(
            transport: PullRequestTransport([.init(body: body, status: status, headers: headers)]), now: { clock }
        )
        await #expect(throws: error) {
            try await service.repositories(for: "fork/repo", accessToken: "synthetic")
        }
        #expect(!error.localizedDescription.contains("synthetic"))
    }
}

@Test func githubScopedThrottleKeepsUnaffectedSuccess() async throws {
    let other = GitHubBranch(repository: "fork/repo", name: "other")
    let transport = PullRequestTransport([.init(body: envelope(
        #""r0":{"b0":null,"b1":"# + connection([pull(2, ref: "other")]) + "}",
        errors: #"[{"extensions":{"code":"RATE_LIMITED"},"path":["r0","b0"]}]"#
    ))])
    let results = try await GitHubPullRequestService(transport: transport, now: { clock }).pullRequests(
        for: [feature, other], repositories: ["fork/repo"], accessToken: "synthetic"
    )
    #expect(results.results[feature] == .failure(.rateLimitExceeded(retryAt: clock.addingTimeInterval(60))))
    #expect(try results.results[other]?.get()?.number == 2)
}

@Test(arguments: [
    #"[{"type":"UNKNOWN","message":"synthetic"}]"#,
    #"[{"type":"FORBIDDEN","path":["unexpected"]}]"#
])
func githubUnscopedErrorsFailClosed(_ errors: String) async throws {
    let transport = PullRequestTransport([.init(body: envelope(
        #""r0":{"b0":"# + connection([pull(1)]) + "}", errors: errors
    ))])
    let results = try await GitHubPullRequestService(transport: transport).pullRequests(
        for: [feature], repositories: ["fork/repo"], accessToken: "synthetic"
    )
    guard case .failure = results.results[feature] else {
        Issue.record("Unscoped errors must not produce successful results")
        return
    }
}

@Test func githubExhaustedHTTPBudgetStopsPendingPages() async throws {
    let transport = PullRequestTransport([.init(
        body: envelope(#""r0":{"b0":"# + connection(cursor: "next") + "}"),
        headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1700000180"]
    )])
    let results = try await GitHubPullRequestService(transport: transport, now: { clock }).pullRequests(
        for: [feature], repositories: ["fork/repo"], accessToken: "synthetic"
    )
    #expect(results.results[feature] == .failure(.rateLimitExceeded(retryAt: clock.addingTimeInterval(180))))
    #expect(await transport.requests.count == 1)
}

@Test func githubValidationAndResponseURLSecurity() async throws {
    let transport = PullRequestTransport([])
    let service = GitHubPullRequestService(transport: transport)
    await #expect(throws: GitHubPullRequestError.invalidResponse) {
        try await service.pullRequests(for: [feature], repositories: ["https://evil.example/repo"], accessToken: "synthetic")
    }
    await #expect(throws: GitHubPullRequestError.invalidResponse) {
        try await service.pullRequests(for: (0..<26).map { .init(repository: "fork/repo", name: "\($0)") },
                                       repositories: ["fork/repo"], accessToken: "synthetic")
    }
    await #expect(throws: GitHubPullRequestError.unauthorized) {
        try await service.pullRequests(for: [feature], repositories: ["fork/repo"], accessToken: "bad token")
    }
    #expect(await transport.requests.isEmpty)
    let unsafe = PullRequestTransport([.init(body: "{}", url: URL(string: "https://evil.example"))])
    let results = try await GitHubPullRequestService(transport: unsafe).pullRequests(
        for: [feature], repositories: ["fork/repo"], accessToken: "synthetic"
    )
    #expect(results.results[feature] == .failure(.invalidResponse))
}

@Test func githubCancellationIsPreserved() async {
    struct CancelledTransport: GitHubPullRequestTransport {
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            throw URLError(.cancelled)
        }
    }
    await #expect(throws: CancellationError.self) {
        try await GitHubPullRequestService(transport: CancelledTransport()).pullRequests(
            for: [feature], repositories: ["fork/repo"], accessToken: "synthetic"
        )
    }
}

@Test(arguments: [
    ("", "feature"), ("broken", "feature"), ("../repo", "feature"),
    ("fork/repo", ""), ("fork/repo", "bad..ref")
])
func githubMalformedSourceIsNotAnEmptyResult(_ repository: String, _ ref: String) async throws {
    let transport = PullRequestTransport([.init(body: envelope(
        #""r0":{"b0":"# + connection([pull(1, repo: repository, ref: ref)]) + "}"
    ))])
    let batch = try await GitHubPullRequestService(transport: transport).pullRequests(
        for: [feature], repositories: ["fork/repo"], accessToken: "synthetic"
    )
    #expect(batch.results[feature] == .failure(.invalidResponse))
}

@Test(arguments: [false, true])
func githubSuccessfulBatchStillReturnsExhaustedBudget(_ graphError: Bool) async throws {
    let transport = PullRequestTransport([.init(
        body: envelope(
            #""r0":{"b0":"# + connection([pull(1)]) + "}",
            errors: graphError ? #"[{"type":"RATE_LIMITED"}]"# : nil
        ),
        headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1700000180"]
    )])
    let service = GitHubPullRequestService(transport: transport, now: { clock })
    let batch = try await service.pullRequests(for: [feature], repositories: ["fork/repo"], accessToken: "synthetic")
    #expect(try batch.results[feature]?.get()?.number == 1)
    #expect(batch.retryAt == clock.addingTimeInterval(180))
    let blocked = try await service.pullRequests(for: [feature], repositories: ["fork/repo"], accessToken: "synthetic")
    #expect(blocked.results[feature] == .failure(.rateLimitExceeded(retryAt: clock.addingTimeInterval(180))))
    #expect(await transport.requests.count == 1)
}

private actor ConcurrentPageTransport: GitHubPullRequestTransport {
    private(set) var count = 0
    private var held: CheckedContinuation<Void, Never>?
    private var arrivals: [CheckedContinuation<Void, Never>] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        count += 1
        let variables = try #require(requestBody(request)["variables"] as? [String: Any])
        let name = variables["headr0b0"] as? String
        let body: String
        var headers: [String: String] = [:]
        if name == "waiting" {
            // Don't hang on an unexpected next page if the budget check regresses.
            guard variables["cursorr0b0"] is NSNull else { throw URLError(.badServerResponse) }
            await withCheckedContinuation { continuation in
                held = continuation
                arrivals.forEach { $0.resume() }
                arrivals.removeAll()
            }
            body = envelope(
                #""r0":{"b0":"# + connection([pull(1, repo: "another/repo", ref: "waiting")], cursor: "next")
                + #","b1":"# + connection([pull(2, ref: "finished")]) + "}"
            )
        } else {
            body = envelope(#""r0":{"b0":"# + connection([pull(3, ref: "limited")]) + "}")
            headers = ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1700000180"]
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!)
    }

    func waitForHeldPage() async {
        if held != nil { return }
        await withCheckedContinuation { arrivals.append($0) }
    }

    func release() {
        held?.resume()
        held = nil
    }
}

@Test(.timeLimit(.minutes(1)))
func githubSiblingThrottleStopsNewPagesButKeepsReceivedMatches() async throws {
    let transport = ConcurrentPageTransport()
    let service = GitHubPullRequestService(transport: transport, now: { clock })
    let waiting = GitHubBranch(repository: "fork/repo", name: "waiting")
    let finished = GitHubBranch(repository: "fork/repo", name: "finished")
    let limited = GitHubBranch(repository: "fork/repo", name: "limited")
    let pending = Task {
        try await service.pullRequests(for: [waiting, finished], repositories: ["fork/repo"], accessToken: "synthetic")
    }
    await transport.waitForHeldPage()
    let complete = try await service.pullRequests(for: [limited], repositories: ["fork/repo"], accessToken: "synthetic")
    #expect(try complete.results[limited]?.get()?.number == 3)
    await transport.release()
    let batch = try await pending.value
    #expect(batch.results[waiting] == .failure(.rateLimitExceeded(retryAt: clock.addingTimeInterval(180))))
    #expect(try batch.results[finished]?.get()?.number == 2)
    #expect(batch.retryAt == clock.addingTimeInterval(180))
    #expect(await transport.count == 2)
}
