import Foundation
import Observation
import Synchronization
import Testing
@testable import DevBox
@testable import DevBoxCore

@MainActor
private final class DatabaseMemorySettings: SettingsPersisting {
    var value = AppSettings()
    func load() throws -> AppSettings { value }
    func save(_ settings: AppSettings) throws { value = settings }
}

@MainActor
private final class DatabaseMemoryCredentials: CredentialsPersisting {
    var reads = 0
    var removed: [UUID] = []
    func password(for id: UUID) throws -> String? {
        reads += 1
        return "test-secret"
    }
    func save(password: String, for id: UUID) throws {}
    func remove(for id: UUID) throws { removed.append(id) }
}

private enum DatabaseFixtureError: Error { case metadataUnavailable }

private func databaseEstimate(_ bytes: Int64?) -> DatabaseStatistics {
    DatabaseStatistics(tableCount: 2, viewCount: 1, estimatedRows: 17,
                       dataBytes: bytes, indexBytes: 0)
}

/// Deliberately ignores cancellation, as a blocking database client may do.
private actor DatabaseMetadataProbe {
    private(set) var inventories = 0
    private(set) var calls = 0
    private var pending: [Int: CheckedContinuation<[String: DatabaseStatistics], any Error>] = [:]
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var rejectNextInventory = false

    func failNextInventory() { rejectNextInventory = true }

    func inventory() throws -> [DatabaseRecord] {
        inventories += 1
        if rejectNextInventory {
            rejectNextInventory = false
            throw DatabaseFixtureError.metadataUnavailable
        }
        return [DatabaseRecord(name: "app"), DatabaseRecord(name: "mysql")]
    }

    func statistics() async throws -> [String: DatabaseStatistics] {
        calls += 1
        let call = calls
        return try await withCheckedThrowingContinuation { continuation in
            pending[call] = continuation
            let ready = waiters.filter { $0.0 <= call }
            waiters.removeAll { $0.0 <= call }
            for (_, waiter) in ready { waiter.resume() }
        }
    }

    func waitForCall(_ call: Int) async {
        if calls >= call { return }
        await withCheckedContinuation { waiters.append((call, $0)) }
    }

    func succeed(_ call: Int, bytes: Int64) {
        pending.removeValue(forKey: call)?.resume(returning: [
            "app": databaseEstimate(bytes), "mysql": databaseEstimate(0)
        ])
    }

    func fail(_ call: Int) {
        pending.removeValue(forKey: call)?.resume(throwing: DatabaseFixtureError.metadataUnavailable)
    }
}

private final class DatabaseInvalidations: Sendable {
    private let count = Mutex(0)
    var value: Int { count.withLock { $0 } }
    func increment() { count.withLock { $0 += 1 } }
}

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct DatabaseSessionTests {
    private func makeStore(
        _ settings: DatabaseMemorySettings,
        _ credentials: DatabaseMemoryCredentials,
        _ probe: DatabaseMetadataProbe
    ) -> AppStore {
        AppStore(persistence: settings, credentials: credentials,
                 listDatabases: { _, _ in try await probe.inventory() },
                 loadStatistics: { _, _ in try await probe.statistics() },
                 editorLauncher: inertEditorLauncher())
    }

    private func completed(_ session: DatabaseSessionState) async {
        for await loading in Observations({ session.isLoadingStatistics }) {
            if !loading { return }
        }
    }

    @Test
    func reconciliationPreservesIdentityAndDoesNotInvalidateCollectionForMetadata() throws {
        let session = DatabaseSessionState()
        let records = ["app", "other"].map { DatabaseRecord(name: $0) }
        session.reconcile(records)
        let first = try #require(session.row(id: "app"))
        let second = try #require(session.row(id: "other"))
        let changes = DatabaseInvalidations()
        let rowChanges = DatabaseInvalidations()
        withObservationTracking { _ = session.rows } onChange: { changes.increment() }
        withObservationTracking { _ = first.presentation } onChange: { rowChanges.increment() }
        session.reconcile(records)
        session.beginStatistics()
        let date = Date(timeIntervalSince1970: 123)
        session.receive(["app": databaseEstimate(100), "other": databaseEstimate(200)], at: date)
        #expect(session.row(id: "app") === first)
        #expect(session.row(id: "other") === second)
        #expect(changes.value == 0)
        #expect(rowChanges.value == 1)
        #expect(first.measuredAt == date)
        #expect(first.statistics?.estimatedRows == 17)
        #expect(!session.needsStatisticsLoad)
        session.reconcile([records[0], DatabaseRecord(name: "new")])
        #expect(changes.value == 1)
        #expect(session.row(id: "app") === first)
        #expect(session.row(id: "other") == nil)
    }

    @Test
    func missingMetadataIsUnavailableAndFailureKeepsStaleEstimate() throws {
        let session = DatabaseSessionState()
        session.reconcile(["app", "missing"].map { DatabaseRecord(name: $0) })
        let date = Date(timeIntervalSince1970: 123)
        session.receive(["app": databaseEstimate(100)], at: date)
        let app = try #require(session.row(id: "app"))
        let missing = try #require(session.row(id: "missing"))
        #expect(missing.statistics == nil)
        #expect(missing.statisticsError != nil)
        #expect(missing.presentation.size == "—")
        #expect(session.summary.bytes == 100)
        #expect(session.summary.isPartial)
        #expect(session.selectedSummary(["app"]).isPartial == false)
        #expect(session.selectedSummary(["missing"]).text == "Estimated size unavailable")
        session.failStatistics("permission denied")
        #expect(app.statistics?.totalBytes == 100)
        #expect(app.measuredAt == date)
        #expect(app.presentation.isStale)
        #expect(app.presentation.help.contains("permission denied"))
        #expect(session.summary.text.contains("Partial"))
        #expect(session.summary.text.contains("last-known"))
        #expect(session.summary.staleCount == 1)
        session.receive(["app": databaseEstimate(200), "missing": databaseEstimate(0)])
        #expect(!app.presentation.isStale)
        #expect(!session.summary.isPartial)
        #expect(session.summary.knownCount == 2)
    }

    @Test
    func nilAndOverflowTotalsArePartialRatherThanWrappingOrBecomingZero() {
        let session = DatabaseSessionState()
        session.reconcile(["large", "small", "unknown"].map { DatabaseRecord(name: $0) })
        session.receive(["large": databaseEstimate(.max), "small": databaseEstimate(1),
                         "unknown": databaseEstimate(nil)])
        #expect(session.summary.bytes == Int64.max)
        #expect(session.summary.isPartial)
        #expect(session.summary.knownCount == 1)
        #expect(session.summary.databaseCount == 3)
        #expect(session.selectedSummary(["small"]).bytes == 1)
        #expect(!session.selectedSummary(["small"]).isPartial)
        #expect(session.selectedSummary(["unknown"]).knownCount == 0)
        #expect(session.selectedSummary([]).bytes == 0)
        #expect(!session.selectedSummary([]).isPartial)
        session.receive(["large": DatabaseStatistics(tableCount: 1, viewCount: 0,
                         estimatedRows: nil, dataBytes: .max, indexBytes: 1)])
        #expect(session.selectedSummary(["large"]).knownCount == 0)
        // The omitted small database retains its prior estimate, explicitly stale.
        #expect(session.summary.knownCount == 1)
        #expect(session.summary.bytes == 1)
        #expect(session.row(id: "small")?.presentation.isStale == true)
        #expect(session.summary.isPartial)
    }

    @Test
    func inventoryIsUsableWhileMetadataIsHeldAndFailureDoesNotPreventDeletion() async throws {
        let settings = DatabaseMemorySettings()
        let connection = SavedConnection(name: "Test", settings: .init())
        settings.value.connections = [connection]
        let credentials = DatabaseMemoryCredentials()
        let probe = DatabaseMetadataProbe()
        let store = makeStore(settings, credentials, probe)
        store.loadSelection()
        await probe.waitForCall(1)
        let session = try #require(store.selectedDatabaseSession)
        #expect(store.databases.map(\.name) == ["app", "mysql"])
        #expect(!store.isRefreshing)
        #expect(session.isLoadingStatistics)
        store.databaseSelection = ["app"]
        #expect(store.canDeleteSelection)
        await probe.fail(1)
        await completed(session)
        #expect(session.statisticsError != nil)
        #expect(store.databases.count == 2)
        #expect(store.canDeleteSelection)
        store.databaseSelection = ["mysql"]
        #expect(!store.canDeleteSelection)
        let reads = credentials.reads
        store.destination = nil
        store.destination = .connection(connection.id)
        #expect(store.selectedDatabaseSession === session)
        #expect(session.statisticsError != nil)
        #expect(!session.needsStatisticsLoad)
        #expect(credentials.reads == reads)
        #expect(await probe.calls == 1)
    }

    @Test
    func failedInventoryRefreshKeepsVisibleButStaleValuesAndDisablesDeletion() async throws {
        let settings = DatabaseMemorySettings()
        settings.value.connections = [SavedConnection(name: "Test", settings: .init())]
        let probe = DatabaseMetadataProbe()
        let store = makeStore(settings, DatabaseMemoryCredentials(), probe)
        store.loadSelection()
        await probe.waitForCall(1)
        let session = try #require(store.selectedDatabaseSession)
        await probe.succeed(1, bytes: 100)
        await completed(session)
        let original = try #require(session.row(id: "app"))
        store.databaseSelection = ["app"]
        #expect(store.canDeleteSelection)

        await probe.failNextInventory()
        store.refresh()
        for await loading in Observations({ store.isRefreshing }) {
            if !loading { break }
        }
        #expect(store.loadError != nil)
        #expect(session.row(id: "app") === original)
        #expect(store.databases.map(\.name) == ["app", "mysql"])
        #expect(original.statistics?.totalBytes == 100)
        #expect(original.presentation.isStale)
        #expect(session.summary.text.contains("last-known"))
        #expect(!session.statisticsRefreshPending)
        #expect(!session.isLoadingStatistics)
        #expect(!session.hasLoadedInventory)
        #expect(!store.canDeleteSelection)
        #expect(await probe.calls == 1)

        store.refresh()
        await probe.waitForCall(2)
        await probe.succeed(2, bytes: 200)
        await completed(session)
        #expect(store.loadError == nil)
        #expect(session.hasLoadedInventory)
        #expect(!original.presentation.isStale)
        #expect(store.canDeleteSelection)
    }

    @Test
    func databasesDifferingOnlyInUnicodeNormalizationStayDistinctThroughDeletion() async throws {
        let composed = DatabaseRecord(name: "caf\u{e9}")
        let decomposed = DatabaseRecord(name: "cafe\u{301}")
        // MariaDB lists both. Swift equates the names, which used to trap on the duplicate key.
        #expect(composed.name == decomposed.name)
        let settings = DatabaseMemorySettings()
        settings.value.connections = [SavedConnection(name: "Test", settings: .init())]
        let dropped = Mutex<[String]>([])
        let store = AppStore(
            persistence: settings, credentials: DatabaseMemoryCredentials(),
            dropDatabase: { record, _, _ in dropped.withLock { $0.append(record.id) } },
            listDatabases: { _, _ in [composed, decomposed] },
            loadStatistics: { _, _ in [composed.id: databaseEstimate(100), decomposed.id: databaseEstimate(900)] },
            editorLauncher: inertEditorLauncher(),
            authenticate: { _ in }
        )
        store.loadSelection()
        let session = try #require(store.selectedDatabaseSession)
        for await ready in Observations({ session.hasLoadedInventory && !session.statisticsRefreshPending }) {
            if ready { break }
        }
        #expect(store.databases.count == 2)
        #expect(session.row(id: composed.id)?.statistics?.dataBytes == 100)
        #expect(session.row(id: decomposed.id)?.statistics?.dataBytes == 900)

        store.databaseSelection = [decomposed.id]
        #expect(store.selectedDatabases.count == 1)
        #expect(session.selectedSummary(store.databaseSelection).bytes == 900)
        store.prepareDeletion()
        let request = try #require(store.deletionRequest)
        #expect(request.count == 1)
        await store.delete(request)
        #expect(dropped.withLock { $0 } == [decomposed.id])
        #expect(store.deletionEntries.map(\.state) == [.completed])
        #expect(store.databases.map(\.id) == [composed.id])
    }

    @Test
    func uncertainDropKeepsTheRowButRequiresARefreshBeforeAnotherDeletion() async throws {
        let settings = DatabaseMemorySettings()
        settings.value.connections = [SavedConnection(name: "Test", settings: .init())]
        let store = AppStore(
            persistence: settings, credentials: DatabaseMemoryCredentials(),
            dropDatabase: { _, _, _ in throw DatabaseServiceError.deletionOutcomeUnknown(code: 2013) },
            listDatabases: { _, _ in [DatabaseRecord(name: "app"), DatabaseRecord(name: "other")] },
            loadStatistics: { _, _ in ["app": databaseEstimate(1), "other": databaseEstimate(1)] },
            editorLauncher: inertEditorLauncher(),
            authenticate: { _ in }
        )
        store.loadSelection()
        let session = try #require(store.selectedDatabaseSession)
        for await ready in Observations({ session.hasLoadedInventory && !session.statisticsRefreshPending }) {
            if ready { break }
        }
        store.databaseSelection = ["app"]
        store.prepareDeletion()
        let request = try #require(store.deletionRequest)
        await store.delete(request)
        guard case .uncertain = store.deletionEntries[0].state else {
            Issue.record("The lost reply must be reported as uncertain")
            return
        }
        store.sheetDidDismiss() // Show, then close, the results so no modal gets in the way.
        store.activeSheet = nil
        // The server may or may not have dropped it, and the message says to refresh first.
        #expect(store.databases.map(\.name) == ["app", "other"])
        #expect(!session.hasLoadedInventory)
        store.databaseSelection = ["app"]
        #expect(!store.isModalPresented)
        #expect(!store.canDeleteSelection)

        store.refresh()
        for await ready in Observations({ session.hasLoadedInventory && !store.isRefreshing }) {
            if ready { break }
        }
        store.databaseSelection = ["app"]
        #expect(store.canDeleteSelection)
    }

    @Test
    func completingMetadataDoesNotClearActiveDeletionProgress() async throws {
        let settings = DatabaseMemorySettings()
        settings.value.connections = [SavedConnection(name: "Test", settings: .init())]
        let metadata = DatabaseMetadataProbe()
        let deletion = DatabaseMetadataProbe()
        let store = AppStore(
            persistence: settings, credentials: DatabaseMemoryCredentials(),
            dropDatabase: { _, _, _ in _ = try await deletion.statistics() },
            listDatabases: { _, _ in try await metadata.inventory() },
            loadStatistics: { _, _ in try await metadata.statistics() },
            editorLauncher: inertEditorLauncher(),
            authenticate: { _ in }
        )
        store.loadSelection()
        await metadata.waitForCall(1)
        let session = try #require(store.selectedDatabaseSession)
        store.databaseSelection = ["app"]
        store.prepareDeletion()
        let request = try #require(store.deletionRequest)
        let task = Task { await store.delete(request) }
        await deletion.waitForCall(1)
        let progress = store.progressText
        #expect(progress.contains("Deleting"))
        #expect(store.deletionEntries[0].startedAt != nil)
        #expect(store.deletionEntries[0].elapsed == nil)
        await metadata.succeed(1, bytes: 100)
        await completed(session)
        #expect(store.isDeleting)
        #expect(store.progressText == progress)
        await deletion.succeed(1, bytes: 0)
        await task.value
        #expect(store.deletionEntries[0].state == .completed)
        #expect(try #require(store.deletionEntries[0].elapsed) >= 0)
        #expect(store.databases.map(\.name) == ["mysql"])
        #expect(await metadata.calls == 1)
        #expect(await metadata.inventories == 1)
        #expect(!store.isRefreshing)
    }

    @Test
    func reselectionUsesSessionWithoutCredentialReadsButRefreshAndNewStoreRescan() async throws {
        let settings = DatabaseMemorySettings()
        let connection = SavedConnection(name: "Test", settings: .init())
        settings.value.connections = [connection]
        let persisted = try JSONEncoder().encode(settings.value)
        let credentials = DatabaseMemoryCredentials()
        let probe = DatabaseMetadataProbe()
        let store = makeStore(settings, credentials, probe)
        store.loadSelection()
        await probe.waitForCall(1)
        let session = try #require(store.selectedDatabaseSession)
        await probe.succeed(1, bytes: 100)
        await completed(session)
        let reads = credentials.reads
        store.destination = nil
        store.destination = .connection(connection.id)
        store.loadSelection()
        #expect(store.selectedDatabaseSession === session)
        #expect(session.summary.bytes == 100)
        #expect(credentials.reads == reads)
        #expect(await probe.inventories == 1)
        #expect(await probe.calls == 1)
        store.refresh()
        await probe.waitForCall(2)
        #expect(session.summary.bytes == 100)
        await probe.succeed(2, bytes: 200)
        await completed(session)
        #expect(session.summary.bytes == 200)
        #expect(await probe.inventories == 2)
        // Compare decoded values: JSON dictionary key order is not meaningful.
        let saved = try JSONSerialization.jsonObject(with: persisted) as? NSDictionary
        let current = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings.value)) as? NSDictionary
        #expect(saved == current)
        let reopened = makeStore(settings, credentials, probe)
        reopened.loadSelection()
        await probe.waitForCall(3)
        let fresh = try #require(reopened.selectedDatabaseSession)
        #expect(fresh !== session)
        #expect(fresh.row(id: "app")?.statistics == nil)
        await probe.succeed(3, bytes: 300)
        await completed(fresh)
        #expect(fresh.summary.bytes == 300)
        #expect(await probe.inventories == 3)
    }

    @Test
    func unfinishedMetadataResumesWithoutRelistingAndObsoleteRefreshCannotWin() async throws {
        let settings = DatabaseMemorySettings()
        let connection = SavedConnection(name: "Test", settings: .init())
        settings.value.connections = [connection]
        let probe = DatabaseMetadataProbe()
        let store = makeStore(settings, DatabaseMemoryCredentials(), probe)
        store.loadSelection()
        await probe.waitForCall(1)
        let session = try #require(store.selectedDatabaseSession)
        store.destination = nil
        #expect(session.needsStatisticsLoad)
        #expect(!session.isLoadingStatistics)
        store.destination = .connection(connection.id)
        await probe.waitForCall(2)
        #expect(await probe.inventories == 1)
        store.refresh()
        await probe.waitForCall(3)
        // Both previous-selection and previous-refresh requests ignore cancellation.
        await probe.succeed(1, bytes: 111)
        await probe.succeed(2, bytes: 222)
        await probe.succeed(3, bytes: 333)
        await completed(session)
        #expect(session.summary.bytes == 333)
        #expect(!session.needsStatisticsLoad)
        #expect(await probe.inventories == 2)
    }

    @Test
    func editingAndForgettingConnectionDiscardMetadataCache() async throws {
        let settings = DatabaseMemorySettings()
        var connection = SavedConnection(name: "Test", settings: .init())
        settings.value.connections = [connection]
        let credentials = DatabaseMemoryCredentials()
        let probe = DatabaseMetadataProbe()
        let store = makeStore(settings, credentials, probe)
        store.loadSelection()
        await probe.waitForCall(1)
        let original = try #require(store.selectedDatabaseSession)
        await probe.succeed(1, bytes: 100)
        await completed(original)
        connection.settings.host = "new-server.invalid"
        try await store.saveConnection(connection, password: "changed-secret")
        await probe.waitForCall(2)
        let updated = try #require(store.selectedDatabaseSession)
        #expect(updated !== original)
        #expect(updated.row(id: "app")?.statistics == nil)
        await probe.succeed(2, bytes: 200)
        await completed(updated)
        await store.forgetConnection(connection)
        #expect(store.selectedDatabaseSession == nil)
        #expect(settings.value.connections.isEmpty)
        #expect(credentials.removed == [connection.id])
        try await store.saveConnection(connection, password: "new-secret")
        await probe.waitForCall(3)
        let restored = try #require(store.selectedDatabaseSession)
        #expect(restored !== updated)
        #expect(restored.row(id: "app")?.statistics == nil)
        await probe.succeed(3, bytes: 300)
        await completed(restored)
        #expect(restored.summary.bytes == 300)
    }
}
