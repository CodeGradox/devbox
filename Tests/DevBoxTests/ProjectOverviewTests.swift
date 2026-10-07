import Observation
import Foundation
import Testing
@testable import DevBox
@testable import DevBoxCore

struct ProjectOverviewTests {
    private func row(
        _ path: String = "/test/main", bytes: Int64? = nil,
        bare: Bool = false, exists: Bool = true, unreadable: Int = 0
    ) -> WorktreeRow {
        var row = WorktreeRow(worktree: WorktreeRecord(
            path: path, branch: "main", head: "", isMain: true,
            isBare: bare, exists: exists
        ))
        row.usage = bytes.map { DiskUsage(bytes: $0, fileCount: 1, unreadableCount: unreadable) }
        return row
    }

    private func overview(bytes: Int64 = 30, unreadable: Int = 0) -> ProjectOverview {
        var overview = ProjectOverview()
        overview.gitUsage = DiskUsage(bytes: bytes, fileCount: 1, unreadableCount: unreadable)
        return overview
    }

    @Test
    func exclusiveCheckoutMeasurementsPlusGitStorageOnce() {
        let summary = ProjectSizeSummary(
            rows: [row(bytes: 100), row("/test/main/nested", bytes: 20)],
            overview: overview()
        )
        #expect(summary.worktreeBytes == 120)
        #expect(summary.gitBytes == 30)
        #expect(summary.totalBytes == 150)
        #expect(summary.measuredWorktrees == 2)
        #expect(summary.expectedWorktrees == 2)
        #expect(summary.state == .complete)
        #expect(!summary.overflow)
    }

    @Test
    func bareRepositoryContributesOnlyGitStorage() {
        // Even a stale measurement attached to the bare row is not checkout data.
        let summary = ProjectSizeSummary(rows: [row(bytes: 900, bare: true)], overview: overview())
        #expect(summary.worktreeBytes == 0)
        #expect(summary.gitBytes == 30)
        #expect(summary.totalBytes == 30)
        #expect(summary.expectedWorktrees == 0)
        #expect(summary.measuredWorktrees == 0)
        #expect(summary.state == .complete)
    }

    @Test
    func absentMeasurementsAreNotZero() {
        let summary = ProjectSizeSummary(rows: [row()], overview: ProjectOverview())
        #expect(summary.worktreeBytes == nil)
        #expect(summary.gitBytes == nil)
        #expect(summary.totalBytes == nil)
        #expect(summary.measuredWorktrees == 0)
        #expect(summary.expectedWorktrees == 1)
        #expect(summary.state == .partial)

        let zero = ProjectSizeSummary(rows: [row(bytes: 0)], overview: overview(bytes: 0))
        #expect(zero.totalBytes == 0)
        #expect(zero.state == .complete)
    }

    @Test
    func availableMeasurementsRemainVisibleInPartialTotal() {
        let missingCheckout = ProjectSizeSummary(rows: [row()], overview: overview())
        #expect(missingCheckout.worktreeBytes == nil)
        #expect(missingCheckout.totalBytes == 30)
        #expect(missingCheckout.state == .partial)
        let missingGit = ProjectSizeSummary(rows: [row(bytes: 100)], overview: ProjectOverview())
        #expect(missingGit.gitBytes == nil)
        #expect(missingGit.totalBytes == 100)
        #expect(missingGit.state == .partial)
    }

    @Test(arguments: ["missing", "error", "unreadable", "refresh-pending", "unmeasured"])
    func incompleteCheckoutNeverReportsComplete(reason: String) {
        var checkout = row(bytes: 100)
        switch reason {
        case "missing": checkout = row(bytes: 100, exists: false)
        case "error": checkout.usageError = "Refresh failed"
        case "unreadable": checkout = row(bytes: 100, unreadable: 1)
        case "refresh-pending": checkout.sizeRefreshPending = true
        default: checkout.usage = nil
        }
        let summary = ProjectSizeSummary(rows: [checkout], overview: overview())
        #expect(summary.state == .partial)
        #expect(summary.expectedWorktrees == 1)
        #expect(summary.measuredWorktrees == (reason == "unmeasured" ? 0 : 1))
        #expect(summary.totalBytes == (reason == "unmeasured" ? 30 : 130))
    }

    @Test(arguments: ["error", "unreadable", "refresh-pending"])
    func incompleteGitMeasurementNeverReportsComplete(reason: String) {
        var metadata = overview()
        switch reason {
        case "error": metadata.gitUsageError = "Metadata refresh failed"
        case "unreadable": metadata = overview(unreadable: 1)
        default: metadata.gitRefreshPending = true
        }
        let summary = ProjectSizeSummary(rows: [row(bytes: 100)], overview: metadata)
        #expect(summary.totalBytes == 130)
        #expect(summary.state == .partial)
    }

    @Test(arguments: [SizeScanState.queued, .scanning])
    func busyMeasurementsKeepPreviousTotalButMarkCalculating(state: SizeScanState) {
        var checkout = row(bytes: 100)
        checkout.sizeState = state
        #expect(ProjectSizeSummary(rows: [checkout], overview: overview()).state == .calculating)

        var metadata = overview()
        metadata.gitSizeState = state
        let summary = ProjectSizeSummary(rows: [row(bytes: 100)], overview: metadata)
        #expect(summary.totalBytes == 130)
        #expect(summary.state == .calculating)
        metadata.gitSizeState = .idle
        #expect(ProjectSizeSummary(rows: [row(bytes: 100)], overview: metadata).state == .complete)
    }

    @Test(arguments: [false, true])
    func overflowingTotalsAreUnavailable(overflowCheckouts: Bool) {
        let rows = overflowCheckouts
            ? [row(bytes: Int64.max), row("/test/other", bytes: 1)]
            : [row(bytes: Int64.max)]
        let summary = ProjectSizeSummary(rows: rows, overview: overview(bytes: 1))
        #expect(summary.overflow)
        #expect(summary.totalBytes == nil)
        #expect(summary.worktreeBytes == (overflowCheckouts ? nil : Int64.max))
        #expect(summary.state == .partial)
    }

    @Test
    func overviewRetriesInterruptedWorkButCachesCompletedAndFailedMeasurements() {
        var value = ProjectOverview()
        #expect(value.needsBranchLoad)
        #expect(value.needsGitSizeLoad)
        value.branchError = "Inspection failed"
        value.gitUsageError = "Scan failed"
        #expect(!value.needsBranchLoad)
        #expect(!value.needsGitSizeLoad)
        value.gitRefreshPending = true
        #expect(value.needsGitSizeLoad)
        value = overview()
        value.branches = BranchInspection(targetLabel: "main")
        #expect(!value.needsBranchLoad)
        #expect(!value.needsGitSizeLoad)
        value.gitSizeState = .scanning
        #expect(value.needsGitSizeLoad)
    }
}

@MainActor
private final class OverviewSettings: SettingsPersisting {
    var value = AppSettings()
    func load() throws -> AppSettings { value }
    func save(_ settings: AppSettings) throws { value = settings }
}

@MainActor
private final class OverviewCredentials: CredentialsPersisting {
    func password(for id: UUID) throws -> String? { nil }
    func save(password: String, for id: UUID) throws {}
    func remove(for id: UUID) throws {}
}

private actor OverviewProbe {
    private var calls: [String: Int] = [:]
    func count(_ key: String) -> Int { calls[key, default: 0] }

    func usage(_ key: String) -> DiskUsage {
        calls[key, default: 0] += 1
        return DiskUsage(bytes: Int64(calls[key, default: 0] * 4096), fileCount: 1, unreadableCount: 0)
    }

    func inspect(_ project: ProjectRecord) -> BranchInspection {
        calls["branches:" + project.id, default: 0] += 1
        return BranchInspection(
            targetLabel: project.mergeTarget ?? "Automatic",
            targetReference: project.mergeTarget,
            availableTargets: [BranchTarget(reference: "refs/heads/main", label: "main")]
        )
    }
}

@MainActor
private func waitForOverviewLoad(_ store: AppStore) async {
    for await refreshing in Observations({ store.isRefreshing }) {
        if !refreshing { break }
    }
    for await rows in Observations({ store.worktrees }) {
        if !rows.isEmpty && rows.allSatisfy({ !$0.isSizeBusy && $0.measuredAt != nil }) { break }
    }
    for await overview in Observations({ store.projectOverview }) {
        if !overview.isLoadingBranches && overview.branches != nil
            && overview.gitSizeState == .idle && overview.gitMeasuredAt != nil { return }
    }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func projectOverviewCachesMetadataChangesOnlyBranchTargetAndRefreshesAllMeasurements() async throws {
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = projectRoot.appendingPathComponent(".build/test-temp/project-overview-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var projects: [ProjectRecord] = []
    for name in ["a", "b"] {
        let repository = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        for arguments in [
            ["init", "-b", "main"],
            ["-c", "user.name=Tests", "-c", "user.email=tests@example.invalid",
             "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "Initial"]
        ] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", repository.path, "-c", "core.hooksPath=/dev/null"] + arguments
            process.environment = GitService.environment(from: ProcessInfo.processInfo.environment)
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            try #require(process.terminationStatus == 0)
        }
        projects.append(try await GitService().discoverProject(at: repository.path))
    }
    let a = projects[0]
    let b = projects[1]
    let persistence = OverviewSettings()
    persistence.value.projects = projects
    let probe = OverviewProbe()
    func makeStore() -> AppStore {
        AppStore(
            persistence: persistence, credentials: OverviewCredentials(),
            sizeQueue: WorktreeSizeQueue(
                scan: { await probe.usage("checkout:" + $0.id) },
                gitStorageScan: { await probe.usage("git:" + $0.id) }
            ),
            inspectBranches: { project, _ in await probe.inspect(project) },
            editorLauncher: inertEditorLauncher()
        )
    }
    let store = makeStore()
    store.loadSelection()
    await waitForOverviewLoad(store)
    let original = store.projectOverview
    let checkout = try #require(store.worktrees.first)
    #expect(store.projectSizeSummary.state == .complete)
    #expect(store.projectSizeSummary.totalBytes == 8192)
    store.destination = .project(b.id)
    await waitForOverviewLoad(store)
    store.destination = .project(a.id)
    await waitForOverviewLoad(store)
    #expect(store.projectOverview.gitMeasuredAt == original.gitMeasuredAt)
    #expect(store.projectOverview.gitUsage?.bytes == original.gitUsage?.bytes)
    #expect(await probe.count("git:" + a.id) == 1)
    #expect(await probe.count("branches:" + a.id) == 1)

    store.changeMergeTarget("refs/heads/main")
    await waitForOverviewLoad(store)
    #expect(persistence.value.projects.first?.mergeTarget == "refs/heads/main")
    #expect(store.projectOverview.branches?.targetReference == "refs/heads/main")
    #expect(await probe.count("branches:" + a.id) == 2)
    #expect(await probe.count("git:" + a.id) == 1)
    #expect(await probe.count("checkout:" + checkout.id) == 1)
    #expect(store.projectOverview.gitMeasuredAt == original.gitMeasuredAt)
    #expect(store.worktrees.first?.measuredAt == checkout.measuredAt)

    store.changeMergeTarget(nil)
    await waitForOverviewLoad(store)
    #expect(persistence.value.projects.first?.mergeTarget == nil)
    #expect(store.projectOverview.branches?.targetReference == nil)
    #expect(await probe.count("branches:" + a.id) == 3)
    #expect(await probe.count("git:" + a.id) == 1)
    #expect(await probe.count("checkout:" + checkout.id) == 1)

    store.refresh()
    await waitForOverviewLoad(store)
    #expect(await probe.count("git:" + a.id) == 2)
    #expect(await probe.count("checkout:" + checkout.id) == 2)
    #expect(store.projectOverview.gitUsage?.bytes == 8192)
    #expect(store.projectSizeSummary.totalBytes == 16384)

    let reopened = makeStore()
    reopened.loadSelection()
    await waitForOverviewLoad(reopened)
    #expect(await probe.count("git:" + a.id) == 3)
    #expect(await probe.count("checkout:" + checkout.id) == 3)
    #expect(reopened.projectOverview.gitUsage?.bytes == 12288)
}
