import Foundation
import XCTest
@testable import DevBoxCore

@MainActor
final class DatabaseIntegrationTests: XCTestCase {
    /// Run with scripts/test-mariadb.sh, never against a user's regular server.
    func testIsolatedMariaDBFlow() async throws {
        guard let socket = ProcessInfo.processInfo.environment["DEVBOX_TEST_MARIADB_SOCKET"] else {
            throw XCTSkip("Opt in with scripts/test-mariadb.sh")
        }
        let directory = URL(fileURLWithPath: socket).deletingLastPathComponent()
        let build = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build")
        guard socket.hasPrefix("/"), socket.utf8.count < 104,
              directory.deletingLastPathComponent().standardizedFileURL == build.standardizedFileURL,
              directory.lastPathComponent.hasPrefix("db."),
              FileManager.default.fileExists(atPath: directory.appendingPathComponent("devbox-isolated-test").path)
        else {
            XCTFail("Refusing anything except an explicitly marked isolated socket under this repository's .build")
            return
        }

        let settings = ConnectionSettings(socketPath: socket)
        let service = DatabaseService()
        try await service.testConnection(settings: settings, password: "")
        let before = try await service.databases(settings: settings, password: "")
        XCTAssertEqual(before.map(\.name), before.map(\.name).sorted())
        for name in ["devbox_integration_plain", "devbox_integration_`資料"] {
            XCTAssertTrue(before.contains(.init(name: name)), "Missing fixture \(name)")
            try await service.dropDatabase(.init(name: name), settings: settings, password: "")
        }
        for name in ["mysql", "information_schema", "performance_schema", "sys", "MYSQL"] {
            do {
                try await service.dropDatabase(.init(name: name), settings: settings, password: "")
                XCTFail("System database was not protected: \(name)")
            } catch DatabaseServiceError.protectedDatabase {
                // Expected, before any destructive SQL is submitted.
            }
        }
        let after = try await service.databases(settings: settings, password: "")
        XCTAssertFalse(after.contains { $0.name.hasPrefix("devbox_integration_") })
        XCTAssertEqual(before.filter(\.isSystem), after.filter(\.isSystem))
        XCTAssertTrue(after.contains(.init(name: "mysql")))
    }
}
