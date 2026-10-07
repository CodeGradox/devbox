import Darwin
import Foundation
import Testing
@testable import DevBoxCore

private struct FTSFixture {
    let root: URL
    let checkout: URL

    init() throws {
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        root = project.appendingPathComponent(".build/test-temp/FTS tests \(UUID().uuidString)")
        checkout = root.appendingPathComponent("checkout ' \"\n\t")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func write(_ path: String, at base: URL? = nil) throws -> URL {
        let url = (base ?? checkout).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: 16_384).write(to: url)
        return url
    }

    // Deliberately independent of both the scanner and Foundation's recursive enumeration.
    func allocatedBytes(_ files: [URL]) throws -> Int64 {
        try files.reduce(Int64(0)) { total, file in
            var information = stat()
            let result = file.path.withCString { lstat($0, &information) }
            try #require(result == 0)
            try #require(information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG))
            return total + Int64(information.st_blocks) * 512
        }
    }
}

@Test func ftsCountsHardLinksAsSeparateRegularEntries() throws {
    let fixture = try FTSFixture()
    defer { fixture.cleanup() }
    let original = try fixture.write("original")
    let alias = fixture.checkout.appendingPathComponent("hard link")
    try FileManager.default.linkItem(at: original, to: alias)
    let usage = try FTSDiskScanner.scan(rootPath: fixture.checkout.path)
    #expect(usage.fileCount == 2)
    #expect(usage.bytes == (try fixture.allocatedBytes([original, alias])))
    #expect(usage.unreadableCount == 0)
}

@Test func ftsCountsSparseAllocationRatherThanLogicalLength() throws {
    let fixture = try FTSFixture()
    defer { fixture.cleanup() }
    let sparse = try fixture.write("sparse")
    let handle = try FileHandle(forWritingTo: sparse)
    defer { try? handle.close() }
    try handle.truncate(atOffset: 128 * 1024 * 1024)
    try handle.synchronize()
    let expected = try fixture.allocatedBytes([sparse])
    #expect(expected < 128 * 1024 * 1024)
    let usage = try FTSDiskScanner.scan(rootPath: fixture.checkout.path)
    #expect(usage.fileCount == 1)
    #expect(usage.bytes == expected)
    #expect(usage.unreadableCount == 0)
}

@Test func ftsCountsResourceForkAllocationWhenSupported() throws {
    let fixture = try FTSFixture()
    defer { fixture.cleanup() }
    let file = try fixture.write("with resource fork")
    let fork = URL(fileURLWithPath: file.path + "/..namedfork/rsrc")
    do {
        try Data(repeating: 0x62, count: 65_536).write(to: fork)
    } catch {
        // Not every filesystem used for the build directory supports resource forks.
        return
    }
    let usage = try FTSDiskScanner.scan(rootPath: fixture.checkout.path)
    #expect(usage.fileCount == 1)
    #expect(usage.bytes == (try fixture.allocatedBytes([file])))
    #expect(usage.unreadableCount == 0)
}

@Test func ftsIncludesHiddenIgnoredAndUnusualNamesButExcludesMetadata() throws {
    let fixture = try FTSFixture()
    defer { fixture.cleanup() }
    let ignore = fixture.checkout.appendingPathComponent(".gitignore")
    try Data("ignored/\n".utf8).write(to: ignore)
    let included = try [
        fixture.write("ignored/cache"),
        fixture.write(".hidden"),
        fixture.write("nested/line\n tab\t quote\" apostrophe' emoji🦊"),
        fixture.write("nested/.gitkeep"),
        fixture.write("other/shared-metadata/payload"),
        // Only the checkout's own metadata is shared. An independent clone's .git is its own storage.
        fixture.write("nested/.git/objects/included"),
        fixture.write("regular-entry/.git")
    ] + [ignore]
    try fixture.write(".git/objects/excluded")
    try fixture.write("shared-metadata/objects/excluded")
    let metadata = fixture.checkout.appendingPathComponent("shared-metadata")
    let usage = try FTSDiskScanner.scan(
        rootPath: fixture.checkout.path,
        excludedDirectoryPath: metadata.path
    )
    #expect(usage.fileCount == included.count)
    #expect(usage.bytes == (try fixture.allocatedBytes(included)))
    #expect(usage.unreadableCount == 0)
}

@Test func ftsDoesNotFollowFileDirectoryOrBrokenSymlinks() throws {
    let fixture = try FTSFixture()
    defer { fixture.cleanup() }
    let included = try fixture.write("included")
    let outside = try fixture.write("outside/payload", at: fixture.root)
    for (name, target) in [
        ("file-link", outside),
        ("directory-link", outside.deletingLastPathComponent()),
        ("broken-link", fixture.root.appendingPathComponent("missing")),
        ("cycle", fixture.checkout)
    ] {
        try FileManager.default.createSymbolicLink(
            at: fixture.checkout.appendingPathComponent(name), withDestinationURL: target
        )
    }
    let usage = try FTSDiskScanner.scan(rootPath: fixture.checkout.path)
    #expect(usage.fileCount == 1)
    #expect(usage.bytes == (try fixture.allocatedBytes([included])))
    #expect(usage.unreadableCount == 0)
}

@Test(arguments: ["", "/", "///"])
func ftsRejectsSymlinkRootWithoutTraversingTarget(suffix: String) throws {
    let fixture = try FTSFixture()
    defer { fixture.cleanup() }
    try fixture.write("payload")
    let alias = fixture.root.appendingPathComponent("root-link")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.checkout)
    let usage: DiskUsage
    do {
        usage = try FTSDiskScanner.scan(rootPath: alias.path + suffix)
    } catch {
        return // Explicit rejection is also a valid result for a symlink root.
    }
    #expect(usage.fileCount == 0)
    #expect(usage.bytes == 0)
    #expect(usage.unreadableCount > 0)
}

@Test func ftsPreservesProcessWorkingDirectory() throws {
    let fixture = try FTSFixture()
    defer { fixture.cleanup() }
    try fixture.write("a/b/c/payload")
    let before = FileManager.default.currentDirectoryPath
    _ = try FTSDiskScanner.scan(rootPath: fixture.checkout.path)
    #expect(FileManager.default.currentDirectoryPath == before)
}

@Test func ftsThrowsForAlreadyCancelledTask() async throws {
    let fixture = try FTSFixture()
    defer { fixture.cleanup() }
    try fixture.write("payload")
    let rootPath = fixture.checkout.path
    let task = Task.detached {
        withUnsafeCurrentTask { $0?.cancel() }
        do {
            _ = try FTSDiskScanner.scan(rootPath: rootPath)
            Issue.record("A pre-cancelled scan must throw CancellationError")
        } catch is CancellationError {
            // Expected, including for small trees that would otherwise finish immediately.
        } catch {
            Issue.record("Unexpected cancellation error: \(error)")
        }
    }
    await task.value
}

@Test func ftsReportsUnreadableSubdirectoryAndKeepsReadableResults() throws {
    guard geteuid() != 0 else { return } // Root bypasses directory permissions.
    let fixture = try FTSFixture()
    defer { fixture.cleanup() }
    let readable = try fixture.write("readable")
    try fixture.write("locked/payload")
    let locked = fixture.checkout.appendingPathComponent("locked")
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
    }
    let usage = try FTSDiskScanner.scan(rootPath: fixture.checkout.path)
    #expect(usage.fileCount == 1)
    #expect(usage.bytes == (try fixture.allocatedBytes([readable])))
    #expect(usage.unreadableCount > 0)
}

@Test func ftsSkipsOnlyTheScanRootsOwnGitEntry() throws {
    let fixture = try FTSFixture()
    defer { fixture.cleanup() }
    try fixture.write(".git/objects/shared")
    let counted = try [
        fixture.write("vendor/dep/.git/objects/own-storage"),
        fixture.write("vendor/dep/.git/HEAD"),
        fixture.write("vendor/dep/source")
    ]
    let usage = try FTSDiskScanner.scan(rootPath: fixture.checkout.path)
    #expect(usage.fileCount == counted.count)
    #expect(usage.bytes == (try fixture.allocatedBytes(counted)))
    // Repository storage is measured from the Git directory itself, where nothing is skipped.
    let storage = try FTSDiskScanner.scan(
        rootPath: fixture.checkout.appendingPathComponent(".git").path, excludeGitEntries: false
    )
    #expect(storage.fileCount == 1)
}
