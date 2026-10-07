import AppKit
import Observation
import SwiftUI
import Synchronization
import Testing
@testable import DevBox
@testable import DevBoxCore

@Suite(.serialized)
@MainActor
struct DatabaseRenderingTests {
    @Test
    func nativeTableRendersLoadingResultsAndStaleValuesWithoutEnvironment() throws {
        _ = NSApplication.shared
        let session = DatabaseSessionState()
        session.reconcile((0..<100).map { DatabaseRecord(name: "database_\($0)") })
        let original = session.rows
        let invalidations = DatabaseMembershipCounter()
        withObservationTracking {
            _ = session.rows
        } onChange: {
            invalidations.increment()
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1024, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: VStack(spacing: 0) {
            DatabaseTotalsView(session: session)
            DatabaseTable(session: session, selection: .constant([]))
        })
        window.contentView = host
        defer { window.close() }
        host.frame = NSRect(x: 0, y: 0, width: 1024, height: 600)
        session.beginStatistics()
        try render(host)
        session.receive(Dictionary(uniqueKeysWithValues: session.rows.map {
            ($0.id, DatabaseStatistics(tableCount: 3, viewCount: 2, estimatedRows: 21, dataBytes: 4096, indexBytes: 1024))
        }))
        try render(host)
        #expect(session.summary.knownCount == 100)
        session.failStatistics("Synthetic permission failure")
        try render(host)
        #expect(session.summary.staleCount == 100)
        #expect(session.summary.text.contains("last-known"))
        #expect(zip(original, session.rows).allSatisfy { $0 === $1 })
        #expect(invalidations.value == 0)
    }

    private func render<V: View>(_ host: NSHostingView<V>) throws {
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        expectRendered(bitmap)
    }
}

private final class DatabaseMembershipCounter: Sendable {
    private let count = Mutex(0)
    var value: Int { count.withLock { $0 } }
    func increment() { count.withLock { $0 += 1 } }
}
