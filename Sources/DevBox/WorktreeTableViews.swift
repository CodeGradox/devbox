import AppKit
import DevBoxCore
import SwiftUI

// Table builders pass references only. Each hosted cell observes the properties
// it renders, without making inventory or branch updates rebuild the table.
struct WorktreeNameCell: View {
    let state: WorktreeState

    var body: some View {
        let row = state.row
        let presentation = state.presentation
        HStack(spacing: 8) {
            Image(systemName: row.worktree.isMain ? "house" : "folder")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(presentation.folderName).fontWeight(.medium)
                    if row.worktree.isLocked {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .help(row.worktree.lockReason ?? "Locked")
                    }
                    if !row.worktree.nestedWorktreePaths.isEmpty {
                        Image(systemName: "square.stack")
                            .font(.caption)
                            .help("Contains \(row.worktree.nestedWorktreePaths.count) registered worktrees, excluded from this row’s size.")
                    }
                }
                Text(presentation.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 5)
        .help(presentation.path)
    }
}

struct WorktreeBranchCell: View {
    let state: WorktreeState

    var body: some View {
        Text(state.presentation.branchLabel)
            .foregroundStyle(state.row.worktree.branch == nil ? .secondary : .primary)
            .help(state.row.worktree.head)
    }
}

struct WorktreeStatusCell: View {
    let state: WorktreeState

    var body: some View {
        let presentation = state.presentation
        Label {
            Text(presentation.statusText).foregroundStyle(.secondary)
        } icon: {
            Image(systemName: presentation.statusSymbol)
                .foregroundStyle(color)
        }
        .lineLimit(2)
        .help(presentation.statusText)
    }

    private var color: Color {
        switch state.presentation.statusTone {
        case .neutral: .secondary
        case .clean: .green
        case .changed, .conflicted: .orange
        }
    }
}

struct WorktreeLifecycleCell: View {
    let state: WorktreeState

    var body: some View {
        BranchLifecycleCell(
            lifecycle: state.lifecycle,
            targetLabel: state.targetLabel,
            isLoading: state.branchLoading,
            error: state.branchError
        )
    }
}

struct WorktreeSizeCell: View {
    let state: WorktreeState
    let store: AppStore

    var body: some View {
        let id = state.id
        WorktreeDiskUsageCell(
            row: state.row,
            canRefresh: store.canRefreshSize(state.row),
            onRefresh: { [store, id] in store.refreshWorktreeSize(id) },
            presentation: state.presentation
        )
    }
}

struct WorktreeContextMenu: View {
    let session: ProjectSessionState
    let store: AppStore
    let ids: Set<String>

    var body: some View {
        if let row = session.rows.first(where: { ids.contains($0.id) })?.row, ids.count == 1 {
            Button("Open in Zed") { [store, ids] in
                Task { await store.openInZed(ids) }
            }
            .disabled(!store.canOpenInZed(ids))
            Divider()
            Button("Refresh Disk Usage") { [store, id = row.id] in
                store.refreshWorktreeSize(id)
            }
            .disabled(!store.canRefreshSize(row))
            Divider()
            Button("Open in Finder") { [path = row.worktree.path] in
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
            Button("Copy Path") { [path = row.worktree.path] in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
            Divider()
        }
        Button("Delete Selected…", role: .destructive) { [store, ids] in
            store.worktreeSelection = ids
            store.prepareDeletion()
        }
        .disabled(ids.isEmpty || store.isRefreshing || store.isDeleting
                  || session.rows.contains { ids.contains($0.id) && $0.row.protectedReason != nil })
    }
}
