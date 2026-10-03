import DevBoxCore
import Foundation

struct ProjectOverview {
    var branches: BranchInspection?
    var branchError: String?
    var isLoadingBranches = false
    var gitUsage: DiskUsage?
    var gitUsageError: String?
    var gitMeasuredAt: Date?
    var gitSizeState: SizeScanState = .idle
    var gitRefreshPending = false

    var needsBranchLoad: Bool { branches == nil && branchError == nil }
    var needsGitSizeLoad: Bool {
        gitRefreshPending || gitSizeState != .idle || (gitUsage == nil && gitUsageError == nil)
    }
}

/// A total is complete only when every contributing measurement is available.
/// Missing, failed, or paused measurements must never masquerade as zero bytes.
struct ProjectSizeSummary: Equatable {
    enum State {
        case calculating
        case partial
        case complete
    }

    let worktreeBytes: Int64?
    let gitBytes: Int64?
    let totalBytes: Int64?
    let measuredWorktrees: Int
    let expectedWorktrees: Int
    let state: State
    let overflow: Bool

    init(rows: some Sequence<WorktreeRow>, overview: ProjectOverview) {
        var expected = 0
        var measured = 0
        var overflow = false
        var bytes: Int64 = 0
        var busy = overview.gitSizeState != .idle
        var incomplete = overview.gitUsage == nil || overview.gitUsageError != nil
            || overview.gitRefreshPending || (overview.gitUsage?.unreadableCount ?? 0) > 0
        for row in rows {
            busy = busy || row.isSizeBusy
            guard !row.worktree.isBare else { continue }
            expected += 1
            if let usage = row.usage {
                measured += 1
                let sum = bytes.addingReportingOverflow(usage.bytes)
                overflow = overflow || sum.overflow
                bytes = sum.partialValue
            }
            incomplete = incomplete || row.usage == nil || row.usageError != nil
                || row.sizeRefreshPending || (row.usage?.unreadableCount ?? 0) > 0
                || !row.worktree.exists
        }
        expectedWorktrees = expected
        measuredWorktrees = measured
        worktreeBytes = !overflow && (measured > 0 || expected == 0) ? bytes : nil
        gitBytes = overview.gitUsage?.bytes
        let sum = bytes.addingReportingOverflow(gitBytes ?? 0)
        overflow = overflow || sum.overflow
        self.overflow = overflow
        totalBytes = !overflow && (measuredWorktrees > 0 || gitBytes != nil) ? sum.partialValue : nil

        state = overflow ? .partial : (busy ? .calculating : (incomplete ? .partial : .complete))
    }
}
