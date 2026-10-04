import Foundation
import Testing
@testable import DevBox
@testable import DevBoxCore

@MainActor
private final class DeletionSettings: SettingsPersisting {
    // In-memory requests never identify a real database or require a saved connection.
    func load() throws -> AppSettings { AppSettings() }
    func save(_ settings: AppSettings) throws {}
}

@MainActor
private final class DeletionCredentials: CredentialsPersisting {
    var value: String? = "fake deletion-test password"
    func password(for id: UUID) throws -> String? { value }
    func save(password: String, for id: UUID) throws { value = password }
    func remove(for id: UUID) throws { value = nil }
}

private enum DeletionTestError: LocalizedError {
    case denied
    var errorDescription: String? { "Deletion denied by test server" }
}

/// Holds each submitted operation until the test explicitly acknowledges its outcome.
private actor DeletionProbe {
    private(set) var names: [String] = []
    private(set) var passwords: [String] = []
    private(set) var peakConcurrency = 0
    private var active = 0
    private var pending: [String: CheckedContinuation<Void, any Error>] = [:]
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []

    func run(_ name: String, password: String = "") async throws {
        names.append(name)
        passwords.append(password)
        active += 1
        peakConcurrency = max(peakConcurrency, active)
        defer { active -= 1 }
        try await withCheckedThrowingContinuation { continuation in
            pending[name] = continuation
            let ready = observers.filter { names.count >= $0.0 }
            observers.removeAll { names.count >= $0.0 }
            for (_, observer) in ready { observer.resume() }
        }
    }

    func waitForCalls(_ count: Int) async {
        if names.count >= count { return }
        await withCheckedContinuation { observers.append((count, $0)) }
    }

    func finish(_ name: String, error: (any Error)? = nil) {
        guard let continuation = pending.removeValue(forKey: name) else {
            Issue.record("No pending deletion for \(name)")
            return
        }
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }
}

@MainActor
private func deletionFixture(
    probe: DeletionProbe,
    credentials: DeletionCredentials = DeletionCredentials(),
    authenticate: @escaping @MainActor (String) async throws -> Void = { _ in }
) -> (AppStore, DeletionRequest) {
    let connection = SavedConnection(name: "Fake connection", settings: .init())
    let request = DeletionRequest(items: .databases(
        connection, ["first", "second", "third"].map { DatabaseRecord(name: $0) }
    ))
    let store = AppStore(
        persistence: DeletionSettings(),
        credentials: credentials,
        dropDatabase: { row, _, password in
            try await probe.run(row.name, password: password)
        },
        editorLauncher: inertEditorLauncher(),
        authenticate: authenticate
    )
    store.deletionRequest = request
    return (store, request)
}

@MainActor
private func expectPreservedResults(_ store: AppStore) {
    let ids = store.deletionEntries.map(\.id)
    let names = store.deletionEntries.map(\.name)
    let states = store.deletionEntries.map(\.state)
    let elapsed = store.deletionEntries.map(\.elapsed)
    #expect(store.activeSheet == nil)
    #expect(store.isModalPresented)
    #expect(!store.isDeleting)
    store.sheetDidDismiss()
    guard case .results(let result) = store.activeSheet else {
        Issue.record("Expected results only after confirmation dismissal")
        return
    }
    #expect(result.entries.map(\.id) == ids)
    #expect(result.entries.map(\.name) == names)
    #expect(result.entries.map(\.state) == states)
    #expect(result.entries.map(\.elapsed) == elapsed)
    #expect(store.deletionEntries.map(\.state) == states)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func deletionPublishesQueuedAndSequentialProgressWithoutDuplicateSubmissions() async {
    let probe = DeletionProbe()
    let authentication = DeletionProbe()
    let (store, request) = deletionFixture(probe: probe, authenticate: { _ in
        try await authentication.run("authentication")
    })
    let task = Task { await store.delete(request) }
    await authentication.waitForCalls(1)
    #expect(store.isDeleting)
    #expect(store.deletionEntries.map(\.name) == ["first", "second", "third"])
    #expect(store.deletionEntries.map(\.state) == [.queued, .queued, .queued])
    #expect(store.deletionEntries.allSatisfy { $0.startedAt == nil && $0.elapsed == nil })
    let ids = store.deletionEntries.map(\.id)
    #expect(await probe.names.isEmpty)
    await store.delete(request)
    #expect(await authentication.names == ["authentication"])

    await authentication.finish("authentication")
    await probe.waitForCalls(1)
    #expect(store.deletionEntries.map(\.state) == [.deleting, .queued, .queued])
    #expect(store.deletionEntries[0].startedAt != nil)
    #expect(store.deletionEntries[0].elapsed == nil)
    #expect(store.deletionEntries[1].startedAt == nil)
    await store.delete(request)
    #expect(await probe.names == ["first"])

    await probe.finish("first")
    await probe.waitForCalls(2)
    #expect(store.deletionEntries.map(\.state) == [.completed, .deleting, .queued])
    #expect(store.deletionEntries.map(\.id) == ids)
    #expect(await probe.names == ["first", "second"])
    await probe.finish("second")
    await probe.waitForCalls(3)
    #expect(store.deletionEntries.map(\.state) == [.completed, .completed, .deleting])
    await probe.finish("third")
    await task.value

    #expect(store.deletionEntries.map(\.state) == [.completed, .completed, .completed])
    #expect(store.deletionEntries.allSatisfy { $0.startedAt != nil && ($0.elapsed ?? -1) >= 0 })
    #expect(store.deletionEntries.map(\.id) == ids)
    #expect(await probe.peakConcurrency == 1)
    #expect(await probe.passwords == Array(repeating: "fake deletion-test password", count: 3))
    await store.delete(request)
    #expect(await probe.names == ["first", "second", "third"])
    expectPreservedResults(store)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func knownDeletionFailureContinuesSequentiallyAndPreservesFailure() async {
    let probe = DeletionProbe()
    let (store, request) = deletionFixture(probe: probe)
    let task = Task { await store.delete(request) }
    await probe.waitForCalls(1)
    await probe.finish("first", error: DeletionTestError.denied)
    await probe.waitForCalls(2)
    let failure = DeletionState.failed(DeletionTestError.denied.localizedDescription)
    #expect(store.deletionEntries.map(\.state) == [failure, .deleting, .queued])
    #expect(await probe.names == ["first", "second"])
    await probe.finish("second")
    await probe.waitForCalls(3)
    #expect(store.deletionEntries.map(\.state) == [failure, .completed, .deleting])
    await probe.finish("third")
    await task.value
    #expect(store.deletionEntries.map(\.state) == [failure, .completed, .completed])
    #expect((store.deletionEntries[0].elapsed ?? -1) >= 0)
    #expect(await probe.peakConcurrency == 1)
    expectPreservedResults(store)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func uncertainDeletionStopsRemainingItemsWithoutRetry() async {
    let probe = DeletionProbe()
    let (store, request) = deletionFixture(probe: probe)
    let task = Task { await store.delete(request) }
    await probe.waitForCalls(1)
    await probe.finish("first")
    await probe.waitForCalls(2)
    await probe.finish("second", error: DatabaseServiceError.deletionOutcomeUnknown(code: 2013))
    await task.value

    #expect(store.deletionEntries[0].state == .completed)
    #expect((store.deletionEntries[1].elapsed ?? -1) >= 0)
    #expect(store.deletionEntries[2].startedAt == nil)
    #expect(store.deletionEntries[2].elapsed == nil)
    if case .uncertain(let detail) = store.deletionEntries[1].state {
        #expect(!detail.isEmpty)
    } else {
        Issue.record("Lost acknowledgement must not be reported as a known failure")
    }
    if case .notAttempted(let detail) = store.deletionEntries[2].state {
        #expect(!detail.isEmpty)
    } else {
        Issue.record("Items after the uncertain outcome must remain unsubmitted")
    }
    await store.delete(request)
    #expect(await probe.names == ["first", "second"])
    #expect(await probe.peakConcurrency == 1)
    expectPreservedResults(store)
    #expect(await probe.names == ["first", "second"])
}

@Test(.timeLimit(.minutes(1))) @MainActor
func cancelledDeletionAuthenticationLeavesEveryItemQueued() async {
    let probe = DeletionProbe()
    let authentication = DeletionProbe()
    let (store, request) = deletionFixture(probe: probe, authenticate: { _ in
        try await authentication.run("authentication")
    })
    let task = Task { await store.delete(request) }
    await authentication.waitForCalls(1)
    #expect(store.deletionEntries.map(\.state) == [.queued, .queued, .queued])
    await authentication.finish("authentication", error: CancellationError())
    await task.value
    #expect(await probe.names.isEmpty)
    #expect(store.deletionEntries.map(\.state) == [.queued, .queued, .queued])
    #expect(store.deletionRequest?.id == request.id)
    #expect(store.deletionError?.contains("Nothing was deleted.") == true)
    #expect(!store.isDeleting)
    #expect(store.isModalPresented)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func missingDeletionCredentialMarksEveryItemNotAttempted() async {
    let probe = DeletionProbe()
    let credentials = DeletionCredentials()
    credentials.value = nil
    let (store, request) = deletionFixture(probe: probe, credentials: credentials)
    await store.delete(request)
    #expect(await probe.names.isEmpty)
    #expect(store.deletionEntries.count == 3)
    for entry in store.deletionEntries {
        if case .notAttempted(let detail) = entry.state {
            #expect(detail.contains("Keychain"))
        } else {
            Issue.record("Missing credentials must not imply a submitted deletion")
        }
    }
    expectPreservedResults(store)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func newDeletionRequestDoesNotInheritPreviousItemStates() async {
    let probe = DeletionProbe()
    let (store, request) = deletionFixture(probe: probe)
    let task = Task { await store.delete(request) }
    for (index, name) in ["first", "second", "third"].enumerated() {
        await probe.waitForCalls(index + 1)
        await probe.finish(name)
    }
    await task.value
    expectPreservedResults(store)
    store.activeSheet = nil
    store.sheetDidDismiss()

    let next = DeletionRequest(items: request.items)
    store.deletionRequest = next
    for entry in next.entries {
        #expect(store.deletionState(for: entry.name, in: request) == .completed)
        #expect(store.deletionState(for: entry.name, in: next) == .queued)
    }
    #expect(await probe.names == ["first", "second", "third"])
}
