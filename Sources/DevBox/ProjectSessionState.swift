import DevBoxCore
import Foundation
import Observation
import os

enum StatusTone: Equatable {
    case neutral, clean, changed, conflicted
}

/// Created when a row changes, never from a view's body. No formatter or path
/// manipulation needs to run just because a different row was updated.
struct WorktreePresentation: Equatable {
    let folderName: String
    let path: String
    let branchLabel: String
    let statusText: String
    let statusSymbol: String
    let statusTone: StatusTone
    let sizeText: String
    let sizeDetail: String?
    let sizeHelp: String

    init(row: WorktreeRow, previousRow: WorktreeRow? = nil, previous: WorktreePresentation? = nil) {
        path = row.worktree.path
        if let previous, previous.path == path {
            folderName = previous.folderName
        } else {
            folderName = URL(fileURLWithPath: path).lastPathComponent
        }
        branchLabel = row.worktree.isBare ? "Bare repository" : row.worktree.branch ?? "Detached HEAD"
        statusText = row.statusDescription
        if row.statusError != nil || !row.worktree.exists {
            statusSymbol = "exclamationmark.triangle"
            statusTone = .neutral
        } else if row.worktree.isBare {
            statusSymbol = "minus.circle"
            statusTone = .neutral
        } else if let status = row.status {
            statusSymbol = status.conflicted > 0 ? "exclamationmark.circle"
                : status.isClean ? "checkmark.circle" : "circle.lefthalf.filled"
            statusTone = status.conflicted > 0 ? .conflicted : status.isClean ? .clean : .changed
        } else {
            statusSymbol = "ellipsis"
            statusTone = .neutral
        }
        if let previousRow, let previous, row.hasSameMeasurement(as: previousRow),
           row.worktree == previousRow.worktree {
            sizeText = previous.sizeText
            sizeDetail = previous.sizeDetail
            sizeHelp = previous.sizeHelp
            return
        } else if let usage = row.usage {
            sizeText = ByteCountFormatter.string(fromByteCount: usage.bytes, countStyle: .file)
            let suffix = row.sizeState == .queued ? " · queued"
                : row.sizeState == .scanning ? " · updating"
                : row.usageError != nil ? " · update failed"
                : usage.unreadableCount > 0 ? " · partial" : ""
            sizeDetail = "\(usage.fileCount.formatted()) files" + suffix
        } else {
            sizeDetail = nil
            sizeText = !row.worktree.exists || row.worktree.isBare ? "—"
                : row.sizeState == .queued ? "Queued…"
                : row.sizeState == .scanning ? "Scanning…"
                : row.usageError == nil ? "Not measured" : "Unavailable"
        }
        var help = "Exclusive allocated disk usage, including ignored files. Shared Git storage and registered nested worktrees are excluded. APFS sharing means actual space recovered may differ."
        if let date = row.measuredAt { help += "\nLast measured \(date.formatted(date: .abbreviated, time: .standard))." }
        if let usage = row.usage, usage.unreadableCount > 0 { help += "\n\(usage.unreadableCount) entries could not be read." }
        if let error = row.usageError { help += "\nRefresh failed: \(error)" }
        sizeHelp = help
    }
}

@MainActor @Observable
final class WorktreeState: Identifiable {
    let id: String
    private(set) var row: WorktreeRow
    private(set) var presentation: WorktreePresentation
    private(set) var lifecycle: BranchLifecycle?
    private(set) var targetLabel = "main checkout"
    private(set) var branchLoading = false
    private(set) var branchError: String?

    init(row: WorktreeRow) {
        id = row.id
        self.row = row
        presentation = WorktreePresentation(row: row)
    }

    func update(_ mutation: (inout WorktreeRow) -> Void) {
        var next = row
        mutation(&next)
        guard !row.hasSameValues(as: next) else { return }
        let rendered = WorktreePresentation(row: next, previousRow: row, previous: presentation)
        row = next
        if presentation != rendered { presentation = rendered }
    }

    func updateBranches(_ overview: ProjectOverview) {
        let next = overview.branches?.byWorktreeID[id]
        if lifecycle?.mergeState != next?.mergeState || lifecycle?.upstreamGone != next?.upstreamGone
            || lifecycle?.detail != next?.detail { lifecycle = next }
        let label = overview.branches?.targetLabel ?? "main checkout"
        if targetLabel != label { targetLabel = label }
        if branchLoading != overview.isLoadingBranches { branchLoading = overview.isLoadingBranches }
        let error = overview.branchError ?? overview.branches?.warning
        if branchError != error { branchError = error }
    }
}

/// The session cache owns this object. The selected project and sidebar share its
/// identity, not duplicate arrays that copy-on-write on every result.
@MainActor @Observable
final class ProjectSessionState {
    let branchList = BranchListState()
    private(set) var rows: [WorktreeState] = []
    // Publish sort/filter values only when they change. Hosted cells continue
    // observing their stable state references for measurement details and errors.
    private(set) var tableRows: [WorktreeListRow] = []
    private(set) var filterCounts = WorktreeFilterCounts()
    var filter: WorktreeFilter = .all {
        didSet { if filter != oldValue { refreshTableRows() } }
    }
    var sortOrder = [WorktreeSort(column: .name)] {
        didSet { if sortOrder != oldValue { refreshTableRows() } }
    }
    private(set) var overview = ProjectOverview()
    private(set) var summary = ProjectSizeSummary(rows: [WorktreeRow](), overview: ProjectOverview())
    private(set) var sizePresentation = ProjectSizePresentation(
        summary: ProjectSizeSummary(rows: [WorktreeRow](), overview: ProjectOverview()), overview: ProjectOverview()
    )
    private(set) var branchPresentation = BranchPickerPresentation(overview: ProjectOverview())
    private(set) var sizeProgressText = ""
    private(set) var isMeasuringSizes = false
    private(set) var hasLoadedInventory = false
    @ObservationIgnored private var byID: [String: WorktreeState] = [:]
    @ObservationIgnored private var batchDepth = 0
    @ObservationIgnored private var summaryDirty = false
    @ObservationIgnored private var tableDirty = false
    @ObservationIgnored private let signposter = OSSignposter(subsystem: "app.devbox.DevBox", category: "Project state")

    var snapshots: [WorktreeRow] { rows.map(\.row) }
    func row(id: String) -> WorktreeState? {
        // Observe collection membership, not every row's mutable data.
        _ = rows
        return byID[id]
    }

    func reconcile(_ records: [WorktreeRecord], refresh: Bool) {
        let interval = signposter.beginInterval("Reconcile inventory")
        defer { signposter.endInterval("Reconcile inventory", interval) }
        var next: [WorktreeState] = []
        var lookup: [String: WorktreeState] = [:]
        for record in records {
            let state: WorktreeState
            if let existing = byID[record.id] {
                state = existing
                existing.update { old in
                    var row = WorktreeRow(worktree: record)
                    let sameBoundary = old.worktree.nestedWorktreePaths == record.nestedWorktreePaths
                    if sameBoundary && record.exists && !record.isBare {
                        row.usage = old.usage
                        row.measuredAt = old.measuredAt
                    }
                    let sameCommit = old.worktree.head == record.head && old.worktree.branch == record.branch
                    if sameCommit && record.exists && !record.isBare {
                        row.status = old.status
                        row.statusError = refresh ? nil : old.statusError
                    }
                    row.statusRefreshPending = refresh && record.exists && !record.isBare
                        || (!refresh && old.statusRefreshPending)
                    if !refresh && sameBoundary {
                        row.usageError = old.usageError
                        row.sizeRefreshPending = old.sizeRefreshPending
                    }
                    old = row
                }
            } else {
                state = WorktreeState(row: WorktreeRow(worktree: record))
                state.updateBranches(overview)
            }
            next.append(state)
            lookup[record.id] = state
        }
        byID = lookup
        if rows.map(\.id) != next.map(\.id) { rows = next }
        if !hasLoadedInventory { hasLoadedInventory = true }
        refreshSummary()
        refreshTableRows()
    }

    func invalidateInventory() { hasLoadedInventory = false }

    /// Apply confirmed deletions to the snapshot without scheduling any fresh I/O.
    func removeConfirmedWorktrees(ids: Set<String>) {
        let removed = rows.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return }
        let paths = Set(removed.map { $0.row.worktree.canonicalPath })
        for state in removed { byID.removeValue(forKey: state.id) }
        rows.removeAll { ids.contains($0.id) }
        for state in rows {
            state.update {
                // Removing a nested checkout does not change its parent's exclusive
                // measurement: that subtree was already excluded from the cached size.
                $0.worktree = $0.worktree.removingNestedWorktrees(at: paths)
            }
        }
        // Shared Git storage, status, branch snapshots, errors and timestamps remain
        // last-known values until Refresh. Recompute rather than blindly subtract:
        // missing/partial measurements and overflow must still be represented correctly.
        refreshSummary()
        refreshTableRows()
    }

    func pauseScans() {
        performBatchUpdates {
            for state in rows where state.row.isSizeBusy {
                updateRow(state.id) {
                    $0.sizeState = .idle
                    $0.sizeRefreshPending = true
                }
            }
            updateOverview {
                if $0.gitSizeState != .idle {
                    $0.gitSizeState = .idle
                    $0.gitRefreshPending = true
                }
                $0.isLoadingBranches = false
            }
        }
    }

    func updateRow(_ id: String, _ mutation: (inout WorktreeRow) -> Void) {
        guard let state = byID[id] else { return }
        let before = state.row
        let sortValues = WorktreeListRow(state)
        state.update(mutation)
        if !before.hasSameMeasurement(as: state.row) { refreshSummary() }
        if WorktreeListRow(state) != sortValues { refreshTableRows() }
    }

    func updateOverview(_ mutation: (inout ProjectOverview) -> Void) {
        let before = overview
        mutation(&overview)
        // Branch changes affect each row's merge cell, not its status/size content.
        if before.isLoadingBranches != overview.isLoadingBranches
            || before.branchError != overview.branchError
            || before.branches != overview.branches {
            let next = BranchPickerPresentation(overview: overview, previous: branchPresentation)
            if branchPresentation != next { branchPresentation = next }
            for state in rows { state.updateBranches(overview) }
            refreshTableRows()
        }
        if !before.hasSameMeasurement(as: overview) { refreshSummary() }
    }

    func performBatchUpdates(_ update: () -> Void) {
        batchDepth += 1
        defer {
            batchDepth -= 1
            if batchDepth == 0 && summaryDirty {
                summaryDirty = false
                refreshSummary()
            }
            if batchDepth == 0 && tableDirty {
                tableDirty = false
                refreshTableRows()
            }
        }
        update()
    }

    func refreshPresentation() {
        for state in rows {
            // Force only formatting refresh when locale changes, not a disk scan.
            state.refreshPresentation()
        }
        sizePresentation = ProjectSizePresentation(summary: summary, overview: overview)
        refreshTableRows()
    }

    private func refreshTableRows() {
        guard batchDepth == 0 else { tableDirty = true; return }
        let counts = WorktreeFilterCounts(
            all: rows.count,
            changed: rows.filter { $0.matches(.changed) }.count,
            merged: rows.filter { $0.matches(.merged) }.count
        )
        if counts != filterCounts { filterCounts = counts }
        let next = rows.filter { $0.matches(filter) }.map(WorktreeListRow.init).sorted {
            WorktreeSort.precedes($0, $1, using: sortOrder)
        }
        if tableRows != next { tableRows = next }
    }

    private func refreshSummary() {
        guard batchDepth == 0 else { summaryDirty = true; return }
        let interval = signposter.beginInterval("Update size summary")
        defer { signposter.endInterval("Update size summary", interval) }
        let next = ProjectSizeSummary(rows: rows.lazy.map(\.row), overview: overview)
        if summary != next { summary = next }
        let rendered = ProjectSizePresentation(summary: next, overview: overview)
        if sizePresentation != rendered { sizePresentation = rendered }
        let scanning = rows.lazy.filter { $0.row.sizeState == .scanning }.count
        let queued = rows.lazy.filter { $0.row.sizeState == .queued }.count
        let busy = scanning + queued > 0 || overview.gitSizeState != .idle
        if isMeasuringSizes != busy { isMeasuringSizes = busy }
        let text: String
        if scanning + queued == 0 {
            text = overview.gitSizeState == .queued ? "Git storage queued"
                : overview.gitSizeState == .scanning ? "Measuring Git storage…" : ""
        } else {
            text = scanning == 0 ? "\(queued) size scans queued"
                : "Measuring \(scanning) worktree\(scanning == 1 ? "" : "s")"
                    + (queued > 0 ? " · \(queued) queued" : "")
        }
        if sizeProgressText != text { sizeProgressText = text }
    }
}

private extension WorktreeState {
    func refreshPresentation() {
        let rendered = WorktreePresentation(row: row)
        if presentation != rendered { presentation = rendered }
    }
}

extension WorktreeRow {
    func hasSameValues(as other: WorktreeRow) -> Bool {
        worktree == other.worktree && hasSameMeasurement(as: other)
            && statusError == other.statusError && statusRefreshPending == other.statusRefreshPending
            && status?.staged == other.status?.staged
            && status?.modified == other.status?.modified
            && status?.untracked == other.status?.untracked
            && status?.conflicted == other.status?.conflicted
    }

    func hasSameMeasurement(as other: WorktreeRow) -> Bool {
        worktree.exists == other.worktree.exists && worktree.isBare == other.worktree.isBare
            && usage?.bytes == other.usage?.bytes && usage?.fileCount == other.usage?.fileCount
            && usage?.unreadableCount == other.usage?.unreadableCount
            && usageError == other.usageError && measuredAt == other.measuredAt
            && sizeState == other.sizeState && sizeRefreshPending == other.sizeRefreshPending
    }
}

private extension ProjectOverview {
    func hasSameMeasurement(as other: ProjectOverview) -> Bool {
        gitUsage?.bytes == other.gitUsage?.bytes && gitUsage?.fileCount == other.gitUsage?.fileCount
            && gitUsage?.unreadableCount == other.gitUsage?.unreadableCount
            && gitUsageError == other.gitUsageError && gitMeasuredAt == other.gitMeasuredAt
            && gitSizeState == other.gitSizeState && gitRefreshPending == other.gitRefreshPending
    }
}
