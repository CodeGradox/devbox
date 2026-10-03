import Foundation
import Observation
import Synchronization
import Testing
@testable import DevBox
@testable import DevBoxCore

// Observation callbacks are Sendable and run on the mutating executor.
// Count logical invalidations, not elapsed time or SwiftUI body evaluations.
private final class InvalidationCounter: Sendable {
    private let storage = Mutex(0)

    var value: Int { storage.withLock { $0 } }
    func increment() { storage.withLock { $0 += 1 } }
}

@MainActor
struct ObservationScopeTests {
    private func records(count: Int = 2) -> [WorktreeRecord] {
        (0..<count).map {
            WorktreeRecord(path: "/observation/worktree-\($0)", branch: "branch-\($0)",
                           head: "", isMain: $0 == 0)
        }
    }

    @Test
    func oneMeasurementInvalidatesOnlyItsRowAmongTwoHundred() throws {
        let session = ProjectSessionState()
        session.reconcile(records(count: 200), refresh: false)
        let rows = session.rows
        let rowChanges = rows.map { _ in InvalidationCounter() }
        let presentationChanges = rows.map { _ in InvalidationCounter() }
        let collectionChanges = InvalidationCounter()
        withObservationTracking {
            _ = session.rows
        } onChange: {
            collectionChanges.increment()
        }
        for (index, row) in rows.enumerated() {
            let rowCounter = rowChanges[index]
            let presentationCounter = presentationChanges[index]
            withObservationTracking {
                _ = row.row
            } onChange: {
                rowCounter.increment()
            }
            withObservationTracking {
                _ = row.presentation
            } onChange: {
                presentationCounter.increment()
            }
        }

        let changed = try #require(rows.first)
        session.updateRow(changed.id) {
            $0.usage = DiskUsage(bytes: 4096, fileCount: 1, unreadableCount: 0)
            $0.measuredAt = Date(timeIntervalSince1970: 100)
        }

        #expect(rowChanges[0].value == 1)
        #expect(presentationChanges[0].value == 1)
        #expect(rowChanges.dropFirst().allSatisfy { $0.value == 0 })
        #expect(presentationChanges.dropFirst().allSatisfy { $0.value == 0 })
        #expect(collectionChanges.value == 0)
        #expect(session.rows.count == 200)
        #expect(zip(rows, session.rows).allSatisfy { $0 === $1 })
        #expect(session.summary.worktreeBytes == 4096)
        #expect(session.summary.measuredWorktrees == 1)
        #expect(session.summary.expectedWorktrees == 200)
    }

    @Test(arguments: [false, true])
    func unchangedInventoryPreservesCollectionAndRowIdentity(refresh: Bool) {
        let session = ProjectSessionState()
        let inventory = records()
        session.reconcile(inventory, refresh: false)
        let original = session.rows
        let changes = InvalidationCounter()
        withObservationTracking {
            _ = session.rows
        } onChange: {
            changes.increment()
        }

        session.reconcile(inventory, refresh: refresh)

        #expect(changes.value == 0)
        #expect(session.rows.count == original.count)
        #expect(zip(original, session.rows).allSatisfy { $0 === $1 })
        for row in original {
            #expect(session.row(id: row.id) === row)
        }
    }

    @Test
    func branchOverviewDoesNotInvalidateTableMembership() {
        let session = ProjectSessionState()
        session.reconcile(records(), refresh: false)
        let changes = InvalidationCounter()
        let overviewChanges = InvalidationCounter()
        let summaryChanges = InvalidationCounter()
        withObservationTracking {
            _ = session.rows
        } onChange: {
            changes.increment()
        }
        withObservationTracking {
            _ = session.summary
        } onChange: {
            summaryChanges.increment()
        }
        withObservationTracking {
            _ = session.overview
        } onChange: {
            overviewChanges.increment()
        }

        session.updateOverview {
            $0.branches = BranchInspection(targetLabel: "main")
        }

        #expect(changes.value == 0)
        #expect(overviewChanges.value == 1)
        #expect(summaryChanges.value == 0)
        #expect(session.overview.branches?.targetLabel == "main")
    }

    @Test
    func statusOnlyUpdateDoesNotInvalidateSizeSummaryOrOtherRows() throws {
        let session = ProjectSessionState()
        session.reconcile(records(), refresh: false)
        let first = try #require(session.rows.first)
        let second = try #require(session.rows.last)
        session.updateRow(first.id) {
            $0.usage = DiskUsage(bytes: 100, fileCount: 1, unreadableCount: 0)
        }
        let summaryChanges = InvalidationCounter()
        let otherRowChanges = InvalidationCounter()
        withObservationTracking {
            _ = session.summary
        } onChange: {
            summaryChanges.increment()
        }
        withObservationTracking {
            _ = second.row
            _ = second.presentation
        } onChange: {
            otherRowChanges.increment()
        }

        session.updateRow(first.id) { $0.statusError = "Status unavailable" }

        #expect(first.row.statusError == "Status unavailable")
        #expect(summaryChanges.value == 0)
        #expect(otherRowChanges.value == 0)
        #expect(session.summary.worktreeBytes == 100)
    }

    @Test
    func sizeUpdatesDoNotInvalidateBranchPickerAndBatchSummaryPublishesOnce() throws {
        let session = ProjectSessionState()
        session.reconcile(records(count: 20), refresh: false)
        session.updateOverview {
            $0.branches = BranchInspection(targetLabel: "main", availableTargets: [
                BranchTarget(reference: "refs/heads/main", label: "main"),
                BranchTarget(reference: "refs/remotes/origin/main", label: "origin/main")
            ])
        }
        let pickerChanges = InvalidationCounter()
        let summaryChanges = InvalidationCounter()
        withObservationTracking {
            _ = session.branchPresentation
        } onChange: {
            pickerChanges.increment()
        }
        withObservationTracking {
            _ = session.summary
        } onChange: {
            summaryChanges.increment()
        }
        let before = session.summary
        session.performBatchUpdates {
            for state in session.rows {
                session.updateRow(state.id) {
                    $0.usage = DiskUsage(bytes: 4096, fileCount: 1, unreadableCount: 0)
                }
            }
            #expect(session.summary == before)
        }
        #expect(summaryChanges.value == 1)
        #expect(pickerChanges.value == 0)
        let expectedBytes: Int64 = 20 * 4096
        #expect(session.summary.worktreeBytes == expectedBytes)
        #expect(session.branchPresentation.options.last?.label == "origin/main (remote)")
        session.updateOverview {
            $0.gitSizeState = .scanning
            $0.gitUsageError = "Test storage warning"
        }
        #expect(pickerChanges.value == 0)
    }

    @Test
    func inventoryReconciliationReusesSurvivorsButInvalidatesChangedSizeBoundary() throws {
        let session = ProjectSessionState()
        let original = records(count: 3)
        session.reconcile(original, refresh: false)
        let retained = try #require(session.row(id: original[0].id))
        let reordered = try #require(session.row(id: original[2].id))
        session.updateRow(retained.id) {
            $0.usage = DiskUsage(bytes: 4096, fileCount: 1, unreadableCount: 0)
        }
        let parent = WorktreeRecord(
            path: original[0].path, branch: original[0].branch, head: "", isMain: true,
            nestedWorktreePaths: ["/observation/worktree-0/child"]
        )
        let child = WorktreeRecord(path: "/observation/worktree-0/child", branch: "child", head: "", isMain: false)
        session.reconcile([original[2], parent, child], refresh: true)
        #expect(session.rows.map(\.id) == [original[2].id, parent.id, child.id])
        #expect(session.rows[0] === reordered)
        #expect(session.rows[1] === retained)
        #expect(session.row(id: original[1].id) == nil)
        #expect(retained.row.usage == nil)
        #expect(retained.row.needsSizeLoad)
        #expect(retained.row.worktree.nestedWorktreePaths == [child.path])
    }

    @Test
    func pausedProjectDoesNotAppearToKeepScanning() throws {
        let session = ProjectSessionState()
        session.reconcile(records(count: 1), refresh: false)
        let state = try #require(session.rows.first)
        session.updateRow(state.id) {
            $0.usage = DiskUsage(bytes: 4096, fileCount: 1, unreadableCount: 0)
            $0.sizeState = .scanning
        }
        session.updateOverview {
            $0.gitUsage = DiskUsage(bytes: 1024, fileCount: 1, unreadableCount: 0)
            $0.gitSizeState = .queued
        }
        session.pauseScans()
        #expect(!session.isMeasuringSizes)
        #expect(state.row.sizeState == .idle)
        #expect(state.row.needsSizeLoad)
        #expect(session.overview.gitSizeState == .idle)
        #expect(session.overview.needsGitSizeLoad)
        #expect(session.summary.totalBytes == 5120)
        #expect(session.summary.state == .partial)
    }

    @Test
    func refreshRetainsStatusAndMarksUnfinishedWorkForResumption() throws {
        let session = ProjectSessionState()
        let inventory = records(count: 1)
        session.reconcile(inventory, refresh: false)
        let state = try #require(session.rows.first)
        session.updateRow(state.id) {
            $0.status = GitStatus(staged: 0, modified: 0, untracked: 0, conflicted: 0)
        }
        session.reconcile(inventory, refresh: true)
        #expect(state.row.status?.isClean == true)
        #expect(state.row.needsStatusLoad)
        #expect(session.rows.first === state)
    }

    @Test
    func summaryTracksMeasurementsAndRefreshStateWithoutChangingMembership() throws {
        let session = ProjectSessionState()
        session.reconcile(records(count: 1), refresh: false)
        let row = try #require(session.rows.first)
        #expect(session.summary.totalBytes == nil)
        session.updateRow(row.id) {
            $0.usage = DiskUsage(bytes: 100, fileCount: 1, unreadableCount: 0)
        }
        session.updateOverview {
            $0.gitUsage = DiskUsage(bytes: 30, fileCount: 1, unreadableCount: 0)
        }
        #expect(session.summary.totalBytes == 130)
        #expect(session.summary.state == .complete)

        let changes = InvalidationCounter()
        withObservationTracking {
            _ = session.summary
        } onChange: {
            changes.increment()
        }
        session.updateRow(row.id) { $0.sizeState = .scanning }
        #expect(changes.value == 1)
        #expect(session.summary.totalBytes == 130)
        #expect(session.summary.state == .calculating)
        session.updateRow(row.id) {
            $0.sizeState = .idle
            $0.usageError = "Scan failed"
        }
        #expect(session.summary.totalBytes == 130)
        #expect(session.summary.state == .partial)
        #expect(session.rows.first === row)
    }
}
