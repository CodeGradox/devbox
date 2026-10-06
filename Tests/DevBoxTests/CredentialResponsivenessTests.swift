import Foundation
import Synchronization
import Testing
@testable import DevBox
import DevBoxCore

/// Deliberately blocks an OS thread, like a Security authorization prompt. The
/// test must reach the main-actor heartbeat before releasing that thread.
private final class BlockingCredentialBackend: PasswordCredentialBackend, GitHubCredentialBackend, Sendable {
    let entered = AsyncStream<Void>.makeStream()
    let release = DispatchSemaphore(value: 0)
    private let calls = Mutex(0)

    var count: Int { calls.withLock { $0 } }

    private func block() {
        #expect(!Thread.isMainThread)
        calls.withLock { $0 += 1 }
        entered.continuation.yield(())
        release.wait()
    }

    func password(for id: UUID) throws -> String? { block(); return "synthetic" }
    func save(password: String, for id: UUID) throws { block() }
    func remove(for id: UUID) throws { block() }
    func load() throws -> GitHubToken? { block(); return githubTestToken }
    func save(_ token: GitHubToken) throws { block() }
    func remove() throws { block() }
}

@Test(.timeLimit(.minutes(1)), arguments: ["read", "save", "remove"])
@MainActor
func passwordAdapterSuspendsMainActorWhileSynchronousBackendBlocks(operation: String) async throws {
    let backend = BlockingCredentialBackend()
    let adapter = KeychainCredentials(backend: backend)
    let id = UUID()
    let task = Task {
        switch operation {
        case "read": _ = try await adapter.password(for: id)
        case "save": try await adapter.save(password: "synthetic", for: id)
        default: try await adapter.remove(for: id)
        }
    }
    var entries = backend.entered.stream.makeAsyncIterator()
    await entries.next()
    // This actor must remain available while the backend is still blocked.
    let heartbeat = Task { @MainActor in true }
    #expect(await heartbeat.value)
    backend.release.signal()
    try await task.value
    #expect(backend.count == 1)
}

@Test(.timeLimit(.minutes(1)), arguments: ["read", "save", "remove"])
@MainActor
func githubAdapterSuspendsMainActorWhileSynchronousBackendBlocks(operation: String) async throws {
    let backend = BlockingCredentialBackend()
    let adapter = GitHubKeychainCredentials(backend: backend)
    let task = Task {
        switch operation {
        case "read": _ = try await adapter.load()
        case "save": try await adapter.save(githubTestToken)
        default: try await adapter.remove()
        }
    }
    var entries = backend.entered.stream.makeAsyncIterator()
    await entries.next()
    let heartbeat = Task { @MainActor in true }
    #expect(await heartbeat.value)
    backend.release.signal()
    try await task.value
    #expect(backend.count == 1)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func passwordAdapterCoalescesConcurrentReads() async throws {
    let backend = BlockingCredentialBackend()
    let adapter = KeychainCredentials(backend: backend)
    let id = UUID()
    let first = Task { try await adapter.password(for: id) }
    var entries = backend.entered.stream.makeAsyncIterator()
    await entries.next()
    var secondStarted = false
    let second = Task {
        secondStarted = true
        return try await adapter.password(for: id)
    }
    while !secondStarted { await Task.yield() }
    backend.release.signal()
    #expect(try await first.value == "synthetic")
    #expect(try await second.value == "synthetic")
    #expect(backend.count == 1)
}
