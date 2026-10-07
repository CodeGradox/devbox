import Foundation
import Testing
@testable import DevBoxCore

private struct BranchFixture {
    let root: URL
    let repository: URL

    init(unborn: Bool = false) throws {
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        root = project.appendingPathComponent(".build/test-temp/Branch inspection \(UUID().uuidString)")
        repository = root.appendingPathComponent("main '\n checkout")
        do {
            try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
            try git(["init", "-b", "main"])
            try git(["config", "user.name", "DevBox Tests"])
            try git(["config", "user.email", "tests@example.invalid"])
            if !unborn { try git(["commit", "--allow-empty", "-m", "Initial"]) }
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func git(_ arguments: [String], at directory: URL? = nil) throws -> String {
        String(decoding: try GitService.git(
            ["-C", (directory ?? repository).path, "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"] + arguments
        ), as: UTF8.self)
            .trimmingCharacters(in: .newlines)
    }

    func linked(_ branch: String) throws -> URL {
        let path = root.appendingPathComponent(branch + "\t\n checkout")
        try git(["worktree", "add", "-b", branch, path.path])
        return path
    }

    func project(at directory: URL? = nil, target: String? = nil) async throws -> ProjectRecord {
        let discovered = try await GitService().discoverProject(at: (directory ?? repository).path)
        return ProjectRecord(id: discovered.id, name: discovered.name, path: discovered.path, mergeTarget: target)
    }

    func inspect(_ project: ProjectRecord) async throws -> BranchInspection {
        try await BranchStatusService().inspect(
            project: project, worktrees: GitService().listWorktrees(project: project)
        )
    }
}

@Test func branchInspectionUsesPrimarySnapshotAndExplicitTarget() async throws {
    let fixture = try BranchFixture()
    defer { fixture.cleanup() }
    let merged = try fixture.linked("merged")
    try fixture.git(["commit", "--allow-empty", "-m", "Merged change"], at: merged)
    try fixture.git(["merge", "--ff-only", "merged"])
    let pending = try fixture.linked("pending")
    try fixture.git(["commit", "--allow-empty", "-m", "Pending change"], at: pending)
    let project = try await fixture.project(at: pending)
    let records = try await GitService().listWorktrees(project: project)
    let main = try #require(records.first(where: { $0.isMain }))
    let mergedRecord = try #require(records.first(where: { $0.branch == "merged" }))
    let pendingRecord = try #require(records.first(where: { $0.branch == "pending" }))
    // Caller ordering/selection must not determine the default target.
    let result = try await BranchStatusService().inspect(project: project, worktrees: Array(records.reversed()))
    #expect(result.targetReference == "refs/heads/main")
    #expect(result.targetCommit == main.head)
    #expect(result.byWorktreeID[main.id]?.mergeState == .base)
    #expect(result.byWorktreeID[mergedRecord.id]?.mergeState == .merged)
    #expect(result.byWorktreeID[pendingRecord.id]?.mergeState == .notMerged)
    #expect(result.byWorktreeID.values.allSatisfy { !$0.upstreamGone })
    #expect(result.availableTargets.contains(BranchTarget(reference: "refs/heads/main", label: "main")))
    let overridden = try await fixture.inspect(fixture.project(target: "refs/heads/pending"))
    #expect(overridden.byWorktreeID[pendingRecord.id]?.mergeState == .base)
    #expect(overridden.byWorktreeID[main.id]?.mergeState == .merged)
}

@Test func branchInspectionGoneUpstreamDoesNotImplySquashMerged() async throws {
    let fixture = try BranchFixture()
    defer { fixture.cleanup() }
    let feature = try fixture.linked("feature")
    try Data("squash me\n".utf8).write(to: feature.appendingPathComponent("change"))
    try fixture.git(["add", "change"], at: feature)
    try fixture.git(["commit", "-m", "Feature"], at: feature)
    try fixture.git(["remote", "add", "origin", fixture.root.appendingPathComponent("not-a-remote").path])
    try fixture.git(["update-ref", "refs/remotes/origin/feature", "refs/heads/feature"])
    try fixture.git(["branch", "--set-upstream-to=origin/feature", "feature"])
    try fixture.git(["update-ref", "refs/remotes/origin/main", "refs/heads/main"])
    try fixture.git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"])
    let project = try await fixture.project()
    let before = try await fixture.inspect(project)
    #expect(before.byWorktreeID.values.allSatisfy { !$0.upstreamGone })
    #expect(before.availableTargets.contains { $0.reference == "refs/remotes/origin/main" })
    #expect(!before.availableTargets.contains { $0.reference == "refs/remotes/origin/HEAD" })
    try fixture.git(["merge", "--squash", "feature"])
    try fixture.git(["commit", "-m", "Squashed"])
    try fixture.git(["update-ref", "-d", "refs/remotes/origin/feature"])
    let records = try await GitService().listWorktrees(project: project)
    let featureRecord = try #require(records.first(where: { $0.branch == "feature" }))
    let result = try await fixture.inspect(project)
    #expect(result.byWorktreeID[featureRecord.id]?.mergeState == .notMerged)
    #expect(result.byWorktreeID[featureRecord.id]?.upstreamGone == true)
    let main = try #require(records.first(where: { $0.isMain }))
    #expect(result.byWorktreeID[main.id]?.upstreamGone == false)
    // Upstream state can change without either comparison commit moving.
    try fixture.git(["update-ref", "refs/remotes/origin/feature", "refs/heads/feature"])
    let restored = try await fixture.inspect(project)
    #expect(restored.targetCommit == result.targetCommit)
    #expect(restored.byWorktreeID[featureRecord.id]?.mergeState == .notMerged)
    #expect(restored.byWorktreeID[featureRecord.id]?.upstreamGone == false)
    try fixture.git(["config", "branch.feature.merge", "refs/heads/another-upstream"])
    let changedTracking = try await fixture.inspect(project)
    #expect(changedTracking.targetCommit == result.targetCommit)
    #expect(changedTracking.byWorktreeID[featureRecord.id]?.upstreamGone == true)
}

@Test func branchInspectionHandlesDetachedUnbornAndInvalidTargets() async throws {
    let fixture = try BranchFixture()
    defer { fixture.cleanup() }
    let linked = try fixture.linked("feature")
    try fixture.git(["checkout", "--detach"], at: linked)
    let project = try await fixture.project()
    var records = try await GitService().listWorktrees(project: project)
    let detached = try #require(records.first(where: { !$0.isMain }))
    let first = try await fixture.inspect(project)
    #expect(first.byWorktreeID[detached.id]?.mergeState == .merged)
    try fixture.git(["checkout", "--detach"])
    let second = try await fixture.inspect(project)
    #expect(second.targetReference == nil)
    #expect(second.byWorktreeID[detached.id]?.mergeState == .merged)
    records = try await GitService().listWorktrees(project: project)
    let main = try #require(records.first(where: { $0.isMain }))
    #expect(second.byWorktreeID[main.id]?.mergeState == .base)
    for invalid in ["refs/heads/missing", "--help", "main", "refs/heads/main^{commit}"] {
        let result = try await fixture.inspect(fixture.project(target: invalid))
        #expect(result.warning != nil)
        #expect(result.targetCommit == nil)
        #expect(result.byWorktreeID.values.allSatisfy { $0.mergeState == .unknown })
    }
    let missingPrimary = try await BranchStatusService().inspect(project: project, worktrees: [detached])
    #expect(missingPrimary.warning != nil)
    #expect(missingPrimary.byWorktreeID[detached.id]?.mergeState == .unknown)
    let unborn = try BranchFixture(unborn: true)
    defer { unborn.cleanup() }
    let empty = try await unborn.inspect(unborn.project())
    #expect(empty.targetCommit == nil)
    #expect(empty.warning != nil)
    #expect(empty.byWorktreeID.values.allSatisfy { $0.mergeState == .unknown })
}

@Test func branchInspectionRejectsMovedSnapshotAndShallowNegative() async throws {
    let fixture = try BranchFixture()
    defer { fixture.cleanup() }
    let feature = try fixture.linked("feature")
    let project = try await fixture.project()
    let snapshot = try await GitService().listWorktrees(project: project)
    let record = try #require(snapshot.first(where: { $0.branch == "feature" }))
    try fixture.git(["commit", "--allow-empty", "-m", "Moved"], at: feature)
    let moved = try await BranchStatusService().inspect(project: project, worktrees: snapshot)
    #expect(moved.byWorktreeID[record.id]?.mergeState == .unknown)
    let featureHash = try fixture.git(["rev-parse", "feature"])
    // A real shallow boundary makes the negative comparison inconclusive.
    try Data((featureHash + "\n").utf8).write(to: URL(fileURLWithPath: project.id).appendingPathComponent("shallow"))
    let shallow = try await fixture.inspect(project)
    #expect(shallow.byWorktreeID[record.id]?.mergeState == .unknown)
    let main = try #require(snapshot.first(where: { $0.isMain }))
    #expect(shallow.byWorktreeID[main.id]?.mergeState == .base)
}

@Test func branchInspectionHandlesBareAndMissingPrimaryAndCancellation() async throws {
    let fixture = try BranchFixture()
    defer { fixture.cleanup() }
    let project = try await fixture.project()
    let records = try await GitService().listWorktrees(project: project)
    let main = try #require(records.first(where: { $0.isMain }))
    let missing = WorktreeRecord(path: main.path, branch: main.branch, head: main.head,
                                 isMain: true, exists: false)
    let result = try await BranchStatusService().inspect(project: project, worktrees: [missing])
    #expect(result.targetCommit == nil)
    #expect(result.byWorktreeID[missing.id]?.mergeState == .unknown)
    let barePath = fixture.root.appendingPathComponent("bare.git")
    try fixture.git(["clone", "--bare", fixture.repository.path, barePath.path])
    let bareProject = try await GitService().discoverProject(at: barePath.path)
    let bare = try await fixture.inspect(bareProject)
    #expect(bare.warning != nil)
    #expect(bare.targetCommit == nil)
    #expect(bare.byWorktreeID.values.allSatisfy { $0.mergeState == .unknown })
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await BranchStatusService().inspect(project: project, worktrees: records)
    }
    do {
        _ = try await task.value
        Issue.record("A cancelled inspection should throw CancellationError")
    } catch is CancellationError {
        // Cancellation is not converted into an unknown result.
    }
}

@Test func branchFixtureIgnoresTheDevelopersGitSetup() throws {
    let fixture = try withHostileGitEnvironment { try BranchFixture() }
    defer { fixture.cleanup() }
    try withHostileGitEnvironment { try fixture.git(["commit", "--allow-empty", "-m", "Second"]) }
    #expect(try fixture.git(["rev-list", "--count", "HEAD"]) == "2")
}
