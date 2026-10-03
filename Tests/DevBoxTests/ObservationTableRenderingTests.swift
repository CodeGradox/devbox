import AppKit
import SwiftUI
import Testing
@testable import DevBox
@testable import DevBoxCore

@Suite(.serialized)
@MainActor
struct ObservationTableRenderingTests {
    /// Exercise the actual hosted row views through loading/result transitions.
    /// Scope counters live in ObservationScopeTests; this is not a timing test.
    @Test
    func tableKeepsStableModelsWhileStreamingResults() throws {
        _ = NSApplication.shared
        let session = ProjectSessionState()
        session.reconcile((0..<200).map {
            WorktreeRecord(path: "/test/project/worktree-\($0)", branch: "feature-\($0)", head: "", isMain: $0 == 0)
        }, refresh: false)
        let original = session.rows
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: StreamingTable(session: session))
        window.contentView = host
        defer { window.close() }
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        try render(host)
        for (index, row) in original.enumerated() {
            session.updateRow(row.id) {
                $0.sizeState = .scanning
                $0.status = GitStatus(staged: 0, modified: index % 2, untracked: 0, conflicted: 0)
            }
            if index.isMultiple(of: 40) { try render(host) }
            session.updateRow(row.id) {
                $0.sizeState = .idle
                $0.usage = DiskUsage(bytes: Int64((index + 1) * 4096), fileCount: index + 1, unreadableCount: 0)
            }
        }
        try render(host)
        #expect(zip(original, session.rows).allSatisfy { $0 === $1 })
        #expect(session.summary.measuredWorktrees == 200)
    }

    private func render<V: View>(_ host: NSHostingView<V>) throws {
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(bitmap.pixelsWide > 0)
    }
}

private struct StreamingTable: View {
    let session: ProjectSessionState

    var body: some View {
        Table(session.rows) {
            TableColumn("Worktree") { WorktreeNameCell(state: $0) }
            TableColumn("Status") { WorktreeStatusCell(state: $0) }
            TableColumn("Merge") { WorktreeLifecycleCell(state: $0) }
            TableColumn("Size") { StreamingSizeCell(state: $0) }
        }
    }
}

private struct StreamingSizeCell: View {
    let state: WorktreeState

    var body: some View {
        WorktreeDiskUsageCell(
            row: state.row, canRefresh: !state.row.isSizeBusy, onRefresh: {},
            presentation: state.presentation
        )
    }
}
