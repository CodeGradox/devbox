import XCTest
@testable import DevBoxCore

@MainActor
final class DatabaseServiceTests: XCTestCase {
    func testSettingsDefaultsAndRoundTrip() throws {
        let settings = ConnectionSettings()
        XCTAssertEqual(settings.host, "127.0.0.1")
        XCTAssertEqual(settings.port, 3306)
        XCTAssertEqual(settings.username, "root")
        XCTAssertEqual(settings.socketPath, "")
        XCTAssertEqual(try JSONDecoder().decode(ConnectionSettings.self, from: JSONEncoder().encode(settings)), settings)
    }

    func testOnlyExplicitLoopbackHostsAreAccepted() throws {
        for host in ["127.0.0.1", "localhost", "::1"] {
            try DatabaseService.validate(settings: .init(host: host), password: "")
        }
        for host in ["", "example.com", "192.168.1.2", "127.1", "localhost.", " localhost", "localhost\0evil"] {
            XCTAssertThrowsError(try DatabaseService.validate(settings: .init(host: host), password: ""))
            XCTAssertThrowsError(try DatabaseService.validate(settings: .init(host: host, socketPath: "/tmp/mysql.sock"), password: ""))
        }
    }

    func testPortAndSocketValidation() throws {
        for port in [Int.min, -1, 0, 65536, Int.max] {
            XCTAssertThrowsError(try DatabaseService.validate(settings: .init(port: port), password: ""))
        }
        for port in [1, 3306, 65535] {
            try DatabaseService.validate(settings: .init(port: port), password: "")
        }
        try DatabaseService.validate(settings: .init(socketPath: "/tmp/mysql.sock"), password: "")
        for path in ["mysql.sock", "~/mysql.sock", "/tmp/mysql\0.sock"] {
            XCTAssertThrowsError(try DatabaseService.validate(settings: .init(socketPath: path), password: ""))
        }
        XCTAssertThrowsError(try DatabaseService.validate(settings: .init(username: ""), password: ""))
        XCTAssertThrowsError(try DatabaseService.validate(settings: .init(username: "root\0other"), password: ""))
        XCTAssertThrowsError(try DatabaseService.validate(settings: .init(), password: "secret\0suffix"))
    }

    func testIdentifierQuoting() throws {
        XCTAssertEqual(try DatabaseService.quotedIdentifier("example"), "`example`")
        XCTAssertEqual(try DatabaseService.quotedIdentifier("a`b"), "`a``b`")
        XCTAssertEqual(try DatabaseService.quotedIdentifier("資料庫"), "`資料庫`")
        XCTAssertEqual(try DatabaseService.quotedIdentifier("x`; DROP DATABASE mysql; --"), "`x``; DROP DATABASE mysql; --`")
        XCTAssertThrowsError(try DatabaseService.quotedIdentifier(""))
        XCTAssertThrowsError(try DatabaseService.quotedIdentifier("a\0b"))
    }

    func testSystemProtectionAndIdentity() throws {
        for name in ["mysql", "MYSQL", "information_schema", "Information_Schema", "performance_schema", "sys", "SYS"] {
            let database = DatabaseRecord(name: name)
            XCTAssertEqual(database.id, name)
            XCTAssertTrue(database.isSystem)
            XCTAssertThrowsError(try DatabaseService.dropStatement(database)) { error in
                guard case DatabaseServiceError.protectedDatabase = error else {
                    return XCTFail("Expected protected database error, got \(error)")
                }
            }
        }
        XCTAssertFalse(DatabaseRecord(name: "my_app").isSystem)
        XCTAssertEqual(try DatabaseService.dropStatement(.init(name: "my`app")), "DROP DATABASE `my``app`")
    }

    func testMissingLibraryGivesActionableErrorWithoutConnecting() {
        XCTAssertThrowsError(try MariaDBConnector(paths: ["/nonexistent/devbox-test/libmariadb.dylib"])) { error in
            guard case DatabaseServiceError.connectorUnavailable = error else {
                return XCTFail("Expected missing connector error, got \(error)")
            }
            XCTAssertTrue(error.localizedDescription.contains("brew install mariadb-connector-c"))
        }
    }

    func testBundledServerConnectorFallbacks() {
        for prefix in ["/opt/homebrew", "/usr/local"] {
            XCTAssertTrue(MariaDBConnector.libraryPaths.contains("\(prefix)/opt/mariadb/lib/libmariadb.dylib"))
        }
    }

    func testLibraryWithoutConnectorSymbolsFailsGracefully() {
        XCTAssertThrowsError(try MariaDBConnector(paths: ["/usr/lib/libSystem.B.dylib"])) { error in
            guard case DatabaseServiceError.connectorIncompatible = error else {
                return XCTFail("Expected incompatible connector error, got \(error)")
            }
        }
    }

    func testSubmittedDropTransportLossIsUncertainAndNeverRetried() {
        for code: UInt32 in [2006, 2013, 2055] {
            var calls = 0
            XCTAssertThrowsError(try DatabaseService.performSubmittedDrop {
                calls += 1
                throw DatabaseServiceError.databaseOperation(operation: "Database query", code: code)
            }) { error in
                guard case DatabaseServiceError.deletionOutcomeUnknown(let actual) = error else {
                    return XCTFail("Expected uncertain deletion, got \(error)")
                }
                XCTAssertEqual(actual, code)
                XCTAssertTrue(error.localizedDescription.contains(String(code)))
                XCTAssertTrue(error.localizedDescription.contains("may still be running"))
                XCTAssertTrue(error.localizedDescription.contains("No automatic retry"))
            }
            XCTAssertEqual(calls, 1)
        }
    }

    func testOtherDropErrorsRetainTheirClassification() {
        for code: UInt32 in [1044, 1142, 1205, 2002, 2003] {
            XCTAssertThrowsError(try DatabaseService.performSubmittedDrop {
                throw DatabaseServiceError.databaseOperation(operation: "Database query", code: code)
            }) { error in
                guard case DatabaseServiceError.databaseOperation(let operation, let actual) = error else {
                    return XCTFail("Expected original error, got \(error)")
                }
                XCTAssertEqual(operation, "Database query")
                XCTAssertEqual(actual, code)
            }
        }
        XCTAssertThrowsError(try DatabaseService.performSubmittedDrop { throw CancellationError() }) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    func testSubmittedDropSuccessExecutesOnce() throws {
        var calls = 0
        try DatabaseService.performSubmittedDrop { calls += 1 }
        XCTAssertEqual(calls, 1)
    }

    func testPublicAPIRejectsUnsafeOperationsBeforeLoadingOrConnecting() async {
        let service = DatabaseService()
        do {
            try await service.testConnection(settings: .init(host: "remote.example"), password: "unused")
            XCTFail("Remote host accepted")
        } catch {
            guard case DatabaseServiceError.invalidSettings = error else {
                return XCTFail("Expected validation error, got \(error)")
            }
        }
        do {
            _ = try await service.databases(settings: .init(port: 0), password: "unused")
            XCTFail("Invalid port accepted")
        } catch {
            guard case DatabaseServiceError.invalidSettings = error else {
                return XCTFail("Expected validation error, got \(error)")
            }
        }
        do {
            try await service.dropDatabase(.init(name: "MYSQL"), settings: .init(), password: "unused")
            XCTFail("System database accepted")
        } catch {
            guard case DatabaseServiceError.protectedDatabase = error else {
                return XCTFail("Expected system protection error, got \(error)")
            }
        }
    }
}
