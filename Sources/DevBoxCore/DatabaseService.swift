import Foundation
import Darwin

public struct ConnectionSettings: Codable, Hashable, Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public var socketPath: String

    public init(
        host: String = "127.0.0.1",
        port: Int = 3306,
        username: String = "root",
        socketPath: String = ""
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.socketPath = socketPath
    }
}

public struct DatabaseRecord: Identifiable, Hashable, Sendable {
    public let name: String
    public var id: String { name }
    public var isSystem: Bool {
        ["mysql", "information_schema", "performance_schema", "sys"].contains(name.lowercased())
    }

    public init(name: String) {
        self.name = name
    }
}

public enum DatabaseServiceError: LocalizedError, Sendable {
    case invalidSettings(String)
    case invalidIdentifier
    case protectedDatabase
    case connectorUnavailable
    case connectorIncompatible
    case clientInitialization
    case databaseOperation(operation: String, code: UInt32)
    case deletionOutcomeUnknown(code: UInt32)
    case invalidResult

    public var errorDescription: String? {
        switch self {
        case .invalidSettings(let reason):
            return reason
        case .invalidIdentifier:
            return "The database name must not be empty or contain a NUL character."
        case .protectedDatabase:
            return "System databases cannot be deleted."
        case .connectorUnavailable:
            return "MariaDB Connector/C could not be loaded. Run brew install mariadb-connector-c in Terminal, then restart DevBox."
        case .connectorIncompatible:
            return "MariaDB Connector/C could not be initialized. Run brew reinstall mariadb-connector-c in Terminal, then restart DevBox."
        case .clientInitialization:
            return "MariaDB could not allocate a connection."
        case .databaseOperation(let operation, let code):
            // Do not surface arbitrary server messages: they can echo credentials or SQL.
            let advice: String
            switch code {
            case 1045, 1698: advice = "Check the username, password, and account authentication method."
            case 1044, 1142, 1227: advice = "The account does not have permission for this operation."
            case 2002, 2003: advice = "Check that MariaDB is running and the local port or socket is correct."
            case 2006, 2013: advice = "The connection was lost or timed out. Refresh the database list before retrying a deletion."
            default: advice = "Check the local MariaDB server and account permissions."
            }
            return "\(operation) failed (MariaDB error \(code)). \(advice)"
        case .deletionOutcomeUnknown(let code):
            return "The connection was lost before MariaDB confirmed the deletion (error \(code)). The deletion may still be running or may have completed. No automatic retry was made. Check the server and refresh the database list before retrying."
        case .invalidResult:
            return "MariaDB returned an invalid database list."
        }
    }
}

/// Each operation uses a fresh connection. Blocking C calls run on a dedicated
/// serial queue, never on the main actor or Swift's cooperative executor.
public struct DatabaseService: Sendable {
    private static let queue = DispatchQueue(label: "DevBox.MariaDB", qos: .utility)

    public init() {}

    public func testConnection(settings: ConnectionSettings, password: String) async throws {
        try Self.validate(settings: settings, password: password)
        try await Self.perform { cancellation in
            try Self.withConnection(settings: settings, password: password, cancellation: cancellation) { _, _ in }
        }
    }

    public func databases(settings: ConnectionSettings, password: String) async throws -> [DatabaseRecord] {
        try Self.validate(settings: settings, password: password)
        return try await Self.perform { cancellation in
            try Self.withConnection(settings: settings, password: password, cancellation: cancellation) { api, connection in
                try cancellation.check()
                try api.execute("SHOW DATABASES", connection: connection)
                guard let result = api.storeResult(connection) else {
                    throw api.error("Listing databases", connection)
                }
                defer { api.freeResult(result) }
                var databases: [DatabaseRecord] = []
                while let row = api.fetchRow(result) {
                    guard let bytes = row[0], let lengths = api.fetchLengths(result),
                          let count = Int(exactly: lengths[0]) else {
                        throw DatabaseServiceError.invalidResult
                    }
                    let data = Data(bytes: bytes, count: count)
                    guard let name = String(data: data, encoding: .utf8) else {
                        throw DatabaseServiceError.invalidResult
                    }
                    databases.append(DatabaseRecord(name: name))
                }
                guard api.errorNumber(connection) == 0 else {
                    throw api.error("Reading databases", connection)
                }
                return databases.sorted { $0.name < $1.name }
            }
        }
    }

    public func dropDatabase(
        _ database: DatabaseRecord,
        settings: ConnectionSettings,
        password: String
    ) async throws {
        let statement = try Self.dropStatement(database)
        try Self.validate(settings: settings, password: password)
        try await Self.perform { cancellation in
            try Self.withConnection(settings: settings, password: password, cancellation: cancellation) { api, connection in
                // Cancellation is honored up to submission. An already submitted DROP
                // cannot be undone, including if the connection subsequently times out.
                try cancellation.check()
                try Self.performSubmittedDrop {
                    try api.execute(statement, connection: connection)
                }
            }
        }
    }

    /// Only wrap DROP execution, never connection setup or validation: a lost
    /// response here cannot tell us whether the server completed the deletion.
    static func performSubmittedDrop(_ execute: () throws -> Void) throws {
        do {
            try execute()
        } catch DatabaseServiceError.databaseOperation(_, let code)
                    where code == 2006 || code == 2013 || code == 2055 {
            throw DatabaseServiceError.deletionOutcomeUnknown(code: code)
        }
    }

    static func validate(settings: ConnectionSettings, password: String) throws {
        guard ["127.0.0.1", "localhost", "::1"].contains(settings.host) else {
            throw DatabaseServiceError.invalidSettings("Only local hosts are allowed: 127.0.0.1, localhost, or ::1.")
        }
        guard (1...65535).contains(settings.port) else {
            throw DatabaseServiceError.invalidSettings("The port must be between 1 and 65535.")
        }
        guard settings.socketPath.isEmpty || settings.socketPath.hasPrefix("/") else {
            throw DatabaseServiceError.invalidSettings("The Unix socket path must be absolute.")
        }
        guard !settings.username.isEmpty else {
            throw DatabaseServiceError.invalidSettings("Enter a database username.")
        }
        guard ![settings.username, settings.socketPath, password].contains(where: { $0.utf8.contains(0) }) else {
            throw DatabaseServiceError.invalidSettings("Connection fields must not contain a NUL character.")
        }
    }

    static func quotedIdentifier(_ name: String) throws -> String {
        guard !name.isEmpty, !name.utf8.contains(0) else {
            throw DatabaseServiceError.invalidIdentifier
        }
        return "`" + name.replacingOccurrences(of: "`", with: "``") + "`"
    }

    static func dropStatement(_ database: DatabaseRecord) throws -> String {
        guard !database.isSystem else { throw DatabaseServiceError.protectedDatabase }
        return "DROP DATABASE " + (try quotedIdentifier(database.name))
    }

    private static func perform<T: Sendable>(
        _ operation: @escaping @Sendable (CancellationFlag) throws -> T
    ) async throws -> T {
        let cancellation = CancellationFlag()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    continuation.resume(with: Result {
                        try cancellation.check()
                        return try operation(cancellation)
                    })
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func withConnection<T>(
        settings: ConnectionSettings,
        password: String,
        cancellation: CancellationFlag,
        operation: (MariaDBConnector, OpaquePointer) throws -> T
    ) throws -> T {
        let api = try MariaDBConnector.shared.get()
        guard api.threadInit() == 0 else { throw DatabaseServiceError.clientInitialization }
        defer { api.threadEnd() }
        guard let connection = api.initialize(nil) else { throw DatabaseServiceError.clientInitialization }
        defer { api.close(connection) }
        // Stable enum values from MariaDB Connector/C's public mysql.h.
        for option: Int32 in [0, 11, 12] { // CONNECT_TIMEOUT, READ_TIMEOUT, WRITE_TIMEOUT
            var seconds: UInt32 = 10
            guard api.options(connection, option, &seconds) == 0 else {
                throw api.error("Setting connection timeouts", connection)
            }
        }
        var protocolType: UInt32 = settings.socketPath.isEmpty ? 1 : 2 // TCP or SOCKET
        guard api.options(connection, 9, &protocolType) == 0 else {
            throw api.error("Selecting local transport", connection)
        }
        var localInfile: UInt32 = 0
        guard api.options(connection, 8, &localInfile) == 0 else {
            throw api.error("Disabling local file access", connection)
        }
        let charsetResult = "utf8mb4".withCString { api.options(connection, 7, $0) }
        guard charsetResult == 0 else { throw api.error("Setting UTF-8 encoding", connection) }
        try cancellation.check()
        // Never resolve arbitrary names, and never let "localhost" select an implicit socket.
        let host = settings.socketPath.isEmpty
            ? (settings.host == "localhost" ? "127.0.0.1" : settings.host)
            : "localhost"
        let connected = host.withCString { hostPointer in
            settings.username.withCString { userPointer in
                password.withCString { passwordPointer in
                    settings.socketPath.withCString { socketPointer in
                        api.connect(
                            connection, hostPointer, userPointer, passwordPointer, nil,
                            UInt32(settings.port), settings.socketPath.isEmpty ? nil : socketPointer, 0
                        )
                    }
                }
            }
        }
        guard connected != nil else { throw api.error("Connecting to MariaDB", connection) }
        try cancellation.check()
        return try operation(api, connection)
    }
}

/// The lock protects the sole mutable property; cancellation may arrive on any executor.
private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
    }

    func check() throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw CancellationError() }
    }
}

/// Immutable function table. Connections and thread-local initialization stay on
/// the worker queue; the library remains loaded for the lifetime of the process.
final class MariaDBConnector: @unchecked Sendable {
    typealias Initialize = @convention(c) (OpaquePointer?) -> OpaquePointer?
    typealias Close = @convention(c) (OpaquePointer) -> Void
    typealias Options = @convention(c) (OpaquePointer, Int32, UnsafeRawPointer?) -> Int32
    typealias Connect = @convention(c) (
        OpaquePointer, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?,
        UnsafePointer<CChar>?, UInt32, UnsafePointer<CChar>?, UInt
    ) -> OpaquePointer?
    typealias Query = @convention(c) (OpaquePointer, UnsafePointer<CChar>, UInt) -> Int32
    typealias StoreResult = @convention(c) (OpaquePointer) -> OpaquePointer?
    typealias FreeResult = @convention(c) (OpaquePointer) -> Void
    typealias FetchRow = @convention(c) (OpaquePointer) -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
    typealias FetchLengths = @convention(c) (OpaquePointer) -> UnsafeMutablePointer<UInt>?
    typealias ErrorNumber = @convention(c) (OpaquePointer) -> UInt32
    typealias LibraryInit = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
    typealias ThreadInit = @convention(c) () -> Int8
    typealias ThreadEnd = @convention(c) () -> Void

    // Homebrew's Connector/C formula installs under lib, with compatibility
    // symlinks under lib/mariadb, on Apple Silicon and Intel.
    // https://github.com/Homebrew/homebrew-core/blob/master/Formula/m/mariadb-connector-c.rb
    // C signatures and enum values:
    // https://github.com/mariadb-corporation/mariadb-connector-c/blob/3.4/include/mysql.h
    static let libraryPaths = [
        "/opt/homebrew/opt/mariadb-connector-c/lib/mariadb/libmariadb.dylib",
        "/usr/local/opt/mariadb-connector-c/lib/mariadb/libmariadb.dylib",
        "/opt/homebrew/opt/mariadb-connector-c/lib/libmariadb.dylib",
        "/usr/local/opt/mariadb-connector-c/lib/libmariadb.dylib",
        // The server formula bundles Connector/C too; no separate install is needed.
        "/opt/homebrew/opt/mariadb/lib/libmariadb.dylib",
        "/usr/local/opt/mariadb/lib/libmariadb.dylib"
    ]
    static let shared: Result<MariaDBConnector, Error> = Result { try MariaDBConnector() }

    private let library: UnsafeMutableRawPointer
    let initialize: Initialize
    let close: Close
    let options: Options
    let connect: Connect
    let query: Query
    let storeResult: StoreResult
    let freeResult: FreeResult
    let fetchRow: FetchRow
    let fetchLengths: FetchLengths
    let errorNumber: ErrorNumber
    let threadInit: ThreadInit
    let threadEnd: ThreadEnd

    init(paths: [String] = MariaDBConnector.libraryPaths) throws {
        var loaded: UnsafeMutableRawPointer?
        for path in paths {
            if let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) {
                loaded = handle
                break
            }
        }
        guard let loaded else { throw DatabaseServiceError.connectorUnavailable }
        func symbol<T>(_ name: String, as type: T.Type) throws -> T {
            guard let pointer = dlsym(loaded, name) else {
                throw DatabaseServiceError.connectorIncompatible
            }
            return unsafeBitCast(pointer, to: type)
        }
        do {
            initialize = try symbol("mysql_init", as: Initialize.self)
            close = try symbol("mysql_close", as: Close.self)
            options = try symbol("mysql_options", as: Options.self)
            connect = try symbol("mysql_real_connect", as: Connect.self)
            query = try symbol("mysql_real_query", as: Query.self)
            storeResult = try symbol("mysql_store_result", as: StoreResult.self)
            freeResult = try symbol("mysql_free_result", as: FreeResult.self)
            fetchRow = try symbol("mysql_fetch_row", as: FetchRow.self)
            fetchLengths = try symbol("mysql_fetch_lengths", as: FetchLengths.self)
            errorNumber = try symbol("mysql_errno", as: ErrorNumber.self)
            threadInit = try symbol("mysql_thread_init", as: ThreadInit.self)
            threadEnd = try symbol("mysql_thread_end", as: ThreadEnd.self)
            let libraryInit = try symbol("mysql_server_init", as: LibraryInit.self)
            guard libraryInit(0, nil, nil) == 0 else {
                throw DatabaseServiceError.connectorIncompatible
            }
            // mysql_server_init may initialize this thread. Balance it here;
            // each connection operation manages its own thread init/end pair.
            threadEnd()
            library = loaded
        } catch {
            dlclose(loaded)
            throw error
        }
    }

    func execute(_ sql: String, connection: OpaquePointer) throws {
        let status = sql.withCString { query(connection, $0, UInt(sql.utf8.count)) }
        guard status == 0 else { throw error("Database query", connection) }
    }

    func error(_ operation: String, _ connection: OpaquePointer) -> DatabaseServiceError {
        .databaseOperation(operation: operation, code: errorNumber(connection))
    }
}
