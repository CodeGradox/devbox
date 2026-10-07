import AppKit
import SwiftUI
import Testing
@testable import DevBox
@testable import DevBoxCore

/// Table-hosted cells and the total panel must work without an AppStore environment.
@Suite(.serialized)
@MainActor
struct ProjectOverviewRenderingTests {
    @Test
    func lifecycleStatesRenderWithoutSharedEnvironment() throws {
        for state in [BranchMergeState.base, .merged, .notMerged, .unknown] {
            for upstreamGone in [false, true] {
                try render(BranchLifecycleCell(
                    lifecycle: BranchLifecycle(
                        mergeState: state, upstreamGone: upstreamGone, detail: "Local ancestry only"
                    ), targetLabel: "origin/main", isLoading: false
                ))
            }
        }
        try render(BranchLifecycleCell(lifecycle: nil, targetLabel: "main", isLoading: true))
        try render(BranchLifecycleCell(
            lifecycle: nil, targetLabel: "main", isLoading: false, error: "Target unavailable"
        ))
    }

    @Test
    func nativeTableRendersLifecycleCellWithoutSharedEnvironment() throws {
        let rows = [WorktreeRow(worktree: WorktreeRecord(
            path: "/test/feature", branch: "feature", head: "", isMain: false
        ))]
        try render(Table(rows) {
            TableColumn("Worktree") { row in Text(row.worktree.path) }
            TableColumn("Lifecycle") { _ in
                BranchLifecycleCell(
                    lifecycle: BranchLifecycle(mergeState: .merged, upstreamGone: true),
                    targetLabel: "main", isLoading: false
                )
            }
        })
    }

    @Test
    func totalPanelRendersEveryMeasurementStateWithoutSharedEnvironment() throws {
        var row = WorktreeRow(worktree: WorktreeRecord(
            path: "/test/main", branch: "main", head: "", isMain: true
        ))
        var overview = ProjectOverview()
        try render(ProjectSizeView(summary: ProjectSizeSummary(rows: [row], overview: overview)))
        overview.gitSizeState = .scanning
        try render(ProjectSizeView(summary: ProjectSizeSummary(rows: [row], overview: overview)))
        overview.gitUsage = DiskUsage(bytes: 2048, fileCount: 1, unreadableCount: 0)
        row.usage = DiskUsage(bytes: 4096, fileCount: 1, unreadableCount: 0)
        try render(ProjectSizeView(summary: ProjectSizeSummary(rows: [row], overview: overview)))
        overview.gitSizeState = .idle
        try render(ProjectSizeView(
            summary: ProjectSizeSummary(rows: [row], overview: overview),
            gitMeasuredAt: Date(timeIntervalSince1970: 0)
        ))
        overview.gitUsageError = "Metadata refresh failed"
        try render(ProjectSizeView(
            summary: ProjectSizeSummary(rows: [row], overview: overview),
            gitError: overview.gitUsageError, gitMeasuredAt: Date(timeIntervalSince1970: 0)
        ))
        row.usage = DiskUsage(bytes: Int64.max, fileCount: 1, unreadableCount: 0)
        try render(ProjectSizeView(summary: ProjectSizeSummary(rows: [row], overview: overview)))
    }

    private func render<V: View>(_ view: V) throws {
        _ = NSApplication.shared
        let size = NSSize(width: 560, height: 240)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        expectRendered(bitmap)
    }
}
