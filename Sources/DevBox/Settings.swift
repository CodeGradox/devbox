import DevBoxCore
import Foundation
import Security

struct SavedConnection: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var settings: ConnectionSettings
}

struct AppSettings: Codable {
    var projects: [ProjectRecord] = []
    var connections: [SavedConnection] = []
    var preferredEditor: EditorApplication?
}

@MainActor
protocol SettingsPersisting {
    func load() throws -> AppSettings
    func save(_ settings: AppSettings) throws
}

@MainActor
protocol CredentialsPersisting {
    func password(for id: UUID) async throws -> String?
    func save(password: String, for id: UUID) async throws
    func remove(for id: UUID) async throws
}

final class KeychainCredentials: CredentialsPersisting {
    private let backend: any PasswordCredentialBackend
    private var reads: [UUID: Task<String?, Error>] = [:]

    init(backend: any PasswordCredentialBackend = CredentialStore()) {
        self.backend = backend
    }

    func password(for id: UUID) async throws -> String? {
        if let read = reads[id] { return try await read.value }
        let backend = backend
        let read = Task { try await KeychainExecutor.shared.run { try backend.password(for: id) } }
        reads[id] = read
        defer { reads[id] = nil }
        return try await read.value
    }

    func save(password: String, for id: UUID) async throws {
        let backend = backend
        try await KeychainExecutor.shared.run { try backend.save(password: password, for: id) }
    }

    func remove(for id: UUID) async throws {
        let backend = backend
        try await KeychainExecutor.shared.run { try backend.remove(for: id) }
    }
}

/// Synchronous implementations are invoked only on the dedicated Keychain queue.
protocol PasswordCredentialBackend: Sendable {
    func password(for id: UUID) throws -> String?
    func save(password: String, for id: UUID) throws
    func remove(for id: UUID) throws
}

/// Security may block on user authorization. Never occupy the main thread or a
/// cooperative Swift worker while waiting, and never share the disk/Git queue.
final class KeychainExecutor: Sendable {
    static let shared = KeychainExecutor()
    private let queue = DispatchQueue(label: "app.devbox.keychain", qos: .userInitiated)

    func run<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try operation() })
            }
        }
    }
}

struct SettingsStore: SettingsPersisting {
    private var url: URL {
        get throws {
            let directory = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("DevBox", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory.appendingPathComponent("settings.json")
        }
    }

    func load() throws -> AppSettings {
        let location = try url
        guard FileManager.default.fileExists(atPath: location.path) else { return AppSettings() }
        return try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: location))
    }

    func save(_ settings: AppSettings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: try url, options: .atomic)
    }
}

struct CredentialStore: PasswordCredentialBackend {
    private static let service = "app.devbox.mariadb"

    private static func query(_ id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString
        ]
    }

    func password(for id: UUID) throws -> String? {
        var query = Self.query(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let data = result as? Data, let password = String(data: data, encoding: .utf8) else {
            throw KeychainError(status: errSecDecode)
        }
        return password
    }

    func save(password: String, for id: UUID) throws {
        let data = Data(password.utf8)
        let query = Self.query(id)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let status = SecItemAdd(item as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainError(status: status) }
        } else if update != errSecSuccess {
            throw KeychainError(status: update)
        }
    }

    func remove(for id: UUID) throws {
        let status = SecItemDelete(Self.query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private struct KeychainError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            let reason = SecCopyErrorMessageString(status, nil) as String? ?? "Error \(status)"
            return "Keychain: \(reason)"
        }
    }
}
