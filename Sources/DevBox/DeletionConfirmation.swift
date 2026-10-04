import SwiftUI

struct DeletionConfirmation: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var acknowledged = false
    @State private var forceBranches = false
    let request: DeletionRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: "trash.circle.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title2.weight(.semibold))
                    Text(scope).foregroundStyle(.secondary)
                }
            }
            Text(warning).fixedSize(horizontal: false, vertical: true)
            if let estimate = request.statisticsSummary {
                Text("\(estimate) · Not guaranteed reclaimed space")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch request.items {
                    case .worktrees(_, let rows):
                        ForEach(rows) { row in
                            let entry = store.deletionEntry(for: row.worktree.path, in: request)
                            DeletionItemView(
                                name: row.worktree.branch ?? "Detached HEAD",
                                subtitle: "\(row.worktree.path)\n\(row.statusDescription)",
                                state: entry.state, startedAt: entry.startedAt, elapsed: entry.elapsed
                            )
                            if row.id != rows.last?.id { Divider() }
                        }
                    case .branches(_, let branches):
                        ForEach(branches) { branch in
                            let entry = store.deletionEntry(for: branch.reference, in: request)
                            DeletionItemView(
                                name: branch.name,
                                subtitle: branch.isRemote
                                    ? "Delete from remote \(branch.remoteName ?? "unknown") · \(branch.reference)"
                                    : "Local branch · \(branch.reference)",
                                state: entry.state, startedAt: entry.startedAt, elapsed: entry.elapsed
                            )
                            if branch.id != branches.last?.id { Divider() }
                        }
                    case .databases(_, let databases):
                        ForEach(databases) { database in
                            let entry = store.deletionEntry(for: database.name, in: request)
                            DeletionItemView(
                                name: database.name, state: entry.state,
                                startedAt: entry.startedAt, elapsed: entry.elapsed
                            )
                            if database.id != databases.last?.id { Divider() }
                        }
                    }
                }
                .padding(12)
            }
            .frame(minHeight: 70, maxHeight: 210)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            if store.isDeleting {
                ProgressView(value: Double(finishedCount), total: Double(max(request.count, 1)))
                    .accessibilityLabel("Deletion batch progress")
                DeletionSummary(entries: store.deletionEntries)
            }
            if case .worktrees = request.items {
                Toggle("Delete all contents, including uncommitted changes and ignored files", isOn: $acknowledged)
                    .toggleStyle(.checkbox)
                    .disabled(store.isDeleting)
            } else if case .branches(_, let branches) = request.items {
                if branches.contains(where: \.isRemote) {
                    Toggle("Delete these branches from the remote server for everyone", isOn: $acknowledged)
                        .toggleStyle(.checkbox)
                        .disabled(store.isDeleting)
                }
                if branches.contains(where: { !$0.isRemote }) {
                    Toggle("Force delete local branches even if Git considers them unmerged", isOn: $forceBranches)
                        .toggleStyle(.checkbox)
                        .disabled(store.isDeleting)
                    Text("Off by default. Forcing deletion can make unmerged commits unreachable.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Label(
                store.isDeleting
                    ? "Items are processed one at a time. Uncertain results stop the batch."
                    : "macOS will ask for Touch ID or your Mac login password.",
                systemImage: store.isDeleting ? "list.number" : "touchid"
            )
                .font(.callout)
                .foregroundStyle(.secondary)
            if let error = store.deletionError {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            HStack {
                if store.isDeleting {
                    ProgressView().controlSize(.small)
                    Text(store.progressText.isEmpty ? "Authenticating…" : store.progressText)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(store.isDeleting)
                Button("Authenticate & Delete…", role: .destructive) {
                    Task { await store.delete(request, forceBranches: forceBranches) }
                }
                .disabled(store.isDeleting || needsAcknowledgment)
            }
        }
        .padding(24)
        .frame(width: 560)
        .interactiveDismissDisabled(store.isDeleting)
    }

    private var finishedCount: Int {
        store.deletionEntries.filter {
            switch $0.state {
            case .queued, .deleting: false
            default: true
            }
        }.count
    }

    private var needsAcknowledgment: Bool {
        if case .worktrees = request.items { return !acknowledged }
        if case .branches(_, let branches) = request.items, branches.contains(where: \.isRemote) {
            return !acknowledged
        }
        return false
    }

    private var title: String {
        switch request.items {
        case .worktrees: "Delete \(request.count) Worktree\(request.count == 1 ? "" : "s")?"
        case .branches: "Delete \(request.count) Branch\(request.count == 1 ? "" : "es")?"
        case .databases: "Delete \(request.count) Database\(request.count == 1 ? "" : "s")?"
        }
    }

    private var scope: String {
        switch request.items {
        case .worktrees(let project, _), .branches(let project, _): project.name
        case .databases(let connection, _):
            "\(connection.name) · \(connection.settings.socketPath.isEmpty ? "\(connection.settings.host):\(connection.settings.port)" : connection.settings.socketPath)"
        }
    }

    private var warning: String {
        switch request.items {
        case .worktrees:
            "The selected folders and their Git worktree registrations will be permanently removed. Branches will be kept. This cannot be undone."
        case .branches:
            "Local branches are removed only from this repository. Remote branches are deleted from the server for all collaborators, not just hidden locally. Worktree folders are not removed. No backup will be made."
        case .databases:
            "All tables and data in the selected databases will be permanently deleted. No backup will be made. This cannot be undone."
        }
    }
}

struct OperationResultsView: View {
    @Environment(\.dismiss) private var dismiss
    let result: OperationResult

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(result.title).font(.title2.weight(.semibold))
            DeletionSummary(entries: result.entries)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(result.entries) { entry in
                        DeletionItemView(
                            name: entry.name, state: entry.state,
                            startedAt: entry.startedAt, elapsed: entry.elapsed
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 300)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 540)
    }
}

/// No implicit app state: safe to host in a sheet, table, or rendering test.
struct DeletionItemView: View {
    let name: String
    var subtitle: String?
    let state: DeletionState
    var startedAt: Date?
    var elapsed: TimeInterval?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).fontWeight(.medium).textSelection(.enabled)
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 4) {
                    DeletionStateBadge(state: state)
                    if let elapsed {
                        ElapsedTimeLabel(seconds: elapsed)
                    } else if state == .deleting, let startedAt {
                        // Only this tiny view ticks, not the app store or database table.
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            ElapsedTimeLabel(seconds: max(0, context.date.timeIntervalSince(startedAt)))
                        }
                    }
                }
            }
            if let message = state.detail {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ElapsedTimeLabel: View {
    let seconds: TimeInterval

    var body: some View {
        Text("\(seconds, format: .number.precision(.fractionLength(1))) s")
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .help("Elapsed time for this deletion attempt, including waiting for the server.")
    }
}

struct DeletionStateBadge: View {
    let state: DeletionState

    var body: some View {
        HStack(spacing: 5) {
            if state == .deleting {
                ProgressView().controlSize(.mini).frame(width: 14, height: 14)
            } else {
                Image(systemName: symbol).accessibilityHidden(true)
            }
            Text(state.title)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(tint)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch state {
        case .queued: "clock"
        case .deleting: "arrow.triangle.2.circlepath"
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .uncertain: "exclamationmark.triangle.fill"
        case .notAttempted: "pause.circle"
        }
    }

    private var tint: Color {
        switch state {
        case .queued, .notAttempted: .secondary
        case .deleting: .blue
        case .completed: .green
        case .failed: .red
        case .uncertain: .orange
        }
    }
}

private struct DeletionSummary: View {
    let entries: [OperationResult.Entry]

    var body: some View {
        Text(summary).font(.callout).foregroundStyle(.secondary)
    }

    private var summary: String {
        let counts = Dictionary(grouping: entries, by: { $0.state.title }).mapValues(\.count)
        return ["Completed", "Failed", "Uncertain", "Not attempted", "Deleting", "Queued"]
            .compactMap { label in
                counts[label].map { "\($0) \(label.lowercased())" }
            }
            .joined(separator: " · ")
    }
}
