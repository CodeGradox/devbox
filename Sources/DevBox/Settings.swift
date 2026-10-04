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
    func password(for id: UUID) throws -> String?
    func save(password: String, for id: UUID) throws
    func remove(for id: UUID) throws
}

struct KeychainCredentials: CredentialsPersisting {
    func password(for id: UUID) throws -> String? { try CredentialStore.password(for: id) }
    func save(password: String, for id: UUID) throws { try CredentialStore.save(password: password, for: id) }
    func remove(for id: UUID) throws { try CredentialStore.remove(for: id) }
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

enum CredentialStore {
    private static let service = "app.devbox.mariadb"

    private static func query(_ id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString
        ]
    }

    static func password(for id: UUID) throws -> String? {
        var query = query(id)
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

    static func save(password: String, for id: UUID) throws {
        let data = Data(password.utf8)
        let query = query(id)
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

    static func remove(for id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
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
