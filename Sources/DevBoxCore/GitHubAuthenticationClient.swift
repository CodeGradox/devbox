import Foundation

public struct GitHubDeviceAuthorization: Sendable, Equatable {
    public let deviceCode: String
    public let userCode: String
    public let verificationURL: URL
    public let expiresAt: Date
    public let interval: TimeInterval

    public init(deviceCode: String, userCode: String, verificationURL: URL, expiresAt: Date, interval: TimeInterval) {
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationURL = verificationURL
        self.expiresAt = expiresAt
        self.interval = interval
    }
}

public struct GitHubToken: Sendable, Equatable, Codable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date?
    public let refreshTokenExpiresAt: Date?

    public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil, refreshTokenExpiresAt: Date? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.refreshTokenExpiresAt = refreshTokenExpiresAt
    }
}

public struct GitHubUser: Sendable, Equatable {
    public let login: String
    public let id: Int

    public init(login: String, id: Int) {
        self.login = login
        self.id = id
    }
}

/// Error descriptions deliberately exclude response bodies and underlying transport errors.
public enum GitHubAPIError: Error, Sendable, Equatable, LocalizedError {
    case unauthorized
    case forbidden
    case notFound
    case rateLimited
    case authorizationDenied
    case authorizationExpired
    case invalidResponse
    case timedOut
    case transportFailed
    /// Only supply trusted, locally authored text, never server responses or credentials.
    case message(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized: "GitHub authentication has expired or is invalid. Sign in again."
        case .forbidden: "GitHub denied access to this resource."
        case .notFound: "The GitHub resource was not found or is not accessible."
        case .rateLimited: "GitHub's rate limit was reached. Try again later."
        case .authorizationDenied: "GitHub sign-in was declined."
        case .authorizationExpired: "GitHub sign-in has expired. Start sign-in again."
        case .invalidResponse: "GitHub returned an unexpected response."
        case .timedOut: "The GitHub request timed out. Try again."
        case .transportFailed: "Could not connect to GitHub. Check your connection and try again."
        case .message(let message): message
        }
    }
}

public struct GitHubAuthenticationClient: Sendable {
    public static let clientID = "Iv23li8zeAI8rGzYMX69"
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    public typealias Clock = @Sendable () -> Date
    public typealias Sleep = @Sendable (TimeInterval) async throws -> Void

    private let transport: Transport
    private let now: Clock
    private let sleep: Sleep
    private static let verificationURL = URL(string: "https://github.com/login/device")!

    public init() {
        self.init(transport: { try await GitHubHTTPTransport.send($0) })
    }

    /// Injected transports must not follow redirects or persist credentials, cookies, or responses.
    public init(
        transport: @escaping Transport,
        now: @escaping Clock = { Date() },
        sleep: @escaping Sleep = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.transport = transport
        self.now = now
        self.sleep = sleep
    }

    public func startDeviceAuthorization() async throws -> GitHubDeviceAuthorization {
        let requestedAt = now()
        let data = try await send(formRequest(path: "device/code", fields: [
            ("client_id", Self.clientID)
        ]), allowOAuthError: true)
        if let error = (try? decode(data) as TokenResponse)?.error {
            throw oauthError(error)
        }
        let response: DeviceResponse = try decode(data)
        guard !response.device_code.isEmpty, !response.user_code.isEmpty,
              response.verification_uri == Self.verificationURL.absoluteString,
              response.expires_in.isFinite, response.expires_in > 0,
              response.interval.isFinite, response.interval > 0 else {
            throw GitHubAPIError.invalidResponse
        }
        return GitHubDeviceAuthorization(
            deviceCode: response.device_code, userCode: response.user_code,
            verificationURL: Self.verificationURL,
            expiresAt: requestedAt.addingTimeInterval(response.expires_in), interval: response.interval
        )
    }

    public func pollForToken(_ authorization: GitHubDeviceAuthorization) async throws -> GitHubToken {
        guard authorization.interval.isFinite, authorization.interval > 0,
              authorization.expiresAt.timeIntervalSince1970.isFinite,
              !authorization.deviceCode.isEmpty,
              authorization.verificationURL == Self.verificationURL else {
            throw GitHubAPIError.invalidResponse
        }
        var interval = authorization.interval
        while true {
            try Task.checkCancellation()
            let remaining = authorization.expiresAt.timeIntervalSince(now())
            guard remaining > 0 else { throw GitHubAPIError.authorizationExpired }
            try await sleep(min(interval, remaining))
            try Task.checkCancellation()
            guard now() < authorization.expiresAt else { throw GitHubAPIError.authorizationExpired }
            let requestedAt = now()
            let response: TokenResponse
            do {
                response = try decode(await send(formRequest(path: "oauth/access_token", fields: [
                    ("client_id", Self.clientID),
                    ("device_code", authorization.deviceCode),
                    ("grant_type", "urn:ietf:params:oauth:grant-type:device_code")
                ]), allowOAuthError: true))
            } catch GitHubAPIError.timedOut {
                // RFC 8628 recommends exponential backoff for connection timeouts.
                interval = min(interval * 2, max(0, authorization.expiresAt.timeIntervalSince(now())))
                continue
            }
            try Task.checkCancellation()
            guard now() < authorization.expiresAt else { throw GitHubAPIError.authorizationExpired }
            switch response.error {
            case "authorization_pending": continue
            case "slow_down":
                interval += 5
                continue
            case .some(let error): throw oauthError(error)
            case .none: return try token(from: response, issuedAt: requestedAt)
            }
        }
    }

    public func refreshToken(_ token: GitHubToken) async throws -> GitHubToken {
        try Task.checkCancellation()
        guard let refreshToken = token.refreshToken, !refreshToken.isEmpty,
              token.refreshTokenExpiresAt.map({ $0 > now() }) ?? true else {
            throw GitHubAPIError.unauthorized
        }
        let requestedAt = now()
        // Device-issued GitHub App tokens do not require a client secret to refresh.
        let response: TokenResponse = try decode(await send(formRequest(path: "oauth/access_token", fields: [
            ("client_id", Self.clientID), ("grant_type", "refresh_token"), ("refresh_token", refreshToken)
        ]), allowOAuthError: true))
        if let error = response.error {
            switch error {
            case "bad_refresh_token", "invalid_grant", "incorrect_client_credentials",
                 "expired_token", "invalid_token", "revoked_token", "access_denied":
                throw GitHubAPIError.unauthorized
            default:
                throw GitHubAPIError.invalidResponse
            }
        }
        let refreshed = try self.token(from: response, issuedAt: requestedAt)
        return GitHubToken(
            accessToken: refreshed.accessToken,
            refreshToken: refreshed.refreshToken ?? token.refreshToken,
            expiresAt: refreshed.expiresAt,
            refreshTokenExpiresAt: refreshed.refreshToken == nil
                ? token.refreshTokenExpiresAt : refreshed.refreshTokenExpiresAt
        )
    }

    public func user(accessToken: String) async throws -> GitHubUser {
        guard !accessToken.isEmpty, !accessToken.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw GitHubAPIError.unauthorized
        }
        var request = URLRequest(url: URL(string: "https://api.github.com/user")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let response: UserResponse = try decode(await send(request))
        guard !response.login.isEmpty, response.id > 0 else { throw GitHubAPIError.invalidResponse }
        return GitHubUser(login: response.login, id: response.id)
    }

    private func send(_ request: URLRequest, allowOAuthError: Bool = false) async throws -> Data {
        try Task.checkCancellation()
        var request = request
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("DevBox", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport(request)
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            if (error as? URLError)?.code == .timedOut { throw GitHubAPIError.timedOut }
            throw GitHubAPIError.transportFailed
        }
        try Task.checkCancellation()
        guard response.url == request.url else { throw GitHubAPIError.invalidResponse }
        switch response.statusCode {
        case 200..<300: return data
        case 400 where allowOAuthError:
            let response: TokenResponse = try decode(data)
            guard response.error != nil else { throw GitHubAPIError.invalidResponse }
            return data
        case 401: throw GitHubAPIError.unauthorized
        case 403:
            if response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0"
                || response.value(forHTTPHeaderField: "Retry-After") != nil {
                throw GitHubAPIError.rateLimited
            }
            throw GitHubAPIError.forbidden
        case 404: throw GitHubAPIError.notFound
        case 429: throw GitHubAPIError.rateLimited
        default: throw GitHubAPIError.invalidResponse
        }
    }

    private func formRequest(path: String, fields: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://github.com/login/\(path)")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(fields.map { "\(formEncode($0.0))=\(formEncode($0.1))" }.joined(separator: "&").utf8)
        return request
    }

    private func formEncode(_ value: String) -> String {
        value.utf8.map { byte in
            switch byte {
            case 65...90, 97...122, 48...57, 45, 46, 95, 126: String(UnicodeScalar(byte))
            default: String(format: "%%%02X", byte)
            }
        }.joined()
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw GitHubAPIError.invalidResponse }
    }

    private func token(from response: TokenResponse, issuedAt: Date) throws -> GitHubToken {
        guard let accessToken = response.access_token, !accessToken.isEmpty,
              response.refresh_token.map({ !$0.isEmpty }) ?? true,
              response.expires_in.map({ $0.isFinite && $0 > 0 }) ?? true,
              response.refresh_token_expires_in.map({ $0.isFinite && $0 > 0 }) ?? true else {
            throw GitHubAPIError.invalidResponse
        }
        return GitHubToken(
            accessToken: accessToken, refreshToken: response.refresh_token,
            expiresAt: response.expires_in.map { issuedAt.addingTimeInterval($0) },
            refreshTokenExpiresAt: response.refresh_token_expires_in.map { issuedAt.addingTimeInterval($0) }
        )
    }

    private func oauthError(_ code: String) -> GitHubAPIError {
        switch code {
        case "access_denied": .authorizationDenied
        case "expired_token": .authorizationExpired
        case "bad_refresh_token", "invalid_grant", "incorrect_client_credentials": .unauthorized
        case "device_flow_disabled": .message("Device sign-in is not enabled for this GitHub App.")
        default: .invalidResponse
        }
    }
}

private struct DeviceResponse: Decodable {
    let device_code: String
    let user_code: String
    let verification_uri: String
    let expires_in: TimeInterval
    let interval: TimeInterval
}

private struct TokenResponse: Decodable {
    let access_token: String?
    let refresh_token: String?
    let expires_in: TimeInterval?
    let refresh_token_expires_in: TimeInterval?
    let error: String?
}

private struct UserResponse: Decodable {
    let login: String
    let id: Int
}
