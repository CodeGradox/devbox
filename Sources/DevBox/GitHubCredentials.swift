import DevBoxCore
import Foundation
import Security

@MainActor
protocol GitHubCredentialsPersisting {
    func load() async throws -> GitHubToken?
    func save(_ token: GitHubToken) async throws
    func remove() async throws
}

/// Separate from database credentials and settings.json. Neither token is synced
/// through iCloud or written to the repository, preferences, or logs.
final class GitHubKeychainCredentials: GitHubCredentialsPersisting {
    private let backend: any GitHubCredentialBackend
    private var read: Task<GitHubToken?, Error>?

    init(backend: any GitHubCredentialBackend = SecurityGitHubCredentialBackend()) {
        self.backend = backend
    }

    func load() async throws -> GitHubToken? {
        if let read { return try await read.value }
        let backend = backend
        let task = Task { try await KeychainExecutor.shared.run { try backend.load() } }
        read = task
        defer { read = nil }
        return try await task.value
    }

    func save(_ token: GitHubToken) async throws {
        let backend = backend
        try await KeychainExecutor.shared.run { try backend.save(token) }
    }

    func remove() async throws {
        let backend = backend
        try await KeychainExecutor.shared.run { try backend.remove() }
    }
}

protocol GitHubCredentialBackend: Sendable {
    func load() throws -> GitHubToken?
    func save(_ token: GitHubToken) throws
    func remove() throws
}

struct SecurityGitHubCredentialBackend: GitHubCredentialBackend {
    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "app.devbox.github",
            kSecAttrAccount as String: GitHubAuthenticationClient.clientID
        ]
    }

    func load() throws -> GitHubToken? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw GitHubCredentialError(operation: "read", status: status) }
        guard let data = result as? Data, let token = try? JSONDecoder().decode(GitHubToken.self, from: data) else {
            throw GitHubCredentialError(operation: "read", status: errSecDecode)
        }
        return token
    }

    func save(_ token: GitHubToken) throws {
        let data = try JSONEncoder().encode(token)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw GitHubCredentialError(operation: "save", status: added) }
        } else if status != errSecSuccess {
            throw GitHubCredentialError(operation: "save", status: status)
        }
    }

    func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GitHubCredentialError(operation: "remove", status: status)
        }
    }
}

struct GitHubCredentialError: LocalizedError {
    let operation: String
    let status: OSStatus

    var errorDescription: String? {
        "Could not \(operation) GitHub credentials in macOS Keychain (error \(status)). Unlock your keychain and try again."
    }
}
