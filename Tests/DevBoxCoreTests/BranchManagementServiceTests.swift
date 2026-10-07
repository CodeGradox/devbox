import Foundation
import Testing
@testable import DevBoxCore

private struct ManagementFixture {
    let root: URL
    let repository: URL
    let server: URL

    init() throws {
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        root = project.appendingPathComponent(".build/test-temp/Branch management \(UUID().uuidString)")
        repository = root.appendingPathComponent("checkout")
        server = root.appendingPathComponent("server.git")
        do {
            try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
            try git(["init", "-b", "main"])
            try git(["config", "user.name", "Committer Example"])
            try git(["config", "user.email", "committer@example.invalid"])
            try git(["commit", "--allow-empty", "--author=Different Author <author@example.invalid>", "-m", "Initial"])
            try git(["init", "--bare", "-b", "main", server.path])
            try git(["remote", "add", "team/upstream", server.path])
            try git(["push", "team/upstream", "main"])
            try git(["symbolic-ref", "refs/remotes/team/upstream/HEAD", "refs/remotes/team/upstream/main"])
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func git(_ args: [String], at path: URL? = nil) throws -> String {
        String(decoding: try GitService.git(
            ["-C", (path ?? repository).path, "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"] + args
        ), as: UTF8.self)
            .trimmingCharacters(in: .newlines)
    }

    func project() async throws -> ProjectRecord {
        try await GitService().discoverProject(at: repository.path)
    }

    func publish(_ name: String = "topic") throws {
        try git(["branch", name])
        try git(["push", "-u", "team/upstream", name])
    }

    func branch(_ reference: String) async throws -> ManagedBranch {
        let branches = try await BranchManagementService().list(project: project())
        return try #require(branches.first { $0.reference == reference })
    }
}

@Test func managementListsCommitterDateAndProtectsWorktrees() async throws {
    let f = try ManagementFixture()
    defer { f.cleanup() }
    let linked = f.root.appendingPathComponent("linked\ncheckout")
    try f.git(["worktree", "add", "-b", "working", linked.path])
    try f.publish()
    let branches = try await BranchManagementService().list(project: f.project())
    #expect(!branches.contains { $0.reference.hasSuffix("/HEAD") })
    let topic = try #require(branches.first { $0.reference == "refs/remotes/team/upstream/topic" })
    #expect(topic.id == topic.reference)
    #expect(topic.name == "topic")
    #expect(topic.remoteName == "team/upstream")
    #expect(topic.committerName == "Committer Example")
    #expect(topic.committerEmail == "committer@example.invalid")
    #expect(topic.committedAt?.timeIntervalSince1970 == Double(try f.git(["show", "-s", "--format=%ct", "topic"])))
    #expect(topic.protectedReason == nil)
    #expect(branches.first { $0.name == "working" }?.protectedReason != nil)
    #expect(branches.first { $0.reference == "refs/heads/main" }?.protectedReason != nil)
    let project = try await f.project()
    let targeted = ProjectRecord(id: project.id, name: project.name, path: project.path, mergeTarget: "refs/heads/topic")
    let targetedBranches = try await BranchManagementService().list(project: targeted)
    #expect(targetedBranches.first { $0.reference == "refs/heads/topic" }?.protectedReason == "Selected merge target.")
}

@Test func managementLocalSafeForceAndStaleDeletion() async throws {
    let f = try ManagementFixture()
    defer { f.cleanup() }
    let service = BranchManagementService()
    let project = try await f.project()
    try f.git(["branch", "merged"])
    try await service.delete(branch: f.branch("refs/heads/merged"), project: project, force: false)
    try f.git(["checkout", "-b", "pending"])
    try f.git(["commit", "--allow-empty", "-m", "Unmerged"])
    try f.git(["checkout", "main"])
    let pending = try await f.branch("refs/heads/pending")
    await #expect(throws: (any Error).self) { try await service.delete(branch: pending, project: project, force: false) }
    try await service.delete(branch: pending, project: project, force: true)
    try f.git(["branch", "stale"])
    let stale = try await f.branch("refs/heads/stale")
    try f.git(["commit", "--allow-empty", "-m", "Moved"])
    try f.git(["branch", "-f", "stale", "main"])
    await #expect(throws: (any Error).self) { try await service.delete(branch: stale, project: project, force: true) }
    let fresh = try await f.branch("refs/heads/stale")
    try f.git(["symbolic-ref", "refs/heads/stale", "refs/heads/main"])
    await #expect(throws: (any Error).self) { try await service.delete(branch: fresh, project: project, force: true) }
}

@Test func managementDeletesServerRefAndRejectsStaleLease() async throws {
    let f = try ManagementFixture()
    defer { f.cleanup() }
    let service = BranchManagementService()
    let project = try await f.project()
    try f.publish("delete-me")
    try await service.delete(branch: f.branch("refs/remotes/team/upstream/delete-me"), project: project, force: false)
    #expect(try f.git(["for-each-ref", "--format=%(refname)", "refs/heads/delete-me"], at: f.server).isEmpty)
    try f.publish("stale")
    let stale = try await f.branch("refs/remotes/team/upstream/stale")
    try f.git(["commit", "--allow-empty", "-m", "Server moved"])
    let moved = try f.git(["rev-parse", "HEAD"])
    // Pushing to the URL avoids updating the configured tracking ref.
    try f.git(["push", f.server.path, "HEAD:refs/heads/stale"])
    // Git may opportunistically update matching remotes; restore the captured tracking snapshot.
    try f.git(["update-ref", stale.reference, stale.commit])
    await #expect(throws: BranchManagementError.self) {
        try await service.delete(branch: stale, project: project, force: false)
    }
    #expect(try f.git(["rev-parse", "refs/heads/stale"], at: f.server) == moved)
}

@Test func managementBatchSnapshotsSurviveUnrelatedBranchConfigRemoval() async throws {
    let f = try ManagementFixture()
    defer { f.cleanup() }
    let service = BranchManagementService()
    let project = try await f.project()
    try f.publish("first")
    try f.publish("second")
    let branches = try await service.list(project: project)
    for reference in ["refs/heads/first", "refs/heads/second",
                      "refs/remotes/team/upstream/first", "refs/remotes/team/upstream/second"] {
        let branch = try #require(branches.first { $0.reference == reference })
        try await service.delete(branch: branch, project: project, force: false)
    }
    #expect(try f.git(["for-each-ref", "--format=%(refname)", "refs/heads/first", "refs/heads/second"]).isEmpty)
    #expect(try f.git(["for-each-ref", "--format=%(refname)", "refs/heads/first", "refs/heads/second"], at: f.server).isEmpty)
}

@Test func managementRelativeRemoteUsesPrimaryRepositoryAndCleansTrackingRef() async throws {
    let f = try ManagementFixture()
    defer { f.cleanup() }
    try f.publish()
    try f.git(["config", "remote.team/upstream.url", "../server.git"])
    let linked = f.root.appendingPathComponent("linked")
    try f.git(["worktree", "add", "-b", "linked-branch", linked.path])
    let project = try await GitService().discoverProject(at: linked.path)
    try f.git(["worktree", "remove", linked.path])
    let service = BranchManagementService()
    try await service.fetch(project: project)
    let branches = try await service.list(project: project)
    let remote = try #require(branches.first { $0.reference == "refs/remotes/team/upstream/topic" })
    #expect(remote.remoteURL == f.server.resolvingSymlinksInPath().path)
    let local = try #require(branches.first { $0.reference == "refs/heads/topic" })
    try await service.delete(branch: remote, project: project, force: false)
    #expect(try f.git(["for-each-ref", "--format=%(refname)", remote.reference]).isEmpty)
    #expect(try f.git(["for-each-ref", "--format=%(refname)", "refs/heads/topic"], at: f.server).isEmpty)
    // Losing the upstream GitHub link/tracking ref does not invalidate an otherwise
    // unchanged local branch snapshot from the same mixed deletion batch.
    try await service.delete(branch: local, project: project, force: false)
}

@Test func managementRelativeEndpointCannotResolveToPushOnlyRemoteAlias() async throws {
    let f = try ManagementFixture()
    defer { f.cleanup() }
    try f.publish()
    let intended = f.repository.appendingPathComponent("backup")
    let wrong = f.root.appendingPathComponent("wrong.git")
    try f.git(["clone", "--bare", f.server.path, intended.path])
    try f.git(["clone", "--bare", f.server.path, wrong.path])
    try f.git(["config", "remote.team/upstream.url", "backup"])
    try f.git(["config", "remote.backup.pushurl", wrong.path])
    let branch = try await f.branch("refs/remotes/team/upstream/topic")
    #expect(branch.remoteURL == intended.resolvingSymlinksInPath().path)
    try await BranchManagementService().delete(branch: branch, project: f.project(), force: false)
    #expect(try f.git(["for-each-ref", "--format=%(refname)", "refs/heads/topic"], at: intended).isEmpty)
    #expect(try f.git(["rev-parse", "refs/heads/topic"], at: wrong) == branch.commit)
}

@Test func managementFetchRefreshesDefaultsAndUnknownDefaultsFailClosed() async throws {
    let f = try ManagementFixture()
    defer { f.cleanup() }
    try f.publish("trunk")
    try f.git(["symbolic-ref", "HEAD", "refs/heads/trunk"], at: f.server)
    try f.git(["config", "remote.team/upstream.followRemoteHEAD", "never"])
    let service = BranchManagementService()
    try await service.fetch(project: f.project())
    #expect(try f.git(["symbolic-ref", "refs/remotes/team/upstream/HEAD"]) == "refs/remotes/team/upstream/trunk")
    #expect(try await f.branch("refs/remotes/team/upstream/trunk").protectedReason == "Remote default branch.")
    #expect(try await f.branch("refs/heads/trunk").protectedReason == "Tracks the remote default branch.")

    try f.git(["symbolic-ref", "HEAD", "refs/heads/no-default"], at: f.server)
    await #expect(throws: (any Error).self) { try await service.fetch(project: f.project()) }
    #expect(try await f.branch("refs/remotes/team/upstream/trunk").protectedReason?.contains("unknown") == true)
}

@Test func managementRejectsEndpointAndMappingHazards() async throws {
    let f = try ManagementFixture()
    defer { f.cleanup() }
    try f.publish()
    let original = try await f.branch("refs/remotes/team/upstream/topic")
    try f.git(["config", "remote.team/upstream.pushurl", f.root.appendingPathComponent("other.git").path])
    #expect(try await f.branch(original.reference).protectedReason != nil)
    await #expect(throws: (any Error).self) {
        try await BranchManagementService().delete(branch: original, project: f.project(), force: false)
    }
    try f.git(["config", "--unset-all", "remote.team/upstream.pushurl"])
    try f.git(["config", "--add", "remote.team/upstream.pushurl", f.server.path])
    try f.git(["config", "--add", "remote.team/upstream.pushurl", f.server.path])
    #expect(try await f.branch(original.reference).protectedReason != nil)
    try f.git(["config", "--unset-all", "remote.team/upstream.pushurl"])
    try f.git(["config", "--add", "remote.team/upstream.fetch", "+refs/heads/*:refs/remotes/team/upstream/*"])
    #expect(try await f.branch(original.reference).remoteBranchName == nil)
    try f.git(["config", "--replace-all", "remote.team/upstream.fetch", "+refs/heads/*:refs/remotes/team/upstream/*"])
    try f.git(["symbolic-ref", "--delete", "refs/remotes/team/upstream/HEAD"])
    #expect(try await f.branch(original.reference).protectedReason?.contains("unknown") == true)
}

@Test func managementGitHubLinksUseExistingUpstreamAndEncodeBranch() async throws {
    let f = try ManagementFixture()
    defer { f.cleanup() }
    try f.publish("feature/a#b")
    try f.git(["branch", "unpublished"])
    for url in ["https://github.com/example/repo.git", "git@github.com:example/repo.git", "ssh://git@github.com/example/repo.git"] {
        try f.git(["config", "remote.team/upstream.url", url])
        let local = try await f.branch("refs/heads/feature/a#b")
        #expect(local.githubURL?.absoluteString == "https://github.com/example/repo/tree/feature%2Fa%23b")
        #expect(try await f.branch("refs/heads/unpublished").githubURL == nil)
    }
    try f.git(["update-ref", "-d", "refs/remotes/team/upstream/feature/a#b"])
    #expect(try await f.branch("refs/heads/feature/a#b").githubURL == nil)
}

@Test func managementSupportsExactCustomFetchMappingAndExplicitFetch() async throws {
    let f = try ManagementFixture()
    defer { f.cleanup() }
    try f.publish()
    try f.git(["config", "--replace-all", "remote.team/upstream.fetch", "+refs/heads/topic:refs/remotes/custom/nested"])
    try f.git(["config", "--add", "remote.team/upstream.fetch", "+refs/heads/main:refs/remotes/team/upstream/main"])
    try await BranchManagementService().fetch(project: f.project())
    let branch = try await f.branch("refs/remotes/custom/nested")
    #expect(branch.remoteBranchName == "topic")
    #expect(branch.remoteName == "team/upstream")
    try await BranchManagementService().delete(branch: branch, project: f.project(), force: false)
    #expect(try f.git(["for-each-ref", "--format=%(refname)", "refs/heads/topic"], at: f.server).isEmpty)
}

@Test func managementProtectsNonstandardDefaultAndRejectsNewCheckoutOrConfig() async throws {
    let f = try ManagementFixture()
    defer { f.cleanup() }
    try f.publish("trunk")
    try f.git(["symbolic-ref", "refs/remotes/team/upstream/HEAD", "refs/remotes/team/upstream/trunk"])
    #expect(try await f.branch("refs/remotes/team/upstream/trunk").protectedReason == "Remote default branch.")
    try f.git(["branch", "working"])
    let snapshot = try await f.branch("refs/heads/working")
    try f.git(["worktree", "add", f.root.appendingPathComponent("new checkout").path, "working"])
    await #expect(throws: (any Error).self) {
        try await BranchManagementService().delete(branch: snapshot, project: f.project(), force: true)
    }
    try f.git(["branch", "config-change"])
    let beforeConfig = try await f.branch("refs/heads/config-change")
    try f.git(["config", "branch.config-change.description", "Changed while dialog open"])
    await #expect(throws: (any Error).self) {
        try await BranchManagementService().delete(branch: beforeConfig, project: f.project(), force: true)
    }
}

@Test func managementFixtureIgnoresTheDevelopersGitSetup() throws {
    let fixture = try withHostileGitEnvironment { try ManagementFixture() }
    defer { fixture.cleanup() }
    try withHostileGitEnvironment { try fixture.git(["commit", "--allow-empty", "-m", "Second"]) }
    #expect(try fixture.git(["rev-list", "--count", "HEAD"]) == "2")
}
