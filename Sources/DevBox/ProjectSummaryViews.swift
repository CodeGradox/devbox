import DevBoxCore
import SwiftUI

/// Explicit inputs keep table-hosted views independent of environment propagation.
struct BranchLifecycleCell: View {
    let lifecycle: BranchLifecycle?
    let targetLabel: String
    let isLoading: Bool
    var error: String?

    var body: some View {
        HStack(spacing: 5) {
            Label(title, systemImage: symbol)
                .foregroundStyle(!isLoading && lifecycle?.mergeState == .merged ? Color.green : Color.secondary)
            if lifecycle?.upstreamGone == true {
                Image(systemName: "arrow.up.right.circle")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Upstream gone")
            }
        }
        .lineLimit(1)
        .help(help)
    }

    private var title: String {
        if isLoading { return "Checking…" }
        guard let lifecycle else { return "Unknown" }
        switch lifecycle.mergeState {
        case .base: return "Base"
        case .merged: return "Merged"
        case .notMerged: return "No"
        case .unknown: return "Unknown"
        }
    }

    private var symbol: String {
        if isLoading { return "ellipsis" }
        switch lifecycle?.mergeState {
        case .base: return "flag"
        case .merged: return "checkmark"
        case .notMerged: return "minus"
        case .unknown, nil: return "questionmark.circle"
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

/// The normal header shows one line; measurement details remain one click away.
struct CompactProjectSizeView: View {
    let session: ProjectSessionState
    @State private var showingDetails = false

    var body: some View {
        Button { showingDetails.toggle() } label: {
            HStack(spacing: 6) {
                Text(session.sizePresentation.totalLabel)
                    .fontWeight(.medium)
                    .monospacedDigit()
                Text("· \(session.rows.count) worktrees")
                    .foregroundStyle(.secondary)
                Image(systemName: "info.circle").foregroundStyle(.secondary)
            }
            .lineLimit(1)
        }
        .buttonStyle(.plain)
        .help(session.sizePresentation.help)
        .accessibilityLabel("Project disk usage: \(session.sizePresentation.totalLabel). Show details.")
        .popover(isPresented: $showingDetails) {
            VStack(alignment: .leading, spacing: 12) {
                ProjectSizeView(summary: session.summary, presentation: session.sizePresentation)
                Text(session.sizePresentation.help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(width: 360)
        }
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
