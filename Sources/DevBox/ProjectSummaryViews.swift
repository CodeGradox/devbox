import DevBoxCore
import SwiftUI

/// Explicit inputs keep table-hosted views independent of environment propagation.
struct BranchLifecycleCell: View {
    let lifecycle: BranchLifecycle?
    let targetLabel: String
    let isLoading: Bool
    var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol)
                .foregroundStyle(lifecycle?.mergeState == .merged ? Color.green : Color.secondary)
            if lifecycle?.upstreamGone == true {
                Label("Upstream gone", systemImage: "arrow.up.right.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .help(help)
    }

    private var title: String {
        guard let lifecycle else { return isLoading ? "Checking…" : "Unknown" }
        switch lifecycle.mergeState {
        case .base: return "Comparison base"
        case .merged: return "Merged"
        case .notMerged: return "Not merged"
        case .unknown: return "Unknown"
        }
    }

    private var symbol: String {
        switch lifecycle?.mergeState {
        case .base: "flag"
        case .merged: "checkmark.circle.fill"
        case .notMerged: "circle"
        case .unknown: "questionmark.circle"
        case nil: isLoading ? "ellipsis" : "questionmark.circle"
        }
    }

    private var help: String {
        var text = "Commit ancestry compared with \(targetLabel). This is independent of uncommitted changes."
        if lifecycle?.upstreamGone == true {
            text += "\nThe configured upstream ref is missing locally. This does not prove a merge or squash merge."
        }
        if let detail = lifecycle?.detail { text += "\n\(detail)" }
        if let error { text += "\n\(error)" }
        return text + "\nRemote information reflects the last fetch; Refresh does not fetch or prune."
    }
}

struct ProjectSizeView: View {
    let summary: ProjectSizeSummary
    var gitError: String?
    var gitMeasuredAt: Date?
    var presentation: ProjectSizePresentation?

    var body: some View {
        let display = presentation ?? fallbackPresentation
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                if summary.state == .calculating { ProgressView().controlSize(.mini) }
                Text(display.totalLabel).font(.headline).monospacedDigit()
            }
            Text(display.breakdown)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(display.measured)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .help(display.help)
    }

    private var fallbackPresentation: ProjectSizePresentation {
        var overview = ProjectOverview()
        overview.gitMeasuredAt = gitMeasuredAt
        overview.gitUsageError = gitError
        return ProjectSizePresentation(summary: summary, overview: overview)
    }
}
