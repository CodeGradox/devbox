import Darwin
import Foundation
import Testing
@testable import DevBoxCore

private struct SizingFixture {
    let root: URL
    let repository: URL

    init() throws {
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        root = project.appendingPathComponent(".build/test-temp/project-sizing-\(UUID())")
        repository = root.appendingPathComponent("repo")
        do {
            try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
            try git(["init", "-b", "main"])
            try git(["-c", "user.name=Tests", "-c", "user.email=tests@example.invalid",
                     "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "Initial"])
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func git(_ arguments: [String]) throws -> Data {
        try GitService.git(["-C", repository.path, "-c", "core.hooksPath=/dev/null"] + arguments)
    }

    func add(_ branch: String, at path: URL) throws {
        try git(["worktree", "add", "-b", branch, path.path])
    }

    @discardableResult
    func write(_ path: String, in base: URL) throws -> URL {
        let url = base.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 91, count: 16384).write(to: url)
        return url
    }

    func allocatedBytes(_ files: [URL]) throws -> Int64 {
        try files.reduce(Int64(0)) { total, file in
            var info = stat()
            guard lstat(file.path, &info) == 0 else { throw POSIXError(.EIO) }
            return total + Int64(info.st_blocks) * 512
        }
    }
}

@Test func projectSizingCountsNestedAndAdjacentWorktreesExactlyOnce() async throws {
    let fixture = try SizingFixture()
    defer { fixture.cleanup() }
    let nested = fixture.repository.appendingPathComponent(".worktrees/feature")
    let deep = nested.appendingPathComponent("arbitrary-name/inner")
    let adjacent = fixture.root.appendingPathComponent("repo-adjacent")
    try fixture.add("feature", at: nested)
    try fixture.add("deep", at: deep)
    try fixture.add("adjacent", at: adjacent)
    let mainFiles = try [
        fixture.write("main.data", in: fixture.repository),
        fixture.write(".worktrees/note.txt", in: fixture.repository),
        fixture.write(".worktrees/unregistered/payload", in: fixture.repository)
    ]
    let files = try mainFiles + [
        fixture.write("feature.data", in: nested),
        fixture.write("deep.data", in: deep),
        fixture.write("adjacent.data", in: adjacent)
    ]
    let service = GitService()
    let project = try await service.discoverProject(at: nested.path)
    let records = try await service.listWorktrees(project: project)
    let main = try #require(records.first { $0.isMain })
    let child = try #require(records.first { $0.branch == "feature" })
    let outside = try #require(records.first { $0.branch == "adjacent" })
    #expect(main.nestedWorktreePaths.count == 2)
    #expect(child.nestedWorktreePaths.count == 1)
    #expect(outside.nestedWorktreePaths.isEmpty)
    let mainUsage = try await service.diskUsage(worktree: main)
    #expect(mainUsage.fileCount == 3)
    #expect(mainUsage.bytes == (try fixture.allocatedBytes(mainFiles)))
    var total: Int64 = 0
    var count = 0
    for record in records {
        let usage = try await service.diskUsage(worktree: record)
        #expect(usage.unreadableCount == 0)
        total += usage.bytes
        count += usage.fileCount
    }
    #expect(count == files.count)
    #expect(total == (try fixture.allocatedBytes(files)))
    let storage = try await service.gitStorageUsage(project: project)
    let direct = try FTSDiskScanner.scan(rootPath: project.id, excludeGitEntries: false)
    #expect(storage.fileCount > 0)
    #expect(storage.bytes == direct.bytes)
    #expect(storage.unreadableCount == 0)
}

@Test func projectSizingProtectsNestedRegistrationsEvenFromStaleRemovalSnapshot() async throws {
    let fixture = try SizingFixture()
    defer { fixture.cleanup() }
    let parent = fixture.root.appendingPathComponent("parent")
    let child = parent.appendingPathComponent("nested/child")
    try fixture.add("parent", at: parent)
    let service = GitService()
    let project = try await service.discoverProject(at: fixture.repository.path)
    let before = try await service.listWorktrees(project: project)
    let stale = try #require(before.first { $0.branch == "parent" })
    try fixture.add("child", at: child)
    await #expect(throws: GitServiceError.self) {
        try await service.remove(worktree: stale, project: project, allowDirty: true)
    }
    #expect(FileManager.default.fileExists(atPath: child.path))
    let current = try await service.listWorktrees(project: project)
    let nested = try #require(current.first { $0.branch == "child" })
    try await service.remove(worktree: nested, project: project, allowDirty: true)
    let remaining = try await service.listWorktrees(project: project)
    let removable = try #require(remaining.first { $0.branch == "parent" })
    #expect(removable.nestedWorktreePaths.isEmpty)
    try await service.remove(worktree: removable, project: project, allowDirty: true)
    #expect(!FileManager.default.fileExists(atPath: parent.path))
}

@Test func projectSizingRetainsProtectionForMissingNestedRegistration() async throws {
    let fixture = try SizingFixture()
    defer { fixture.cleanup() }
    let parent = fixture.root.appendingPathComponent("parent")
    let child = parent.appendingPathComponent("child")
    try fixture.add("parent", at: parent)
    try fixture.add("child", at: child)
    try FileManager.default.removeItem(at: child)
    let service = GitService()
    let project = try await service.discoverProject(at: fixture.repository.path)
    let records = try await service.listWorktrees(project: project)
    let record = try #require(records.first { $0.branch == "parent" })
    #expect(record.nestedWorktreePaths.count == 1)
    let usage = try await service.diskUsage(worktree: record)
    #expect(usage.fileCount == 0)
    #expect(usage.unreadableCount == 0)
    await #expect(throws: GitServiceError.self) {
        try await service.remove(worktree: record, project: project, allowDirty: true)
    }
}

@Test func projectSizingCountsBareStorageWithoutItsContainedCheckout() async throws {
    let fixture = try SizingFixture()
    defer { fixture.cleanup() }
    let bare = fixture.root.appendingPathComponent("bare.git")
    try fixture.git(["clone", "--bare", fixture.repository.path, bare.path])
    let child = bare.appendingPathComponent("checkouts/feature")
    _ = try GitService.git(["--git-dir", bare.path, "worktree", "add", "-b", "feature", child.path])
    try fixture.write("checkout.data", in: child)
    let service = GitService()
    let project = try await service.discoverProject(at: bare.path)
    let records = try await service.listWorktrees(project: project)
    let checkout = try #require(records.first { !$0.isBare })
    let bareRecord = try #require(records.first { $0.isBare })
    let storage = try await service.gitStorageUsage(project: project)
    let entire = try FTSDiskScanner.scan(rootPath: bare.path, excludeGitEntries: false)
    let checkoutIncludingMarker = try FTSDiskScanner.scan(rootPath: child.path, excludeGitEntries: false)
    #expect(storage.bytes + checkoutIncludingMarker.bytes == entire.bytes)
    #expect(storage.fileCount + checkoutIncludingMarker.fileCount == entire.fileCount)
    #expect(storage.bytes > 0)
    #expect(try await service.diskUsage(worktree: bareRecord).bytes == 0)
    #expect(try await service.diskUsage(worktree: checkout).fileCount == 1)
}

@Test func projectRecordDecodesOlderSettingsAndRetainsMergePreference() throws {
    let old = Data(#"{"id":"/repo/.git","name":"Repo","path":"/repo"}"#.utf8)
    let decoded = try JSONDecoder().decode(ProjectRecord.self, from: old)
    #expect(decoded.mergeTarget == nil)
    let configured = ProjectRecord(id: decoded.id, name: decoded.name, path: decoded.path, mergeTarget: "refs/heads/main")
    let restored = try JSONDecoder().decode(ProjectRecord.self, from: JSONEncoder().encode(configured))
    #expect(restored.mergeTarget == "refs/heads/main")
    #expect(restored == decoded)
}
