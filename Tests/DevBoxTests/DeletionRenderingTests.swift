import AppKit
import SwiftUI
import Testing
@testable import DevBox
@testable import DevBoxCore

@MainActor
private final class DeletionRenderingSettings: SettingsPersisting {
    func load() throws -> AppSettings { AppSettings() }
    func save(_ settings: AppSettings) throws {}
}

@Suite(.serialized)
@MainActor
struct DeletionRenderingTests {
    private var states: [DeletionState] {
        [
            .queued, .deleting, .completed,
            .failed("Permission denied (MariaDB error 1044)."),
            .uncertain("MariaDB did not confirm the result. Check the server before retrying."),
            .notAttempted("The preceding deletion has an uncertain outcome.")
        ]
    }

    @Test
    func everyDeletionStateRendersWithoutSharedEnvironment() throws {
        #expect(states.map(\.title) == ["Queued", "Deleting", "Completed", "Failed", "Uncertain", "Not attempted"])
        for state in states {
            try render(DeletionItemView(name: "example_database", state: state), height: 110)
        }
    }

    @Test
    func mixedResultsRenderWithStatusesAndMessages() throws {
        let entries = states.enumerated().map {
            OperationResult.Entry(name: "database_\($0.offset)", state: $0.element)
        }
        try render(OperationResultsView(result: .init(title: "Deletion Results", entries: entries)), height: 460)
    }

    @Test(.timeLimit(.minutes(1)))
    func activeDeletionShowsOnlyTheItemSpinner() async throws {
        let (started, signalStarted) = AsyncStream<Void>.makeStream()
        let (finished, signalFinished) = AsyncStream<Void>.makeStream()
        defer {
            signalStarted.finish()
            signalFinished.finish()
        }
        let store = AppStore(
            persistence: DeletionRenderingSettings(),
            removeWorktree: { _, _ in
                signalStarted.yield(())
                for await _ in finished { break }
            },
            editorLauncher: inertEditorLauncher(),
            authenticate: { _ in }
        )
        let request = DeletionRequest(items: .worktrees(
            ProjectRecord(id: "/test/repo/.git", name: "Test", path: "/test/repo"),
            [WorktreeRow(worktree: WorktreeRecord(
                path: "/test/feature", branch: "feature", head: "abc123", isMain: false
            ))]
        ))
        store.deletionRequest = request
        let task = Task { await store.delete(request) }
        for await _ in started { break }
        #expect(store.deletionEntries.map(\.state) == [.deleting])
        try render(DeletionConfirmation(request: request).environment(store), height: 600) { host in
            let indicators = progressIndicators(in: host)
            #expect(indicators.filter { $0.style == .spinning }.count == 1)
            #expect(indicators.filter { $0.style == .bar }.count == 1)
        }
        signalFinished.finish()
        await task.value
    }

    private func progressIndicators(in view: NSView) -> [NSProgressIndicator] {
        (view as? NSProgressIndicator).map { [$0] } ?? view.subviews.flatMap { progressIndicators(in: $0) }
    }

    private func render<V: View>(
        _ view: V, height: CGFloat, inspect: (NSView) -> Void = { _ in }
    ) throws {
        _ = NSApplication.shared
        let bounds = NSRect(x: 0, y: 0, width: 560, height: height)
        let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view)
        window.contentView = host
        defer { window.close() }
        host.frame = bounds
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(bitmap.pixelsWide > 0)
        #expect(bitmap.pixelsHigh > 0)
        inspect(host)
    }
}
