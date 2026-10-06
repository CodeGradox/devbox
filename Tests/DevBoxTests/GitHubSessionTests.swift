import Foundation
import Observation
import Testing
@testable import DevBox
import DevBoxCore

// Shared in-memory fixtures: no test uses the default Keychain or network clients.
@MainActor
final class TestGitHubCredentials: GitHubCredentialsPersisting {
    var token: GitHubToken?
    var saves: [GitHubToken] = []
    var removals = 0
    var removalError: GitHubCredentialError?
    var saveError: GitHubCredentialError?
    var loadError: GitHubCredentialError?
    var saveGate: GitHubTestGate<Void>?
    var loadGate: GitHubTestGate<Void>?
    var loads = 0
    var saveAttempts = 0
    init(_ token: GitHubToken? = nil) { self.token = token }
    func load() async throws -> GitHubToken? {
        loads += 1
        let saved = token
        if let loadGate { await loadGate.enter() }
        if let loadError { throw loadError }
        return saved
    }
    func save(_ token: GitHubToken) async throws {
        saveAttempts += 1
        if let saveGate { await saveGate.enter() }
        if let saveError { throw saveError }
        saves.append(token)
        self.token = token
    }
    func remove() throws {
        removals += 1
        if let removalError { throw removalError }
        token = nil
    }
}

actor GitHubTestGate<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Never>?
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    func enter() async -> Value {
        await withCheckedContinuation {
            continuation = $0
            arrivals.forEach { $0.resume() }
            arrivals.removeAll()
        }
    }
    func waitForEntry() async {
        if continuation != nil { return }
        await withCheckedContinuation { arrivals.append($0) }
    }
    func release(_ value: Value) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

actor GitHubTestCalls {
    private(set) var values: [String] = []
    func record(_ value: String) { values.append(value) }
}

let githubTestDate = Date(timeIntervalSince1970: 1_000_000)
let githubTestUser = GitHubUser(login: "test-account", id: 42)
let githubTestToken = GitHubToken(accessToken: "synthetic-access", refreshToken: "synthetic-refresh")
let githubRenewedToken = GitHubToken(accessToken: "synthetic-renewed", refreshToken: "synthetic-refresh-2")

@MainActor
func testGitHubSession(
    credentials: TestGitHubCredentials,
    cache: GitHubPullRequestCache = GitHubPullRequestCache(
        repositories: { _, _ in [] },
        lookup: { branches, _, _ in
            GitHubPullRequestBatch(results: Dictionary(uniqueKeysWithValues: branches.map { ($0, .success(nil)) }))
        }
    ),
    refresh: @escaping @Sendable (GitHubToken) async throws -> GitHubToken = { _ in
        throw GitHubAPIError.invalidResponse
    },
    user: @escaping @Sendable (String) async throws -> GitHubUser = { _ in githubTestUser }
) -> GitHubSession {
    GitHubSession(
        credentials: credentials, pullRequests: cache,
        startAuthorization: { throw GitHubAPIError.invalidResponse },
        poll: { _ in throw GitHubAPIError.invalidResponse },
        refreshToken: refresh, loadUser: user, openBrowser: { _ in },
        now: { githubTestDate }
    )
}

@Test(.timeLimit(.minutes(1))) @MainActor
func githubSignInSavesOnlyAfterIdentityVerification() async {
    let credentials = TestGitHubCredentials()
    let verification = GitHubTestGate<GitHubUser>()
    var opened: [URL] = []
    let url = URL(string: "https://example.invalid/device")!
    let session = GitHubSession(
        credentials: credentials,
        startAuthorization: {
            GitHubDeviceAuthorization(deviceCode: "synthetic-device", userCode: "TEST",
                                      verificationURL: url, expiresAt: githubTestDate, interval: 1)
        },
        poll: { _ in githubTestToken },
        refreshToken: { _ in throw GitHubAPIError.invalidResponse },
        loadUser: { _ in await verification.enter() },
        openBrowser: { opened.append($0) }, now: { githubTestDate }
    )
    session.beginSignIn()
    await verification.waitForEntry()
    #expect(opened == [url])
    #expect(credentials.saves.isEmpty)
    #expect(session.user == nil)
    await verification.release(githubTestUser)
    for await busy in Observations({ session.isSigningIn }) {
        if !busy { break }
    }
    #expect(credentials.saves == [githubTestToken])
    #expect(session.user == githubTestUser)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func githubRestoreIsOnceAndSignOutRemovalFailureIsVisible() async {
    let credentials = TestGitHubCredentials(githubTestToken)
    let calls = GitHubTestCalls()
    let session = testGitHubSession(credentials: credentials, user: { token in
        await calls.record(token)
        return githubTestUser
    })
    await session.restoreIfNeeded()
    await session.restoreIfNeeded()
    #expect(await calls.values == [githubTestToken.accessToken])
    #expect(session.user == githubTestUser)
    #expect(credentials.saves.isEmpty)
    credentials.removalError = GitHubCredentialError(operation: "remove", status: -50)
    await session.signOut()
    #expect(session.user == githubTestUser)
    #expect(session.errorMessage?.contains("remove") == true)
    #expect(credentials.token == githubTestToken)
    credentials.removalError = nil
    await session.signOut()
    #expect(session.user == nil)
    #expect(credentials.token == nil)
    #expect(session.errorMessage == nil)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func githubExpiredRestoreRefreshesAndConcurrentRequestsShareRefresh() async throws {
    let expired = GitHubToken(accessToken: "synthetic-expired", refreshToken: "synthetic-refresh",
                              expiresAt: githubTestDate)
    let credentials = TestGitHubCredentials(expired)
    let gate = GitHubTestGate<GitHubToken>()
    let calls = GitHubTestCalls()
    let session = testGitHubSession(credentials: credentials, refresh: { token in
        await calls.record(token.accessToken)
        return await gate.enter()
    })
    let restore = Task { await session.restore() }
    await gate.waitForEntry()
    let requests = (0..<8).map { _ in Task { try await session.authorized { $0 } } }
    await gate.release(githubRenewedToken)
    await restore.value
    for request in requests {
        #expect(try await request.value == githubRenewedToken.accessToken)
    }
    #expect(await calls.values == [expired.accessToken])
    #expect(credentials.saves == [githubRenewedToken])
    #expect(session.user == githubTestUser)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func githubLate401UsesAlreadyRefreshedToken() async throws {
    let credentials = TestGitHubCredentials(githubTestToken)
    let refreshes = GitHubTestCalls()
    let requests = GitHubTestCalls()
    let gate = GitHubTestGate<Void>()
    let session = testGitHubSession(credentials: credentials, refresh: { token in
        await refreshes.record(token.accessToken)
        return githubRenewedToken
    })
    await session.restore()
    let late = Task {
        try await session.authorized { token in
            await requests.record(token)
            if token == githubTestToken.accessToken {
                await gate.enter()
                throw GitHubAPIError.unauthorized
            }
            return token
        }
    }
    await gate.waitForEntry()
    let first = try await session.authorized { token in
        if token == githubTestToken.accessToken { throw GitHubAPIError.unauthorized }
        return token
    }
    await gate.release(())
    #expect(try await late.value == first)
    #expect(await refreshes.values == [githubTestToken.accessToken])
    #expect(await requests.values == [githubTestToken.accessToken, githubRenewedToken.accessToken])
}

@Test(.timeLimit(.minutes(1))) @MainActor
func github401RetriesExactlyOnceThenClearsCredentials() async {
    let credentials = TestGitHubCredentials(githubTestToken)
    let calls = GitHubTestCalls()
    let session = testGitHubSession(credentials: credentials, refresh: { _ in githubRenewedToken })
    await session.restore()
    do {
        let _: String = try await session.authorized { token in
            await calls.record(token)
            throw GitHubAPIError.unauthorized
        }
        Issue.record("Expected unauthorized")
    } catch {
        #expect(error as? GitHubAPIError == .unauthorized)
    }
    #expect(await calls.values == [githubTestToken.accessToken, githubRenewedToken.accessToken])
    #expect(credentials.removals == 1)
    #expect(session.user == nil)
}

@Test(.timeLimit(.minutes(1)), arguments: [GitHubAPIError.transportFailed, .unauthorized])
@MainActor
func githubRefreshFailurePreservesOnlyTransientCredentials(failure: GitHubAPIError) async {
    let credentials = TestGitHubCredentials(githubTestToken)
    let session = testGitHubSession(credentials: credentials, refresh: { _ in throw failure })
    await session.restore()
    do {
        let _: String = try await session.authorized { _ in throw GitHubAPIError.unauthorized }
        Issue.record("Expected refresh failure")
    } catch { #expect(error as? GitHubAPIError == failure) }
    #expect((credentials.token != nil) == (failure == .transportFailed))
    #expect((session.user != nil) == (failure == .transportFailed))
}

@Test(.timeLimit(.minutes(1))) @MainActor
func githubRefreshRejectsAccountIdentityChange() async {
    let credentials = TestGitHubCredentials(githubTestToken)
    let session = testGitHubSession(credentials: credentials, refresh: { _ in githubRenewedToken },
                                   user: { token in
        token == githubTestToken.accessToken ? githubTestUser : GitHubUser(login: "other", id: 99)
    })
    await session.restore()
    do {
        let _: String = try await session.authorized { _ in throw GitHubAPIError.unauthorized }
        Issue.record("Expected identity rejection")
    } catch { #expect(error as? GitHubAPIError == .unauthorized) }
    #expect(credentials.token == nil)
    #expect(session.user == nil)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func githubRotatedTokenSurvivesIdentityVerificationFailure() async throws {
    let credentials = TestGitHubCredentials(githubTestToken)
    let refreshes = GitHubTestCalls()
    let verifications = GitHubTestCalls()
    let gate = GitHubTestGate<Void>()
    let session = testGitHubSession(credentials: credentials, refresh: { token in
        await refreshes.record(token.accessToken)
        return githubRenewedToken
    }, user: { token in
        if token == githubRenewedToken.accessToken {
            await verifications.record(token)
            let calls = await verifications.values
            if calls.count == 1 {
                await gate.enter()
                throw GitHubAPIError.transportFailed
            }
        }
        return githubTestUser
    })
    await session.restore()
    let request = Task {
        try await session.authorized { token in
            if token == githubTestToken.accessToken { throw GitHubAPIError.unauthorized }
            return token
        }
    }
    await gate.waitForEntry()
    await gate.release(())
    do {
        _ = try await request.value
        Issue.record("Expected identity verification failure")
    } catch { #expect(error as? GitHubAPIError == .transportFailed) }
    #expect(credentials.token == githubRenewedToken)
    let value = try await session.authorized { $0 }
    #expect(value == githubRenewedToken.accessToken)
    #expect(await refreshes.values == [githubTestToken.accessToken])
    #expect(await verifications.values.count == 2)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func githubRotatedTokenSurvivesCredentialSaveFailure() async throws {
    let credentials = TestGitHubCredentials(githubTestToken)
    let refreshes = GitHubTestCalls()
    let session = testGitHubSession(credentials: credentials, refresh: { token in
        await refreshes.record(token.accessToken)
        return githubRenewedToken
    })
    await session.restore()
    credentials.saveError = GitHubCredentialError(operation: "save", status: -50)
    do {
        _ = try await session.authorized { token in
            if token == githubTestToken.accessToken { throw GitHubAPIError.unauthorized }
            return token
        }
        Issue.record("Expected persistence failure")
    } catch { #expect(error is GitHubCredentialError) }
    #expect(session.user == githubTestUser)
    for _ in 0..<5 {
        do {
            _ = try await session.authorized { $0 }
            Issue.record("Expected latched credential failure")
        } catch { #expect(error is GitHubCredentialError) }
    }
    #expect(credentials.saveAttempts == 1)
    #expect(session.credentialAccessFailed)
    credentials.saveError = nil
    await session.retryCredentialAccess()
    #expect(!session.credentialAccessFailed)
    #expect(credentials.saveAttempts == 2)
    #expect(try await session.authorized { $0 } == githubRenewedToken.accessToken)
    #expect(credentials.token == githubRenewedToken)
    #expect(await refreshes.values == [githubTestToken.accessToken])
}

@Test(.timeLimit(.minutes(1))) @MainActor
func githubSignOutBlocksLateRefreshAndRestore() async {
    let credentials = TestGitHubCredentials(GitHubToken(
        accessToken: "synthetic-expired", refreshToken: "synthetic-refresh", expiresAt: githubTestDate
    ))
    let gate = GitHubTestGate<GitHubToken>()
    let session = testGitHubSession(credentials: credentials, refresh: { _ in await gate.enter() })
    let restore = Task { await session.restore() }
    await gate.waitForEntry()
    let signOut = Task { await session.signOut() }
    for await signingOut in Observations({ session.isSigningOut }) {
        if signingOut { break }
    }
    await gate.release(githubRenewedToken) // Deliberately ignores cancellation.
    await signOut.value
    await restore.value
    #expect(session.user == nil)
    #expect(credentials.saves == [githubRenewedToken])
    #expect(credentials.token == nil)
    #expect(!session.isRestoring)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func githubExpiredRefreshTokenCannotBeUsed() async {
    let credentials = TestGitHubCredentials(GitHubToken(
        accessToken: "synthetic-expired", refreshToken: "synthetic-expired-refresh",
        expiresAt: githubTestDate, refreshTokenExpiresAt: githubTestDate
    ))
    let calls = GitHubTestCalls()
    let session = testGitHubSession(credentials: credentials, refresh: { token in
        await calls.record(token.accessToken)
        return githubRenewedToken
    })
    await session.restore()
    #expect(await calls.values.isEmpty)
    #expect(credentials.token == nil)
    #expect(session.user == nil)
    #expect(session.errorMessage != nil)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func githubReadDenialRestoresOnlyOnceUntilExplicitRetry() async {
    let credentials = TestGitHubCredentials(githubTestToken)
    credentials.loadError = GitHubCredentialError(operation: "read", status: -128)
    let gate = GitHubTestGate<Void>()
    credentials.loadGate = gate
    let session = testGitHubSession(credentials: credentials)
    let first = Task { await session.restoreIfNeeded() }
    await gate.waitForEntry()
    await session.restoreIfNeeded()
    #expect(credentials.loads == 1)
    await gate.release(())
    await first.value
    await session.restoreIfNeeded()
    #expect(credentials.loads == 1)
    #expect(session.errorMessage?.contains("read") == true)
    #expect(credentials.removals == 0)
    #expect(credentials.token == githubTestToken)
    await #expect(throws: GitHubCredentialError.self) {
        _ = try await session.authorized { $0 }
    }
    await session.restore()
    #expect(credentials.loads == 1)
    #expect(credentials.removals == 0)
    credentials.loadGate = nil
    credentials.loadError = nil
    await session.retryCredentialAccess()
    #expect(credentials.loads == 2)
    #expect(session.user == githubTestUser)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func githubSignOutOrdersRemovalAfterAlreadySubmittedSave() async {
    let credentials = TestGitHubCredentials(githubTestToken)
    let session = testGitHubSession(credentials: credentials, refresh: { _ in githubRenewedToken })
    await session.restore()
    let gate = GitHubTestGate<Void>()
    credentials.saveGate = gate
    let request = Task {
        try await session.authorized { token in
            if token == githubTestToken.accessToken { throw GitHubAPIError.unauthorized }
            return token
        }
    }
    await gate.waitForEntry()
    let signOut = Task { await session.signOut() }
    while !session.isSigningOut { await Task.yield() }
    #expect(credentials.removals == 0)
    session.beginSignIn()
    #expect(!session.isSigningIn)
    await gate.release(())
    await signOut.value
    await #expect(throws: CancellationError.self) { _ = try await request.value }
    #expect(credentials.saves == [githubRenewedToken])
    #expect(credentials.removals == 1)
    #expect(credentials.token == nil)
    #expect(session.user == nil)
    #expect(!session.isSigningOut)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func githubRefusedSignOutKeepsAnInFlightRotatedToken() async throws {
    let credentials = TestGitHubCredentials(githubTestToken)
    let gate = GitHubTestGate<GitHubToken>()
    let refreshes = GitHubTestCalls()
    let session = testGitHubSession(credentials: credentials, refresh: { token in
        await refreshes.record(token.accessToken)
        return await gate.enter()
    })
    await session.restore()
    let request = Task {
        try await session.authorized { token in
            if token == githubTestToken.accessToken { throw GitHubAPIError.unauthorized }
            return token
        }
    }
    await gate.waitForEntry()
    credentials.removalError = GitHubCredentialError(operation: "remove", status: -128)
    let signOut = Task { await session.signOut() }
    for await signingOut in Observations({ session.isSigningOut }) {
        if signingOut { break }
    }
    #expect(credentials.removals == 0)
    await gate.release(githubRenewedToken)
    await signOut.value
    await #expect(throws: CancellationError.self) { _ = try await request.value }
    #expect(session.user == githubTestUser)
    #expect(session.errorMessage != nil)
    #expect(credentials.token == githubRenewedToken)
    #expect(try await session.authorized { $0 } == githubRenewedToken.accessToken)
    #expect(await refreshes.values == [githubTestToken.accessToken])
    credentials.removalError = nil
    await session.signOut()
    #expect(session.user == nil)
    #expect(credentials.token == nil)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func githubSignOutPreventsLateUnauthorizedRequestsStartingAnotherRotation() async {
    let credentials = TestGitHubCredentials(githubTestToken)
    let rotation = GitHubTestGate<GitHubToken>()
    let response = GitHubTestGate<Void>()
    let refreshes = GitHubTestCalls()
    let session = testGitHubSession(credentials: credentials, refresh: { token in
        await refreshes.record(token.accessToken)
        return await rotation.enter()
    })
    await session.restore()
    let lateRequest = Task {
        try await session.authorized { _ -> String in
            await response.enter()
            throw GitHubAPIError.unauthorized
        }
    }
    await response.waitForEntry()
    let refreshingRequest = Task {
        try await session.authorized { token in
            if token == githubTestToken.accessToken { throw GitHubAPIError.unauthorized }
            return token
        }
    }
    await rotation.waitForEntry()
    let signOut = Task { await session.signOut() }
    for await signingOut in Observations({ session.isSigningOut }) {
        if signingOut { break }
    }
    await response.release(())
    await #expect(throws: CancellationError.self) { _ = try await lateRequest.value }
    await rotation.release(githubRenewedToken)
    await signOut.value
    await #expect(throws: CancellationError.self) { _ = try await refreshingRequest.value }
    #expect(await refreshes.values == [githubTestToken.accessToken])
    #expect(credentials.token == nil)
    #expect(session.user == nil)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func githubSignOutRejectsLateCredentialRead() async {
    let credentials = TestGitHubCredentials(githubTestToken)
    let gate = GitHubTestGate<Void>()
    credentials.loadGate = gate
    let session = testGitHubSession(credentials: credentials)
    let restore = Task { await session.restoreIfNeeded() }
    await gate.waitForEntry()
    await session.signOut()
    await gate.release(())
    await restore.value
    #expect(session.user == nil)
    #expect(credentials.token == nil)
    #expect(credentials.saves.isEmpty)
    #expect(!session.isRestoring)
}
