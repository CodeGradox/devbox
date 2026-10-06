import Foundation
import Synchronization
import Testing
@testable import DevBoxCore

private final class AuthenticationFixture: Sendable {
    enum Reply: Sendable {
        case json(String, status: Int = 200, headers: [String: String] = [:])
        case failure(URLError.Code)
    }

    struct State {
        var date = Date(timeIntervalSince1970: 1_000)
        var replies: [Reply]
        var requests: [URLRequest] = []
        var sleeps: [TimeInterval] = []
    }

    let state: Mutex<State>

    init(_ replies: [Reply]) {
        state = Mutex(State(replies: replies))
    }

    var client: GitHubAuthenticationClient {
        GitHubAuthenticationClient(
            transport: { [self] request in
                let reply = state.withLock { state in
                    state.requests.append(request)
                    return state.replies.isEmpty ? Reply.failure(.badServerResponse) : state.replies.removeFirst()
                }
                switch reply {
                case .json(let json, let status, let headers):
                    return (Data(json.utf8), HTTPURLResponse(
                        url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers
                    )!)
                case .failure(let code): throw URLError(code)
                }
            },
            now: { [self] in state.withLock { $0.date } },
            sleep: { [self] interval in
                try Task.checkCancellation()
                state.withLock {
                    $0.sleeps.append(interval)
                    $0.date.addTimeInterval(interval)
                }
            }
        )
    }

    func authorization(expiresIn: TimeInterval = 100) -> GitHubDeviceAuthorization {
        GitHubDeviceAuthorization(
            deviceCode: "test +&=/é", userCode: "TEST-CODE",
            verificationURL: URL(string: "https://github.com/login/device")!,
            expiresAt: state.withLock { $0.date.addingTimeInterval(expiresIn) }, interval: 5
        )
    }
}

@Suite struct GitHubAuthenticationClientTests {
    @Test func startsDeviceAuthorizationWithoutScopesOrSecret() async throws {
        let fixture = AuthenticationFixture([.json("""
            {"device_code":"fixture-device","user_code":"TEST-CODE",
             "verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}
            """)])
        let authorization = try await fixture.client.startDeviceAuthorization()
        #expect(authorization.verificationURL.absoluteString == "https://github.com/login/device")
        #expect(authorization.expiresAt == Date(timeIntervalSince1970: 1_900))
        #expect(authorization.interval == 5)
        let request = try #require(fixture.state.withLock { $0.requests.first })
        #expect(request.url?.absoluteString == "https://github.com/login/device/code")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "DevBox")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(request.httpShouldHandleCookies == false)
        let bodyIsCorrect = request.httpBody == Data("client_id=\(GitHubAuthenticationClient.clientID)".utf8)
        #expect(bodyIsCorrect)
    }

    @Test(arguments: [200, 400])
    func disabledDeviceFlowExplainsRegistrationSetting(_ status: Int) async {
        let fixture = AuthenticationFixture([.json(
            #"{"error":"device_flow_disabled","error_description":"untrusted server text"}"#,
            status: status
        )])
        await #expect(throws: GitHubAPIError.message("Device sign-in is not enabled for this GitHub App.")) {
            try await fixture.client.startDeviceAuthorization()
        }
    }

    @Test(arguments: [
        "https://github.com.evil.invalid/login/device",
        "http://github.com/login/device",
        "https://github.com/login/device?redirect=elsewhere",
        "https://github.com/login/device/"
    ])
    func rejectsUntrustedVerificationURL(_ url: String) async {
        let fixture = AuthenticationFixture([.json("""
            {"device_code":"fixture","user_code":"TEST","verification_uri":"\(url)","expires_in":900,"interval":5}
            """)])
        await #expect(throws: GitHubAPIError.invalidResponse) {
            try await fixture.client.startDeviceAuthorization()
        }
    }

    @Test func pendingAndSlowDownPersistIncreasedIntervalAndEncodeForm() async throws {
        let fixture = AuthenticationFixture([
            .json(#"{"error":"authorization_pending"}"#),
            .json(#"{"error":"slow_down"}"#),
            .json(#"{"error":"authorization_pending"}"#),
            .json(#"{"access_token":"fixture-access","refresh_token":"fixture-refresh","expires_in":60,"refresh_token_expires_in":600}"#)
        ])
        let token = try await fixture.client.pollForToken(fixture.authorization())
        #expect(fixture.state.withLock { $0.sleeps } == [5, 5, 10, 10])
        #expect(token.expiresAt == Date(timeIntervalSince1970: 1_090))
        #expect(token.refreshTokenExpiresAt == Date(timeIntervalSince1970: 1_630))
        let requests = fixture.state.withLock { $0.requests }
        #expect(requests.count == 4)
        let bodyIsCorrect = requests.allSatisfy {
            $0.httpBody == Data(("client_id=\(GitHubAuthenticationClient.clientID)"
                + "&device_code=test%20%2B%26%3D%2F%C3%A9"
                + "&grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code").utf8)
        }
        #expect(bodyIsCorrect)
        let encoded = try JSONEncoder().encode(token)
        let roundTrips = try JSONDecoder().decode(GitHubToken.self, from: encoded) == token
        #expect(roundTrips)
    }

    @Test(arguments: [
        ("access_denied", GitHubAPIError.authorizationDenied),
        ("expired_token", GitHubAPIError.authorizationExpired),
        ("unexpected-server-content", GitHubAPIError.invalidResponse)
    ])
    func stopsOnOAuthError(_ code: String, _ expected: GitHubAPIError) async {
        let fixture = AuthenticationFixture([.json("{\"error\":\"\(code)\"}", status: 400)])
        await #expect(throws: expected) {
            try await fixture.client.pollForToken(fixture.authorization())
        }
        #expect(fixture.state.withLock { $0.requests.count } == 1)
    }

    @Test func pollingExpiresWithoutSendingAnotherRequest() async {
        let fixture = AuthenticationFixture([.json(#"{"error":"authorization_pending"}"#)])
        await #expect(throws: GitHubAPIError.authorizationExpired) {
            try await fixture.client.pollForToken(fixture.authorization(expiresIn: 8))
        }
        #expect(fixture.state.withLock { $0.sleeps } == [5, 3])
        #expect(fixture.state.withLock { $0.requests.count } == 1)
        await #expect(throws: GitHubAPIError.authorizationExpired) {
            try await fixture.client.pollForToken(fixture.authorization(expiresIn: 0))
        }
        #expect(fixture.state.withLock { $0.requests.count } == 1)
    }

    @Test func timeoutsBackOffAndEventuallyExpire() async {
        let fixture = AuthenticationFixture([.failure(.timedOut), .failure(.timedOut)])
        await #expect(throws: GitHubAPIError.authorizationExpired) {
            try await fixture.client.pollForToken(fixture.authorization(expiresIn: 25))
        }
        #expect(fixture.state.withLock { $0.sleeps } == [5, 10, 10])
        #expect(fixture.state.withLock { $0.requests.count } == 2)
    }

    @Test func cancellationInterruptsSleepWithoutSendingCredentials() async {
        let fixture = AuthenticationFixture([])
        let client = GitHubAuthenticationClient(
            transport: { _ in
                Issue.record("Transport must not run after cancellation")
                throw URLError(.badServerResponse)
            },
            now: { Date(timeIntervalSince1970: 1_000) },
            sleep: { _ in throw CancellationError() }
        )
        await #expect(throws: CancellationError.self) {
            try await client.pollForToken(fixture.authorization())
        }
    }

    @Test func cancelledTransportRemainsCancellation() async {
        let fixture = AuthenticationFixture([.failure(.cancelled)])
        await #expect(throws: CancellationError.self) {
            try await fixture.client.pollForToken(fixture.authorization())
        }
    }

    @Test func alreadyCancelledTaskDoesNotPoll() async {
        let fixture = AuthenticationFixture([])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fixture.client.pollForToken(fixture.authorization())
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(fixture.state.withLock { $0.requests.isEmpty && $0.sleeps.isEmpty })
    }

    @Test func refreshUsesNoSecretAndRotatesTokens() async throws {
        let fixture = AuthenticationFixture([.json("""
            {"access_token":"new-fixture","refresh_token":"rotated-fixture","expires_in":300,"refresh_token_expires_in":900}
            """)])
        let token = try await fixture.client.refreshToken(GitHubToken(accessToken: "old-fixture", refreshToken: "refresh +&="))
        let request = try #require(fixture.state.withLock { $0.requests.first })
        let bodyIsCorrect = request.httpBody == Data(("client_id=\(GitHubAuthenticationClient.clientID)"
            + "&grant_type=refresh_token&refresh_token=refresh%20%2B%26%3D").utf8)
        #expect(bodyIsCorrect)
        #expect(request.url?.absoluteString == "https://github.com/login/oauth/access_token")
        let rotated = token.accessToken == "new-fixture" && token.refreshToken == "rotated-fixture"
        #expect(rotated)
        #expect(token.expiresAt == Date(timeIntervalSince1970: 1_300))
        #expect(token.refreshTokenExpiresAt == Date(timeIntervalSince1970: 1_900))
    }

    @Test func expiredRefreshTokenDoesNotSendRequest() async {
        let fixture = AuthenticationFixture([])
        await #expect(throws: GitHubAPIError.unauthorized) {
            try await fixture.client.refreshToken(GitHubToken(
                accessToken: "fixture", refreshToken: "fixture",
                refreshTokenExpiresAt: Date(timeIntervalSince1970: 999)
            ))
        }
        #expect(fixture.state.withLock { $0.requests.isEmpty })
    }

    @Test(arguments: [
        "bad_refresh_token", "invalid_grant", "incorrect_client_credentials",
        "expired_token", "invalid_token", "revoked_token", "access_denied"
    ])
    func invalidRefreshCredentialsRequireSignIn(_ code: String) async {
        let fixture = AuthenticationFixture([.json("{\"error\":\"\(code)\"}", status: 400)])
        await #expect(throws: GitHubAPIError.unauthorized) {
            try await fixture.client.refreshToken(GitHubToken(accessToken: "fixture", refreshToken: "fixture"))
        }
    }

    @Test func retryableRefreshErrorsDoNotInvalidateCredentials() async {
        let fixture = AuthenticationFixture([.failure(.timedOut), .json("ignored", status: 503)])
        await #expect(throws: GitHubAPIError.timedOut) {
            try await fixture.client.refreshToken(GitHubToken(accessToken: "fixture", refreshToken: "fixture"))
        }
        await #expect(throws: GitHubAPIError.invalidResponse) {
            try await fixture.client.refreshToken(GitHubToken(accessToken: "fixture", refreshToken: "fixture"))
        }
    }

    @Test func userUsesFixedRESTHostAndBearerHeader() async throws {
        let fixture = AuthenticationFixture([.json(#"{"login":"octocat","id":1}"#)])
        let user = try await fixture.client.user(accessToken: "fixture-access")
        #expect(user == GitHubUser(login: "octocat", id: 1))
        let request = try #require(fixture.state.withLock { $0.requests.first })
        #expect(request.url?.absoluteString == "https://api.github.com/user")
        let headerIsCorrect = request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-access"
        #expect(headerIsCorrect)
    }

    @Test(arguments: [
        (401, GitHubAPIError.unauthorized), (403, .forbidden),
        (404, .notFound), (429, .rateLimited), (500, .invalidResponse),
        (302, .invalidResponse)
    ])
    func httpErrorsNeverIncludeResponseBody(_ status: Int, _ expected: GitHubAPIError) async {
        let fixture = AuthenticationFixture([.json("sensitive-fixture-response", status: status)])
        await #expect(throws: expected) {
            try await fixture.client.user(accessToken: "fixture-access")
        }
        let sanitized = !expected.localizedDescription.contains("sensitive-fixture")
        #expect(sanitized)
    }

    @Test(arguments: [
        ["X-RateLimit-Remaining": "0"], ["Retry-After": "60"]
    ])
    func recognizesRateLimitedForbiddenResponses(_ headers: [String: String]) async {
        let fixture = AuthenticationFixture([.json("ignored", status: 403, headers: headers)])
        await #expect(throws: GitHubAPIError.rateLimited) {
            try await fixture.client.user(accessToken: "fixture")
        }
    }

    @Test(arguments: ["not-json", "{}", #"{"access_token":42}"#, #"{"access_token":""}"#])
    func malformedTokenResponsesAreSanitized(_ json: String) async {
        let fixture = AuthenticationFixture([.json(json)])
        await #expect(throws: GitHubAPIError.invalidResponse) {
            try await fixture.client.pollForToken(fixture.authorization())
        }
    }

    @Test func transportErrorsAreSanitized() async {
        let client = GitHubAuthenticationClient(transport: { _ in
            throw NSError(domain: "sensitive-fixture", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "sensitive-fixture"
            ])
        })
        await #expect(throws: GitHubAPIError.transportFailed) {
            try await client.user(accessToken: "fixture")
        }
    }

    @Test func rejectsUnexpectedResponseURL() async {
        let client = GitHubAuthenticationClient(transport: { _ in
            (Data(#"{"login":"octocat","id":1}"#.utf8), HTTPURLResponse(
                url: URL(string: "https://untrusted.invalid/user")!,
                statusCode: 200, httpVersion: nil, headerFields: nil
            )!)
        })
        await #expect(throws: GitHubAPIError.invalidResponse) {
            try await client.user(accessToken: "fixture")
        }
    }
}
