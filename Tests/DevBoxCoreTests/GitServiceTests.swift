import Foundation
import Testing
@testable import DevBoxCore

private struct Fixture {
    let root: URL
    let repository: URL

    init() throws {
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        root = project.appendingPathComponent(".build/test-temp/DevBox tests \(UUID().uuidString)")
        repository = root.appendingPathComponent("main ' repo\n")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try git(["init", "-b", "main"])
        try git(["config", "user.email", "tests@example.invalid"])
        try git(["config", "user.name", "DevBox Tests"])
        try write("tracked", "original\n")
        try write(".gitignore", "ignored/\n")
        try git(["add", "."])
        try git(["commit", "-m", "Initial"])
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    func write(_ path: String, _ contents: String, at base: URL? = nil) throws {
        let url = (base ?? repository).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    @discardableResult
    func git(_ arguments: [String], at base: URL? = nil) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", (base ?? repository).path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw GitServiceError.git("Test Git command failed: \(arguments)") }
        return process.terminationStatus
    }

    func linked(_ name: String = "linked\t\" checkout\n", branch: String = "feature") throws -> URL {
        let url = root.appendingPathComponent(name)
        try git(["worktree", "add", "-b", branch, url.path])
        return url
    }
}

@Test func discoversCommonIdentityAndParsesUnusualWorktreePaths() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let linked = try fixture.linked()
    let service = GitService()
    let main = try await service.discoverProject(at: fixture.repository.path)
    let other = try await service.discoverProject(at: linked.path)
    #expect(main == other)
    #expect(Set([main, other]).count == 1)
    #expect(main.path != other.path)
    let alias = fixture.root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: linked)
    #expect(try await service.discoverProject(at: alias.path) == main)
    let records = try await service.listWorktrees(project: main)
    #expect(records.count == 2)
    #expect(records.first?.isMain == true)
    let listed = URL(fileURLWithPath: try #require(records.last?.path))
    #expect(listed.resolvingSymlinksInPath().path == linked.resolvingSymlinksInPath().path)
    #expect(listed.lastPathComponent == "linked\t\" checkout\n")
    #expect(records.last?.branch == "feature")
    // A persisted anchor can disappear while the shared Git directory remains.
    let staleAnchor = ProjectRecord(id: main.id, name: main.name, path: "/does/not/exist")
    #expect(try await service.listWorktrees(project: staleAnchor).count == 2)
}

@Test func countsStatusIncludingRenameAndSpecialCharacters() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let service = GitService()
    let project = try await service.discoverProject(at: fixture.repository.path)
    let record = try #require(try await service.listWorktrees(project: project).first)
    #expect(try await service.status(worktree: record).isClean)
    try fixture.git(["mv", "tracked", "renamed\n\t\"file"])
    try fixture.write("renamed\n\t\"file", "changed\n")
    try fixture.write("untracked\n?? odd", "new")
    try fixture.write("ignored/cache", "ignored")
    let status = try await service.status(worktree: record)
    #expect(status.staged == 1)
    #expect(status.modified == 1)
    #expect(status.untracked == 1)
    #expect(status.conflicted == 0)
}

@Test func statusDoesNotRefreshIndexOrHideWorkingTreeChanges() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let service = GitService()
    let project = try await service.discoverProject(at: fixture.repository.path)
    let record = try #require(try await service.listWorktrees(project: project).first)
    let index = fixture.repository.appendingPathComponent(".git/index")
    let before = try Data(contentsOf: index)
    // A changed stat cache with identical content normally invites an optional
    // index refresh. Reading status must not take that write opportunity.
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)],
        ofItemAtPath: fixture.repository.appendingPathComponent("tracked").path
    )
    #expect(try await service.status(worktree: record).isClean)
    #expect(try Data(contentsOf: index) == before)
    try fixture.write("tracked", "modified\n")
    #expect(try await service.status(worktree: record).modified == 1)
    #expect(try Data(contentsOf: index) == before)
}

@Test func diskUsageIncludesIgnoredButNotMetadataOrSymlinkTargets() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let service = GitService()
    let project = try await service.discoverProject(at: fixture.repository.path)
    let record = try #require(try await service.listWorktrees(project: project).first)
    let initial = try await service.diskUsage(worktree: record)
    #expect(initial.fileCount == 2)
    try fixture.write("ignored/cache", String(repeating: "data", count: 8192))
    try fixture.write(".git/not-counted", String(repeating: "metadata", count: 8192))
    try fixture.write("outside", "external", at: fixture.root)
    try FileManager.default.createSymbolicLink(
        at: fixture.repository.appendingPathComponent("outside-link"),
        withDestinationURL: fixture.root
    )
    let usage = try await service.diskUsage(worktree: record)
    #expect(usage.fileCount == 3)
    #expect(usage.bytes > initial.bytes)
    #expect(usage.unreadableCount == 0)
}

@Test func diskUsageExcludesNonstandardSharedGitDirectory() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let metadata = fixture.repository.appendingPathComponent("shared-metadata")
    try fixture.git(["init", "--separate-git-dir", metadata.path])
    try fixture.write("shared-metadata/not-counted", String(repeating: "metadata", count: 8192))
    let service = GitService()
    // Git's worktree list reports the detached metadata location for this layout.
    // Exercise diskUsage on the checkout itself, independent of list discovery.
    let record = WorktreeRecord(path: fixture.repository.path, branch: "main", head: "", isMain: true)
    let usage = try await service.diskUsage(worktree: record)
    #expect(usage.fileCount == 2)
    #expect(usage.unreadableCount == 0)
}

@Test(arguments: [false, true], [false, true])
func diskUsageTraversalIsIndependentOfEntryOrder(linkedCheckout: Bool, linksFirst: Bool) async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let checkout = try linkedCheckout ? fixture.linked() : fixture.repository
    let service = GitService()
    let project = try await service.discoverProject(at: checkout.path)
    let records = try await service.listWorktrees(project: project)
    let record = try #require(linkedCheckout ? records.last : records.first)
    let initial = try await service.diskUsage(worktree: record)
    #expect(initial.fileCount == 2)

    try fixture.write("outside/payload", String(repeating: "external", count: 8192), at: fixture.root)
    let paths = [
        "ignored/cache/deep/payload", "ignored/.hidden",
        "nested-file/after/cache", "nested-directory/after/.hidden",
        ".hidden-directory/nested/payload", "z-directory/payload"
    ]
    func addLinksAndMetadata() throws {
        for name in ["a-link", "z-link", "ignored/cache/a-link"] {
            let link = checkout.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: link.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try FileManager.default.createSymbolicLink(
                at: link, withDestinationURL: fixture.root.appendingPathComponent("outside")
            )
        }
        try FileManager.default.createSymbolicLink(
            at: checkout.appendingPathComponent("broken-link"),
            withDestinationURL: fixture.root.appendingPathComponent("missing")
        )
        try fixture.write("nested-file/.git", "gitdir: not-counted\n", at: checkout)
        try fixture.write("nested-directory/.git/objects/payload", "not-counted", at: checkout)
    }
    if linksFirst { try addLinksAndMetadata() }
    for path in linksFirst ? paths : paths.reversed() {
        try fixture.write(path, String(repeating: path, count: 2048), at: checkout)
    }
    if !linksFirst { try addLinksAndMetadata() }

    var addedBytes: Int64 = 0
    for path in paths {
        let values = try checkout.appendingPathComponent(path).resourceValues(
            forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        )
        addedBytes += Int64(try #require(values.totalFileAllocatedSize ?? values.fileAllocatedSize))
    }
    let usage = try await service.diskUsage(worktree: record)
    #expect(usage.fileCount == initial.fileCount + paths.count)
    #expect(usage.bytes == initial.bytes + addedBytes)
    #expect(usage.unreadableCount == 0)
}

@Test func deletionRechecksLockDirtyStateAndAllowsExplicitForce() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let linked = try fixture.linked()
    let service = GitService()
    let project = try await service.discoverProject(at: fixture.repository.path)
    let records = try await service.listWorktrees(project: project)
    let main = try #require(records.first)
    let record = try #require(records.last)
    await #expect(throws: GitServiceError.self) {
        try await service.remove(worktree: main, project: project, allowDirty: true)
    }
    try fixture.git(["worktree", "lock", "--reason", "keep\nthis", linked.path])
    let locked = try #require(try await service.listWorktrees(project: project).last)
    #expect(locked.isLocked)
    #expect(locked.lockReason == "keep\nthis")
    await #expect(throws: GitServiceError.self) {
        try await service.remove(worktree: record, project: project, allowDirty: true)
    }
    try fixture.git(["worktree", "unlock", linked.path])
    try fixture.write("dirty", "unsaved", at: linked)
    await #expect(throws: GitServiceError.self) {
        try await service.remove(worktree: record, project: project, allowDirty: false)
    }
    #expect(FileManager.default.fileExists(atPath: linked.path))
    try await service.remove(worktree: record, project: project, allowDirty: true)
    #expect(!FileManager.default.fileExists(atPath: linked.path))
    #expect(try await service.listWorktrees(project: project).count == 1)
}

@Test func deletionRejectsChangedHeadAndMissingRegistrationWithoutPruning() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let linked = try fixture.linked()
    let service = GitService()
    let project = try await service.discoverProject(at: fixture.repository.path)
    let stale = try #require(try await service.listWorktrees(project: project).last)
    try fixture.git(["commit", "--allow-empty", "-m", "Changed"], at: linked)
    await #expect(throws: GitServiceError.self) {
        try await service.remove(worktree: stale, project: project, allowDirty: true)
    }
    let current = try #require(try await service.listWorktrees(project: project).last)
    try FileManager.default.removeItem(at: linked)
    await #expect(throws: GitServiceError.self) {
        try await service.remove(worktree: current, project: project, allowDirty: true)
    }
    let remaining = try await service.listWorktrees(project: project)
    #expect(remaining.count == 2)
    #expect(remaining.last?.exists == false)
    #expect(remaining.last?.isPrunable == true)
}

@Test func removesCleanLinkedWorktreeWithoutForce() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    _ = try fixture.linked()
    let service = GitService()
    let project = try await service.discoverProject(at: fixture.repository.path)
    let record = try #require(try await service.listWorktrees(project: project).last)
    try await service.remove(worktree: record, project: project, allowDirty: false)
    #expect(try await service.listWorktrees(project: project).count == 1)
}

@Test func bareRepositoryHasNoCheckoutStatusOrCheckoutDiskUsage() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let bare = fixture.root.appendingPathComponent("bare.git")
    try fixture.git(["clone", "--bare", fixture.repository.path, bare.path])
    let service = GitService()
    let project = try await service.discoverProject(at: bare.path)
    let record = try #require(try await service.listWorktrees(project: project).first)
    #expect(record.isBare)
    #expect(record.isMain)
    #expect(try await service.diskUsage(worktree: record).bytes == 0)
    await #expect(throws: GitServiceError.self) { try await service.status(worktree: record) }
    await #expect(throws: GitServiceError.self) {
        try await service.remove(worktree: record, project: project, allowDirty: true)
    }
}

@Test func statusCountsConflictOnceInsteadOfStagedAndModified() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try fixture.git(["checkout", "-b", "other"])
    try fixture.write("tracked", "other\n")
    try fixture.git(["commit", "-am", "Other"])
    try fixture.git(["checkout", "main"])
    try fixture.write("tracked", "main\n")
    try fixture.git(["commit", "-am", "Main"])
    do {
        try fixture.git(["merge", "other"])
        Issue.record("Merge should conflict")
    } catch { }
    let service = GitService()
    let project = try await service.discoverProject(at: fixture.repository.path)
    let record = try #require(try await service.listWorktrees(project: project).first)
    let status = try await service.status(worktree: record)
    #expect(status.conflicted == 1)
    #expect(status.staged == 0)
    #expect(status.modified == 0)
}

@Test func cancelledDiskScanThrowsCancellation() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let service = GitService()
    let project = try await service.discoverProject(at: fixture.repository.path)
    let record = try #require(try await service.listWorktrees(project: project).first)
    let scan = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await service.diskUsage(worktree: record)
    }
    await #expect(throws: CancellationError.self) { try await scan.value }
}
