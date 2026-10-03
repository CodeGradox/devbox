import DevBoxCore
import Foundation

struct BranchPickerPresentation: Equatable {
    struct Option: Equatable, Identifiable {
        var id: String { reference }
        let reference: String
        let label: String
    }
    let targetLabel: String?
    let options: [Option]
    let references: Set<String>
    let isLoading: Bool
    let warning: String?

    init(overview: ProjectOverview, previous: BranchPickerPresentation? = nil) {
        targetLabel = overview.branches?.targetLabel
        if overview.isLoadingBranches, overview.branches == nil, let previous {
            options = previous.options
            references = previous.references
        } else {
            options = (overview.branches?.availableTargets ?? []).map {
                Option(reference: $0.reference, label: $0.reference.hasPrefix("refs/remotes/")
                       ? "\($0.label) (remote)" : $0.label)
            }
            references = Set(options.map(\.reference))
        }
        isLoading = overview.isLoadingBranches
        warning = overview.branchError ?? overview.branches?.warning
    }
}

struct ProjectSizePresentation: Equatable {
    let totalLabel: String
    let sidebarTotal: String?
    let breakdown: String
    let measured: String
    let help: String
    let state: ProjectSizeSummary.State

    init(summary: ProjectSizeSummary, overview: ProjectOverview) {
        func bytes(_ value: Int64?) -> String {
            value.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Pending"
        }
        state = summary.state
        sidebarTotal = summary.totalBytes.map { bytes($0) }
        if summary.overflow {
            totalLabel = "Size unavailable"
        } else if let total = sidebarTotal {
            totalLabel = total + (state == .complete ? " total" : state == .calculating ? " · updating" : " · partial")
        } else {
            totalLabel = state == .calculating ? "Calculating…" : "Size unavailable"
        }
        breakdown = "\(bytes(summary.worktreeBytes)) worktrees · \(bytes(summary.gitBytes)) Git"
        measured = "\(summary.measuredWorktrees)/\(summary.expectedWorktrees) worktrees measured"
        var text = "Exclusive worktree sizes plus shared Git storage once. Nested registered worktree roots are excluded from their parent’s measurement."
        if state != .complete {
            text += "\nThis is not a complete fresh total: measurements are pending, unavailable, partial, or being refreshed."
        }
        if let date = overview.gitMeasuredAt { text += "\nGit storage measured \(date.formatted())." }
        if let error = overview.gitUsageError { text += "\nGit storage: \(error)" }
        help = text + "\nAllocated bytes are not a guarantee of reclaimable APFS space."
    }
}
