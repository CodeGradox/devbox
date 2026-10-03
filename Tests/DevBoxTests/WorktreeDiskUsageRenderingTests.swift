import AppKit
import SwiftUI
import Testing
@testable import DevBox
@testable import DevBoxCore

/// These cells intentionally receive no AppStore/environmentObject. macOS Table
/// hosts cells independently, which exposed the missing-environment crash.
@Suite(.serialized)
@MainActor
struct WorktreeDiskUsageRenderingTests {
    private var rows: [WorktreeRow] {
        (0..<7).map { index in
            var row = WorktreeRow(worktree: WorktreeRecord(
                path: "/test/worktree-\(index)", branch: "feature", head: "",
                isMain: false, isBare: index == 6, exists: index != 5
            ))
            switch index {
            case 1: row.sizeState = .queued
            case 2: row.sizeState = .scanning
            case 3, 4:
                row.usage = DiskUsage(bytes: 8192, fileCount: 2, unreadableCount: 0)
                row.measuredAt = Date(timeIntervalSince1970: 0)
                if index == 4 { row.usageError = "Test refresh failure" }
            default: break
            }
            return row
        }
    }

    @Test
    func cellsRenderWithoutSharedEnvironment() throws {
        for row in rows {
            let cell = WorktreeDiskUsageCell(row: row, canRefresh: !row.isSizeBusy, onRefresh: {})
            try render(cell, size: NSSize(width: 250, height: 48))
        }
    }

    @Test
    func nativeTableRendersCellsWithoutSharedEnvironment() throws {
        let table = Table(rows) {
            TableColumn("Worktree") { row in Text(row.worktree.path) }
            TableColumn("Disk Usage") { row in
                WorktreeDiskUsageCell(row: row, canRefresh: !row.isSizeBusy, onRefresh: {})
            }
        }
        try render(table, size: NSSize(width: 560, height: 360))
    }

    private func render<V: View>(_ view: V, size: NSSize) throws {
        _ = NSApplication.shared
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
        #expect(bitmap.pixelsWide > 0)
        #expect(bitmap.pixelsHigh > 0)
    }
}
