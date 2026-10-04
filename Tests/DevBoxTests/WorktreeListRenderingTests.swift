import AppKit
import ScreenCaptureKit
import SwiftUI
import Testing
import Vision
@testable import DevBox
@testable import DevBoxCore

@MainActor
private final class WorktreeRenderingSettings: SettingsPersisting {
    var value = AppSettings(projects: [
        ProjectRecord(id: "/test/repo/.git", name: "laft-web", path: "/Projects/laft-web")
    ])
    func load() throws -> AppSettings { value }
    func save(_ settings: AppSettings) throws { value = settings }
}

@Suite(.serialized)
@MainActor
struct WorktreeListRenderingTests {
    private func fixture() throws -> (AppStore, ProjectSessionState) {
        let store = AppStore(
            persistence: WorktreeRenderingSettings(),
            removeWorktree: { _, _ in Issue.record("Review must not delete a worktree.") },
            editorLauncher: inertEditorLauncher(),
            authenticate: { _ in Issue.record("Review must not authenticate before confirmation.") }
        )
        let session = try #require(store.selectedProjectSession)
        let destination = store.destination
        store.destination = nil // Cancel initial I/O before seeding a cached fixture.
        let names = [
            "laft-web", "bugfix-copy-data", "feature-batch-edit-residences",
            "feature-better-recurring-select", "feature-bim-ifc-import",
            "feature-buildings-smart-import", "feature-cs-notifications",
            "feature-formalize-work-order-status-log", "feature-work-order-title",
            "feature-housing-agreements", "feature-rental-ui-pages", "feature-regulation-dashboard"
        ]
        let records = names.enumerated().map { index, name in
            WorktreeRecord(
                path: "/Projects/\(name)", branch: index == 0 ? "feature/laft-4179" : name,
                head: "abc123", isMain: index == 0
            )
        }
        session.reconcile(records, refresh: false)
        session.performBatchUpdates {
            for (index, record) in records.enumerated() {
                session.updateRow(record.id) {
                    $0.status = GitStatus(staged: 0, modified: index % 3 == 0 ? 16 : 0,
                                          untracked: index % 3 == 0 ? 1 : 0, conflicted: 0)
                    if index < 10 {
                        $0.usage = DiskUsage(bytes: Int64(500_000_000 + index * 100_000_000),
                                            fileCount: 1200, unreadableCount: 0)
                    } else {
                        $0.usageError = "Measurement unavailable in this fixture."
                    }
                }
            }
            session.updateOverview {
                $0.gitUsage = DiskUsage(bytes: 376_400_000, fileCount: 300, unreadableCount: 0)
                $0.branches = BranchInspection(
                    targetLabel: "feature/laft-4179",
                    byWorktreeID: Dictionary(uniqueKeysWithValues: records.enumerated().map { index, row in
                        (row.id, BranchLifecycle(
                            mergeState: index == 0 ? .base : [3, 5, 9].contains(index) ? .merged : .notMerged,
                            upstreamGone: false
                        ))
                    })
                )
            }
        }
        store.destination = destination
        return (store, session)
    }

    @Test
    func hiddenSelectionCannotEnterDeletionBeforeViewReconciles() throws {
        let (store, session) = try fixture()
        let clean = try #require(session.rows.first { $0.row.status?.isClean == true })
        store.worktreeSelection = [clean.id]
        #expect(store.canDeleteSelection)
        session.filter = .changed
        #expect(store.selectedWorktrees.isEmpty)
        #expect(!store.canDeleteSelection)
        store.prepareDeletion()
        #expect(store.deletionRequest == nil)
    }

    @Test
    func cleanupReviewRecomputesEligibilityAndRevealsItsSelection() throws {
        let (store, session) = try fixture()
        let oldCandidate = try #require(session.rows.first {
            $0.lifecycle?.mergeState == .merged && $0.row.status?.isClean == true
        })
        let newCandidate = try #require(session.rows.first {
            $0.lifecycle?.mergeState == .merged && $0.row.status?.isClean == false
        })
        session.updateRow(oldCandidate.id) { $0.statusError = "Status unavailable" }
        session.updateRow(newCandidate.id) {
            $0.status = GitStatus(staged: 0, modified: 0, untracked: 0, conflicted: 0)
        }
        session.filter = .changed
        #expect(!session.tableRows.contains { $0.id == newCandidate.id })
        store.reviewWorktreeCleanup(.clean, session: session)
        #expect(session.filter == .all)
        #expect(store.worktreeSelection == [newCandidate.id])
        let request = try #require(store.deletionRequest)
        guard case .worktrees(_, let rows) = request.items else {
            Issue.record("Expected the existing worktree confirmation flow.")
            return
        }
        #expect(rows.map(\.id) == [newCandidate.id])
        #expect(!store.isDeleting)
    }

    @Test(.timeLimit(.minutes(1)))
    func compactLayoutAndNativeSortableHeaders() async throws {
        _ = NSApplication.shared
        let (store, session) = try fixture()
        for (width, theme) in [(900.0, AppTheme.light), (1280.0, .light), (1280.0, .dark)] {
            let size = NSSize(width: width, height: 760)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .resizable], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
            let host = NSHostingView(rootView: ContentView(theme: .constant(theme))
                .environment(store)
                .environment(\.locale, Locale(identifier: "en_US"))
                .preferredColorScheme(theme == .dark ? .dark : .light)
                .frame(width: width, height: 760))
            window.contentView = host
            defer { window.close() }
            host.frame = NSRect(origin: .zero, size: size)
            window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let table = try #require(tables(in: host).first {
                $0.numberOfRows == 12 && $0.tableColumns.count == 5
            })
            for (index, column) in [
                WorktreeSort.Column.name, .branch, .changes, .merged, .size
            ].enumerated() {
                let descriptor = try #require(table.tableColumns[index].sortDescriptorPrototype)
                for direction in [SortOrder.forward, .reverse] {
                    table.sortDescriptors = [direction == .forward
                        ? descriptor : descriptor.reversedSortDescriptor as! NSSortDescriptor]
                    try await Task.sleep(for: .milliseconds(30))
                    #expect(session.sortOrder.first?.column == column)
                    #expect(session.sortOrder.first?.order == direction)
                    #expect(table.numberOfRows == 12)
                    let ordered = session.rows.map(WorktreeListRow.init).sorted {
                        WorktreeSort.precedes($0, $1, using: session.sortOrder)
                    }
                    #expect(session.tableRows.map(\.id) == ordered.map(\.id))
                    if column == .size {
                        #expect(session.tableRows.suffix(2).allSatisfy { $0.bytes == nil })
                    }
                }
            }
            #expect(table.rowHeight < 40, "Single-line worktree rows should remain compact.")
            if ProcessInfo.processInfo.environment["DEVBOX_UI_TESTS"] == "1" {
                let image = try await capture(window)
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["en-US"]
                try VNImageRequestHandler(cgImage: image).perform([request])
                let text = request.results?.compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n") ?? ""
                for label in ["Cleanup suggestions", "Branches kept", "Review", "Uncommitted", "Changes", "Disk"] {
                    #expect(text.contains(label), "Missing \(label) at \(width), \(theme). OCR: \(text)")
                }
                if let path = ProcessInfo.processInfo.environment["DEVBOX_WORKTREE_SCREENSHOT"] {
                    let bitmap = NSBitmapImageRep(cgImage: image)
                    let url = URL(fileURLWithPath: path).deletingPathExtension()
                        .appendingPathExtension("\(Int(width)).\(theme == .dark ? "dark" : "light").png")
                    try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
                }
            }
            session.filter = .changed
            try await Task.sleep(for: .milliseconds(50))
            #expect(table.numberOfRows == session.filterCounts.changed)
            session.filter = .all
        }
    }

    private func tables(in view: NSView) -> [NSTableView] {
        (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap { tables(in: $0) }
    }

    private func capture(_ window: NSWindow) async throws -> CGImage {
        // Capture only our test window; never another application or the desktop.
        let content = try await SCShareableContent.currentProcess
        let target = try #require(content.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width * 2)
        configuration.height = Int(window.frame.height * 2)
        configuration.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
}
