import Foundation
import Security
import Testing
@testable import DevBox

/// A file keychain of its own, so the test never reads or writes the user's login keychain.
/// File keychains are deprecated, but they are the only way to isolate the real Security calls.
@available(macOS, deprecated: 10.10, message: "Only an isolated test keychain uses this.")
private struct ThrowawayKeychain: @unchecked Sendable {
    let keychain: SecKeychain
    let path: String

    init() throws {
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = project.appendingPathComponent(".build/test-temp/keychain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.appendingPathComponent("test.keychain").path
        var created: SecKeychain?
        let status = SecKeychainCreate(path, 4, "test", false, nil, &created)
        guard status == errSecSuccess, let created else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        keychain = created
    }

    var store: CredentialStore {
        let keychain = self.keychain
        let box = UncheckedBox(keychain)
        return CredentialStore { query in
            query[kSecUseKeychain as String] = box.value
            query[kSecMatchSearchList as String] = [box.value]
        }
    }

    func delete() {
        SecKeychainDelete(keychain)
        try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path)
    }
}

private struct UncheckedBox: @unchecked Sendable {
    let value: SecKeychain
    init(_ value: SecKeychain) { self.value = value }
}

@available(macOS, deprecated: 10.10, message: "Only an isolated test keychain uses this.")
@Test func replacingAPasswordWithAnEmptyOneReallyClearsTheOldSecret() throws {
    let keychain = try ThrowawayKeychain()
    defer { keychain.delete() }
    let store = keychain.store
    let id = UUID()
    #expect(try store.password(for: id) == nil)

    try store.save(password: "synthetic-old", for: id)
    #expect(try store.password(for: id) == "synthetic-old")
    // SecItemUpdate would report success here and keep "synthetic-old".
    try store.save(password: "", for: id)
    #expect(try store.password(for: id) == "")
    try store.save(password: "synthetic-new", for: id)
    #expect(try store.password(for: id) == "synthetic-new")
    try store.save(password: "", for: id)
    #expect(try store.password(for: id) == "")
    try store.remove(for: id)
    #expect(try store.password(for: id) == nil)
}

@available(macOS, deprecated: 10.10, message: "Only an isolated test keychain uses this.")
@Test func savingAnEmptyPasswordForANewConnectionStillWorks() throws {
    let keychain = try ThrowawayKeychain()
    defer { keychain.delete() }
    let id = UUID()
    try keychain.store.save(password: "", for: id)
    #expect(try keychain.store.password(for: id) == "")
}
