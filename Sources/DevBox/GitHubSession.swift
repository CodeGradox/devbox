import AppKit
import DevBoxCore
import Foundation
import Observation

/// One account per app session. Account changes invalidate in-flight work before
/// any late response can save credentials or reveal a previous account's PRs.
@MainActor @Observable
final class GitHubSession {
    private(set) var user: GitHubUser?
    private(set) var authorization: GitHubDeviceAuthorization?
    private(set) var isSigningIn = false
    private(set) var isRestoring = false
    private(set) var errorMessage: String?
    private(set) var accountGeneration = UUID()
    let pullRequests: GitHubPullRequestCache

    @ObservationIgnored private var token: GitHubToken?
    @ObservationIgnored private var pendingToken: GitHubToken?
    @ObservationIgnored private var operationGeneration = UUID()
    @ObservationIgnored private var signInTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<String, Error>?
    @ObservationIgnored private var didAttemptRestore = false
    private let credentials: any GitHubCredentialsPersisting
    private let startAuthorization: @Sendable () async throws -> GitHubDeviceAuthorization
    private let poll: @Sendable (GitHubDeviceAuthorization) async throws -> GitHubToken
    private let refreshToken: @Sendable (GitHubToken) async throws -> GitHubToken
    private let loadUser: @Sendable (String) async throws -> GitHubUser
    private let openBrowser: @MainActor (URL) -> Void
    private let now: @Sendable () -> Date

    init(
        credentials: any GitHubCredentialsPersisting = GitHubKeychainCredentials(),
        pullRequests: GitHubPullRequestCache = GitHubPullRequestCache(),
        startAuthorization: @escaping @Sendable () async throws -> GitHubDeviceAuthorization = {
            try await GitHubAuthenticationClient().startDeviceAuthorization()
        },
        poll: @escaping @Sendable (GitHubDeviceAuthorization) async throws -> GitHubToken = {
            try await GitHubAuthenticationClient().pollForToken($0)
        },
        refreshToken: @escaping @Sendable (GitHubToken) async throws -> GitHubToken = {
            try await GitHubAuthenticationClient().refreshToken($0)
        },
        loadUser: @escaping @Sendable (String) async throws -> GitHubUser = {
            try await GitHubAuthenticationClient().user(accessToken: $0)
        },
        openBrowser: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.credentials = credentials
        self.pullRequests = pullRequests
        self.startAuthorization = startAuthorization
        self.poll = poll
        self.refreshToken = refreshToken
        self.loadUser = loadUser
        self.openBrowser = openBrowser
        self.now = now
    }

    func restoreIfNeeded() async {
        guard !didAttemptRestore else { return }
        didAttemptRestore = true
        await restore()
    }

    func restore() async {
        guard !isRestoring, !isSigningIn, user == nil else { return }
        let generation = operationGeneration
        isRestoring = true
        errorMessage = nil
        defer { if generation == operationGeneration { isRestoring = false } }
        do {
            token = try credentials.load()
            guard token != nil else { return }
            let identity = try await authorized { [loadUser] in try await loadUser($0) }
            try checkOperation(generation)
            user = identity
            accountGeneration = UUID()
        } catch is CancellationError {
            // Closing or replacing a session must not resurrect it.
        } catch {
            guard generation == operationGeneration else { return }
            errorMessage = Self.message(for: error)
        }
    }

    func beginSignIn() {
        guard !isSigningIn, !isRestoring, user == nil else { return }
        cancelSignIn()
        operationGeneration = UUID()
        let generation = operationGeneration
        isSigningIn = true
        errorMessage = nil
        signInTask = Task {
            defer {
                if generation == operationGeneration {
                    isSigningIn = false
                    authorization = nil
                    signInTask = nil
                }
            }
            do {
                let code = try await startAuthorization()
                try checkOperation(generation)
                authorization = code
                openBrowser(code.verificationURL)
                let newToken = try await poll(code)
                try checkOperation(generation)
                let identity = try await loadUser(newToken.accessToken)
                try checkOperation(generation)
                try credentials.save(newToken)
                token = newToken
                pendingToken = nil
                user = identity
                pullRequests.clear()
                accountGeneration = UUID()
            } catch is CancellationError {
                // The user can close the sheet or cancel while GitHub is polling.
            } catch {
                guard generation == operationGeneration else { return }
                errorMessage = Self.message(for: error)
            }
        }
    }

    func cancelSignIn() {
        guard isSigningIn || signInTask != nil else { return }
        signInTask?.cancel()
        signInTask = nil
        authorization = nil
        isSigningIn = false
        operationGeneration = UUID()
    }

    func signOut() {
        // If Keychain refuses removal, keep the account visible so the user can
        // retry rather than silently signing back in on the next launch.
        do {
            try credentials.remove()
            clearAccount()
            errorMessage = nil
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    /// Refresh proactively, coalesce concurrent refreshes, and retry a rejected
    /// access token once. A transient network failure never deletes credentials.
    func authorized<Value: Sendable>(
        _ operation: @escaping @Sendable (String) async throws -> Value
    ) async throws -> Value {
        let generation = operationGeneration
        do {
            let accessToken = try await currentAccessToken()
            try checkOperation(generation)
            do {
                let value = try await operation(accessToken)
                try checkOperation(generation)
                return value
            } catch {
                guard Self.isUnauthorized(error) else { throw error }
                let replacement = try await currentAccessToken(rejected: accessToken)
                try checkOperation(generation)
                let value = try await operation(replacement)
                try checkOperation(generation)
                return value
            }
        } catch {
            guard generation == operationGeneration else { throw CancellationError() }
            if Self.isUnauthorized(error) {
                clearAccount()
                do {
                    try credentials.remove()
                    errorMessage = "GitHub authorization expired or was revoked. Sign in again."
                } catch {
                    errorMessage = Self.message(for: error)
                }
            }
            throw error
        }
    }

    private func currentAccessToken(rejected: String? = nil) async throws -> String {
        guard let token = pendingToken ?? token else { throw GitHubAPIError.unauthorized }
        let needsRefresh = token.expiresAt.map { $0 <= now().addingTimeInterval(60) } ?? false
        let shouldRefresh = needsRefresh || token.accessToken == rejected
        if !shouldRefresh, pendingToken == nil { return token.accessToken }
        if let refreshTask { return try await refreshTask.value }
        if shouldRefresh && (token.refreshToken == nil ||
                             token.refreshTokenExpiresAt.map({ $0 <= now() }) == true) {
            throw GitHubAPIError.unauthorized
        }
        let generation = operationGeneration
        let task = Task {
            let renewed: GitHubToken
            if shouldRefresh {
                renewed = try await refreshToken(token)
            } else {
                renewed = token
            }
            try checkOperation(generation)
            // Refresh rotates and invalidates the old pair. Retain the new pair
            // even if Keychain or the subsequent identity check is temporarily
            // unavailable; never retry using an already-consumed refresh token.
            pendingToken = renewed
            try credentials.save(renewed)
            let identity = try await loadUser(renewed.accessToken)
            try checkOperation(generation)
            guard user.map({ $0.id == identity.id }) ?? true else {
                throw GitHubAPIError.unauthorized
            }
            self.token = renewed
            pendingToken = nil
            if user != nil { user = identity }
            return renewed.accessToken
        }
        refreshTask = task
        defer { if generation == operationGeneration { refreshTask = nil } }
        return try await task.value
    }

    private func clearAccount() {
        cancelSignIn()
        operationGeneration = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        token = nil
        pendingToken = nil
        user = nil
        isRestoring = false
        pullRequests.clear()
        accountGeneration = UUID()
    }

    private func checkOperation(_ generation: UUID) throws {
        try Task.checkCancellation()
        guard generation == operationGeneration else { throw CancellationError() }
    }

    private static func isUnauthorized(_ error: Error) -> Bool {
        (error as? GitHubAPIError) == .unauthorized ||
            (error as? GitHubPullRequestError) == .unauthorized
    }

    static func message(for error: Error) -> String {
        // Known errors contain only our own descriptions, never an OAuth response,
        // credential, arbitrary server body, or failing request's diagnostic dump.
        if let error = error as? GitHubAPIError { return error.localizedDescription }
        if let error = error as? GitHubPullRequestError { return error.localizedDescription }
        if let error = error as? GitHubCredentialError { return error.localizedDescription }
        return "Could not contact GitHub. Check your connection and try again."
    }
}
