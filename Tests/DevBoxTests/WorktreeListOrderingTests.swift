import Foundation
import Observation
import Synchronization
import Testing
@testable import DevBox
@testable import DevBoxCore

private final class TableInvalidations: Sendable {
    private let storage = Mutex(0)
    var value: Int { storage.withLock { $0 } }
    func increment() { storage.withLock { $0 += 1 } }
}

@MainActor
struct WorktreeListOrderingTests {
    private func record(_ name: String, branch: String? = nil) -> WorktreeRecord {
        WorktreeRecord(path: "/ordering/\(name)", branch: branch ?? name, head: "abc", isMain: false)
    }

    private func status(_ count: Int) -> GitStatus {
        GitStatus(staged: count, modified: 0, untracked: 0, conflicted: 0)
    }

    private func usage(_ bytes: Int64) -> DiskUsage {
        DiskUsage(bytes: bytes, fileCount: 1, unreadableCount: 0)
    }

    private func inspection(_ states: [(String, BranchMergeState)]) -> BranchInspection {
        BranchInspection(targetLabel: "main", byWorktreeID: Dictionary(uniqueKeysWithValues: states.map {
            ($0.0, BranchLifecycle(mergeState: $0.1, upstreamGone: false, detail: nil))
        }))
    }

    @Test(arguments: [WorktreeSort.Column.name, .branch, .changes, .merged, .size],
          [SortOrder.forward, .reverse])
    func allColumnsRespectDirection(column: WorktreeSort.Column, order: SortOrder) {
        let session = ProjectSessionState()
        let low = record("tree2", branch: "branch2")
        let high = record("tree10", branch: "branch10")
        session.reconcile([high, low], refresh: false)
        session.updateRow(low.id) { $0.status = status(1); $0.usage = usage(100) }
        session.updateRow(high.id) { $0.status = status(3); $0.usage = usage(300) }
        session.updateOverview { $0.branches = inspection([(low.id, .base), (high.id, .notMerged)]) }

        session.sortOrder = [WorktreeSort(column: column, order: order)]

        #expect(session.tableRows.map(\.id) == (order == .forward ? [low.id, high.id] : [high.id, low.id]))
        // Sorting is a projection, not a mutation of inventory order.
        #expect(session.rows.map(\.id) == [high.id, low.id])
    }

    @Test(arguments: [WorktreeSort.Column.changes, .merged, .size], [SortOrder.forward, .reverse])
    func unknownValuesStayAfterKnownZeroInEitherDirection(column: WorktreeSort.Column, order: SortOrder) {
        let session = ProjectSessionState()
        let unknown = record("a-unknown")
        let zero = record("z-zero")
        let positive = record("positive")
        session.reconcile([unknown, positive, zero], refresh: false)
        session.updateRow(zero.id) { $0.status = status(0); $0.usage = usage(0) }
        session.updateRow(positive.id) { $0.status = status(2); $0.usage = usage(2) }
        session.updateOverview { $0.branches = inspection([(zero.id, .base), (positive.id, .merged)]) }
        session.sortOrder = [WorktreeSort(column: column, order: order)]

        let known = order == .forward ? [zero.id, positive.id] : [positive.id, zero.id]
        #expect(session.tableRows.map(\.id) == known + [unknown.id])
    }

    @Test(arguments: ["missing", "bare", "error", "unloaded"])
    func unverifiableChangesAreUnknown(reason: String) {
        var row = WorktreeRow(worktree: WorktreeRecord(
            path: "/ordering/unknown", branch: "topic", head: "abc", isMain: false,
            isBare: reason == "bare", exists: reason != "missing"
        ))
        row.status = reason == "unloaded" ? nil : status(5)
        row.statusError = reason == "error" ? "failed" : nil
        let state = WorktreeState(row: row)
        #expect(state.sortChanges == nil)
        #expect(!state.matches(.changed))
    }

    @Test(arguments: ["unknown", "absent", "loading", "error", "warning"])
    func unverifiableMergeStateIsUnknown(reason: String) {
        let state = WorktreeState(row: WorktreeRow(worktree: record("topic")))
        var overview = ProjectOverview()
        overview.branches = inspection([(state.id, reason == "unknown" ? .unknown : .merged)])
        if reason == "absent" { overview.branches = nil }
        if reason == "loading" { overview.isLoadingBranches = true }
        if reason == "error" { overview.branchError = "failed" }
        if reason == "warning" {
            overview.branches = BranchInspection(
                targetLabel: "main",
                byWorktreeID: [state.id: BranchLifecycle(mergeState: .merged, upstreamGone: false, detail: nil)],
                warning: "incomplete"
            )
        }
        state.updateBranches(overview)
        #expect(state.sortMerge == nil)
        #expect(!state.matches(.merged))
    }

    @Test func sizeSortUsesBytesEvenWhenFormattedLabelsAreIdentical() throws {
        let session = ProjectSessionState()
        let larger = record("a-larger")
        let smaller = record("z-smaller")
        session.reconcile([larger, smaller], refresh: false)
        session.updateRow(larger.id) { $0.usage = usage(1_000_001) }
        session.updateRow(smaller.id) { $0.usage = usage(1_000_000) }
        let first = try #require(session.row(id: larger.id))
        let second = try #require(session.row(id: smaller.id))
        #expect(first.presentation.sizeText == second.presentation.sizeText)
        session.sortOrder = [WorktreeSort(column: .size)]
        #expect(session.tableRows.map(\.id) == [smaller.id, larger.id])
        session.sortOrder = [WorktreeSort(column: .size, order: .reverse)]
        #expect(session.tableRows.map(\.id) == [larger.id, smaller.id])
    }

    @Test func naturalNameFallbackAndIDTiesAreIndependentOfInventoryOrder() {
        let session = ProjectSessionState()
        let first = record("a/topic2", branch: "same")
        let second = record("z/topic2", branch: "same")
        let tenth = record("topic10", branch: "same")
        for inventory in [[tenth, second, first], [first, tenth, second], [second, first, tenth]] {
            session.reconcile(inventory, refresh: false)
            for comparators in [
                [WorktreeSort(column: .branch, order: .reverse)],
                [WorktreeSort(column: .size)],
                []
            ] {
                session.sortOrder = comparators
                #expect(session.tableRows.map(\.id) == [first.id, second.id, tenth.id])
            }
            session.sortOrder = [WorktreeSort(column: .name, order: .reverse)]
            #expect(session.tableRows.map(\.id) == [tenth.id, first.id, second.id])
        }
    }

    @Test func secondaryComparatorBreaksPrimaryTiesBeforeNameFallback() {
        let session = ProjectSessionState()
        let a = record("a", branch: "same")
        let z = record("z", branch: "same")
        session.reconcile([a, z], refresh: false)
        session.updateRow(a.id) { $0.usage = usage(1) }
        session.updateRow(z.id) { $0.usage = usage(2) }
        session.sortOrder = [WorktreeSort(column: .branch), WorktreeSort(column: .size, order: .reverse)]
        #expect(session.tableRows.map(\.id) == [z.id, a.id])
    }

    @Test func filtersCombineWithSortAndCountsCoverEntireInventory() {
        let session = ProjectSessionState()
        let both = record("both")
        let changed = record("changed")
        let merged = record("merged")
        let neither = record("neither")
        session.reconcile([neither, merged, changed, both], refresh: false)
        session.updateRow(both.id) {
            $0.status = GitStatus(staged: 1, modified: 2, untracked: 3, conflicted: 4)
        }
        session.updateRow(changed.id) { $0.status = status(2) }
        session.updateRow(merged.id) { $0.status = status(0) }
        session.updateOverview {
            $0.branches = inspection([(both.id, .merged), (merged.id, .merged), (changed.id, .notMerged)])
        }
        let counts = WorktreeFilterCounts(all: 4, changed: 2, merged: 2)
        #expect(session.filterCounts == counts)
        #expect(session.row(id: both.id)?.sortChanges == 10)

        session.sortOrder = [WorktreeSort(column: .changes, order: .reverse)]
        session.filter = .changed
        #expect(session.tableRows.map(\.id) == [both.id, changed.id])
        #expect(session.filterCounts == counts)
        session.filter = .merged
        #expect(session.tableRows.map(\.id) == [both.id, merged.id])
        #expect(session.filterCounts == counts)
        for filter in WorktreeFilter.allCases {
            session.filter = filter
            #expect(session.tableRows.count == counts[filter])
        }
    }

    @Test func newStatesInheritAnExistingBranchInspection() {
        let session = ProjectSessionState()
        let row = record("merged")
        session.updateOverview { $0.branches = inspection([(row.id, .merged)]) }
        session.reconcile([row], refresh: false)
        session.filter = .merged
        #expect(session.tableRows.map(\.id) == [row.id])
        #expect(session.tableRows.first?.merged == 1)
    }

    @Test func streamedUpdatesReorderProjectionWithoutReplacingStates() {
        let session = ProjectSessionState()
        let a = record("a")
        let b = record("b")
        session.reconcile([a, b], refresh: false)
        let original = session.rows
        session.sortOrder = [WorktreeSort(column: .size)]
        session.updateRow(b.id) { $0.usage = usage(20) }
        #expect(session.tableRows.map(\.id) == [b.id, a.id])
        session.updateRow(a.id) { $0.usage = usage(10) }
        #expect(session.tableRows.map(\.id) == [a.id, b.id])
        session.sortOrder = [WorktreeSort(column: .merged)]
        session.updateOverview { $0.branches = inspection([(a.id, .notMerged), (b.id, .merged)]) }
        #expect(session.tableRows.map(\.id) == [b.id, a.id])
        session.updateOverview { $0.branches = inspection([(a.id, .base), (b.id, .notMerged)]) }
        #expect(session.tableRows.map(\.id) == [a.id, b.id])
        for state in original {
            #expect(session.row(id: state.id) === state)
            #expect(session.tableRows.first { $0.id == state.id }?.state === state)
        }
        #expect(zip(original, session.rows).allSatisfy { $0 === $1 })
    }

    @Test func deletionAndReconciliationRefreshFilteredProjection() throws {
        let session = ProjectSessionState()
        let a = record("a")
        let b = record("b")
        let c = record("c")
        session.reconcile([b, a], refresh: false)
        let retained = try #require(session.row(id: a.id))
        session.updateRow(a.id) { $0.status = status(1) }
        session.updateRow(b.id) { $0.status = status(2) }
        session.filter = .changed
        session.removeConfirmedWorktrees(ids: [b.id])
        #expect(session.tableRows.map(\.id) == [a.id])
        #expect(session.filterCounts == WorktreeFilterCounts(all: 1, changed: 1, merged: 0))
        #expect(session.row(id: b.id) == nil)
        session.reconcile([c, a], refresh: false)
        #expect(session.tableRows.map(\.id) == [a.id])
        #expect(session.filterCounts == WorktreeFilterCounts(all: 2, changed: 1, merged: 0))
        #expect(session.tableRows.first?.state === retained)
        session.filter = .all
        #expect(session.tableRows.map(\.id) == [a.id, c.id])
        session.reconcile([], refresh: false)
        #expect(session.tableRows.isEmpty)
        #expect(session.filterCounts == WorktreeFilterCounts())
    }

    @Test func nestedBatchesDoNotPublishInterimSortValuesOrCounts() {
        let session = ProjectSessionState()
        let a = record("a")
        let b = record("b")
        session.reconcile([a, b], refresh: false)
        session.sortOrder = [WorktreeSort(column: .size)]
        let before = session.tableRows
        let counts = session.filterCounts
        let invalidations = TableInvalidations()
        withObservationTracking {
            _ = session.tableRows
        } onChange: {
            invalidations.increment()
        }
        session.performBatchUpdates {
            session.updateRow(b.id) { $0.usage = usage(20); $0.status = status(1) }
            session.performBatchUpdates {
                session.updateRow(a.id) { $0.usage = usage(30) }
                session.updateOverview { $0.branches = inspection([(b.id, .merged)]) }
            }
            #expect(session.tableRows == before)
            #expect(session.tableRows.allSatisfy { $0.bytes == nil && $0.merged == nil })
            #expect(session.filterCounts == counts)
            #expect(invalidations.value == 0)
        }
        #expect(invalidations.value == 1)
        #expect(session.tableRows.map(\.id) == [b.id, a.id])
        #expect(session.tableRows.map(\.bytes) == [20, 30])
        #expect(session.filterCounts == WorktreeFilterCounts(all: 2, changed: 1, merged: 1))
    }
}
