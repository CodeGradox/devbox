import Foundation
import Testing
@testable import DevBox
@testable import DevBoxCore

struct WorktreeCleanupSuggestionTests {
    private func row(
        _ path: String = "/test/topic", protection: String? = nil, dirty: Bool = false
    ) -> WorktreeRow {
        var value = WorktreeRow(worktree: WorktreeRecord(
            path: path, branch: "topic", head: "abc", isMain: protection == "main",
            isBare: protection == "bare", isLocked: protection == "locked",
            exists: protection != "missing",
            nestedWorktreePaths: protection == "nested" ? [path + "/child"] : []
        ))
        value.status = GitStatus(staged: 0, modified: dirty ? 1 : 0, untracked: 0, conflicted: 0)
        return value
    }

    private func overview(
        _ rows: [WorktreeRow], mergeState: BranchMergeState = .merged,
        warning: String? = nil, detail: String? = nil
    ) -> ProjectOverview {
        var value = ProjectOverview()
        value.branches = BranchInspection(
            targetLabel: "main", byWorktreeID: Dictionary(uniqueKeysWithValues: rows.map {
                ($0.id, BranchLifecycle(mergeState: mergeState, upstreamGone: false, detail: detail))
            }), warning: warning
        )
        return value
    }

    private func groups(_ rows: [WorktreeRow]) -> [WorktreeCleanupSuggestion] {
        WorktreeCleanupSuggestion.groups(rows: rows, overview: overview(rows), hasLoadedInventory: true)
    }

    @Test func cleanAndDirtyAreSeparateAndDirtyExplicitlyWarns() throws {
        let clean = row()
        let dirty = row("/test/dirty", dirty: true)
        let suggestions = groups([clean, dirty])
        #expect(suggestions.count == 2)
        #expect(suggestions[0].kind == .clean)
        #expect(suggestions[0].ids == [clean.id])
        #expect(suggestions[1].kind == .changed)
        #expect(suggestions[1].ids == [dirty.id])
        #expect(suggestions[1].title.contains("changes will be lost"))
        #expect(!suggestions[1].title.contains("safe"))
    }

    @Test(arguments: ["main", "bare", "locked", "missing", "nested"])
    func protectedWorktreesAreExcluded(protection: String) {
        #expect(groups([row(protection: protection)]).isEmpty)
    }

    @Test(arguments: ["unknown", "error", "pending"])
    func unverifiableStatusIsExcluded(reason: String) {
        var value = row()
        switch reason {
        case "unknown": value.status = nil
        case "error": value.statusError = "failed"
        default: value.statusRefreshPending = true
        }
        #expect(groups([value]).isEmpty)
    }

    @Test(arguments: [BranchMergeState.base, .notMerged, .unknown])
    func onlyMergedIsEligible(state: BranchMergeState) {
        let rows = [row()]
        #expect(WorktreeCleanupSuggestion.groups(
            rows: rows, overview: overview(rows, mergeState: state), hasLoadedInventory: true
        ).isEmpty)
    }

    @Test(arguments: ["inventory", "missing", "loading", "error", "warning", "detail", "incomplete"])
    func unverifiableInspectionOrInventoryIsExcluded(reason: String) {
        let rows = [row()]
        var metadata = overview(rows)
        switch reason {
        case "missing": metadata.branches = nil
        case "loading": metadata.isLoadingBranches = true
        case "error": metadata.branchError = "failed"
        case "warning": metadata = overview(rows, warning: "incomplete history")
        case "detail": metadata = overview(rows, detail: "unable to verify")
        case "incomplete": metadata = overview([])
        default: break
        }
        #expect(WorktreeCleanupSuggestion.groups(
            rows: rows, overview: metadata, hasLoadedInventory: reason != "inventory"
        ).isEmpty)
    }

    @Test func noDataProducesNoCard() {
        #expect(groups([]).isEmpty)
        #expect(WorktreeCleanupSuggestion.groups(
            rows: [], overview: ProjectOverview(), hasLoadedInventory: false
        ).isEmpty)
    }

    @Test func unmeasuredIsNotZeroAndPartialTotalsRetainKnownBytes() throws {
        var measured = row()
        let unmeasured = row("/test/unmeasured")
        let unknown = try #require(groups([unmeasured]).first)
        #expect(unknown.measuredBytes == nil)
        #expect(unknown.sizeText == "Size not measured")
        measured.usage = DiskUsage(bytes: 4096, fileCount: 1, unreadableCount: 0)
        let partial = try #require(groups([measured, unmeasured]).first)
        #expect(partial.measuredBytes == 4096)
        #expect(partial.isPartial)
        #expect(partial.sizeText.contains("partial"))
        let complete = try #require(groups([measured]).first)
        #expect(!complete.isPartial)
        #expect(complete.sizeText.contains("allocated"))
    }

    @Test(arguments: ["unreadable", "error", "pending", "queued", "scanning"])
    func incompleteMeasurementsAreLabelledPartial(reason: String) throws {
        var value = row()
        value.usage = DiskUsage(bytes: 4096, fileCount: 1, unreadableCount: reason == "unreadable" ? 1 : 0)
        switch reason {
        case "error": value.usageError = "failed"
        case "pending": value.sizeRefreshPending = true
        case "queued": value.sizeState = .queued
        case "scanning": value.sizeState = .scanning
        default: break
        }
        let suggestion = try #require(groups([value]).first)
        #expect(suggestion.measuredBytes == 4096)
        #expect(suggestion.isPartial)
    }

    @Test func overflowDoesNotBecomeZeroOrReclaimEstimate() throws {
        var first = row()
        var second = row("/test/second")
        first.usage = DiskUsage(bytes: .max, fileCount: 1, unreadableCount: 0)
        second.usage = DiskUsage(bytes: 1, fileCount: 1, unreadableCount: 0)
        let suggestion = try #require(groups([first, second]).first)
        #expect(suggestion.overflow)
        #expect(suggestion.measuredBytes == nil)
        #expect(suggestion.sizeText == "Size unavailable · overflow")
    }
}
