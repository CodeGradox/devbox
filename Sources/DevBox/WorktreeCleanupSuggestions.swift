import DevBoxCore
import Foundation
import SwiftUI

/// Snapshot-only recommendations. Missing evidence is never treated as eligibility.
struct WorktreeCleanupSuggestion: Identifiable {
    enum Kind: CaseIterable {
        case clean, changed
    }

    let kind: Kind
    let ids: Set<String>
    let measuredBytes: Int64?
    let isPartial: Bool
    let overflow: Bool
    var id: Kind { kind }

    var title: String {
        switch kind {
        case .clean: "\(ids.count) merged · clean"
        case .changed: "\(ids.count) merged · changes will be lost"
        }
    }

    var sizeText: String {
        if overflow { return "Size unavailable · overflow" }
        guard let measuredBytes else { return "Size not measured" }
        let size = ByteCountFormatter.string(fromByteCount: measuredBytes, countStyle: .file)
        return "\(size) allocated" + (isPartial ? " · partial" : "")
    }

    private init(kind: Kind, rows: [WorktreeRow]) {
        self.kind = kind
        ids = Set(rows.map(\.id))
        var bytes: Int64 = 0
        var measured = false
        var partial = false
        var overflow = false
        for row in rows {
            if let usage = row.usage {
                measured = true
                let sum = bytes.addingReportingOverflow(usage.bytes)
                overflow = overflow || sum.overflow
                bytes = sum.partialValue
                partial = partial || usage.unreadableCount > 0
            } else {
                partial = true
            }
            partial = partial || row.usageError != nil || row.sizeRefreshPending || row.isSizeBusy
        }
        measuredBytes = measured && !overflow ? bytes : nil
        isPartial = partial || overflow
        self.overflow = overflow
    }

    static func groups(
        rows: [WorktreeRow], overview: ProjectOverview, hasLoadedInventory: Bool
    ) -> [Self] {
        guard hasLoadedInventory, !overview.isLoadingBranches, overview.branchError == nil,
              let inspection = overview.branches, inspection.warning == nil else { return [] }
        let eligible = rows.filter {
            $0.protectedReason == nil && !$0.statusRefreshPending && $0.statusError == nil
                && $0.status != nil && inspection.byWorktreeID[$0.id]?.mergeState == .merged
                && inspection.byWorktreeID[$0.id]?.detail == nil
        }
        return Kind.allCases.compactMap { kind in
            let matching = eligible.filter { ($0.status?.isClean == true) == (kind == .clean) }
            return matching.isEmpty ? nil : Self(kind: kind, rows: matching)
        }
    }
}

/// Observe recommendation inputs here, rather than making the table's parent
/// observe every mutable row. Review recomputes membership before selecting it.
struct WorktreeCleanupSuggestions: View {
    @Environment(AppStore.self) private var store
    let session: ProjectSessionState

    private var groups: [WorktreeCleanupSuggestion] {
        WorktreeCleanupSuggestion.groups(
            rows: session.snapshots, overview: session.overview,
            hasLoadedInventory: session.hasLoadedInventory
        )
    }

    private var reviewDisabled: Bool {
        store.isRefreshing || store.isDeleting || store.isModalPresented
            || store.selectedProjectSession !== session || store.projectSection != .worktrees
    }

    var body: some View {
        let suggestions = groups
        if !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Cleanup suggestions").fontWeight(.medium)
                    Spacer()
                    Text("Branches kept").foregroundStyle(.secondary)
                }
                .font(.caption)
                ForEach(suggestions) { suggestion in
                    HStack(spacing: 8) {
                        Image(systemName: suggestion.kind == .clean
                              ? "checkmark.circle" : "exclamationmark.triangle")
                            .foregroundStyle(suggestion.kind == .clean ? Color.secondary : Color.orange)
                        Text(suggestion.title)
                            .lineLimit(1)
                            .help(suggestion.title)
                        Spacer(minLength: 8)
                        Text(suggestion.sizeText)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(suggestion.sizeText + ". Last measured exclusive allocated size; includes ignored files. Shared Git storage is excluded. Actual space recovered may differ.")
                        Button("Review…") {
                            store.reviewWorktreeCleanup(suggestion.kind, session: session)
                        }
                            .controlSize(.small)
                            .disabled(reviewDisabled)
                            .accessibilityLabel("Review \(suggestion.title)")
                    }
                    .font(.callout)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
    }

}

extension AppStore {
    func reviewWorktreeCleanup(_ kind: WorktreeCleanupSuggestion.Kind, session: ProjectSessionState) {
        guard !isRefreshing, !isDeleting, !isModalPresented,
              selectedProjectSession === session, projectSection == .worktrees else { return }
        let groups = WorktreeCleanupSuggestion.groups(
            rows: session.snapshots, overview: session.overview,
            hasLoadedInventory: session.hasLoadedInventory
        )
        guard let current = groups.first(where: { $0.kind == kind }) else { return }
        session.filter = .all
        worktreeSelection = current.ids
        prepareDeletion()
    }
}
