import AppKit
import SwiftUI
import Testing
@testable import DevBox

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

    private func render<V: View>(_ view: V, height: CGFloat) throws {
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
    }
}
