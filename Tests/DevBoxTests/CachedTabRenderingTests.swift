import AppKit
import SwiftUI
import Testing
@testable import DevBox
@testable import DevBoxCore

@MainActor
private struct PaneProjectSettings: SettingsPersisting {
    let project = ProjectRecord(id: "/pane-fixture/.git", name: "Fixture", path: "/pane-fixture")
    func load() throws -> AppSettings { AppSettings(projects: [project]) }
    func save(_ settings: AppSettings) throws {}
}

@MainActor @Observable
private final class PaneEnvironmentStore {
    var name = "initial store"
}

private struct PaneEnvironmentProbe: NSViewRepresentable {
    let metadata: String
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled
    @Environment(PaneEnvironmentStore.self) private var store

    func makeNSView(context: Context) -> NSTextField { NSTextField(labelWithString: "") }
    func updateNSView(_ view: NSTextField, context: Context) {
        view.stringValue = "\(metadata)|\(locale.identifier)|\(scheme == .dark)|\(enabled)|\(store.name)"
    }
}

private struct EnvironmentPaneFixture: View {
    let metadata: String
    let section: ProjectSection
    var body: some View {
        RetainedProjectPanes(
            projectID: "environment", selection: section,
            worktrees: { AnyView(PaneEnvironmentProbe(metadata: metadata)) },
            branches: { AnyView(PaneEnvironmentProbe(metadata: metadata)) }
        )
    }
}

@MainActor
private struct SyntheticPane: View {
    struct Row: Identifiable { let id: Int }
    let rows = (0..<672).map { Row(id: $0) }
    let options = (0..<672).map { BranchCommitter(name: "Developer \($0)", email: "dev\($0)@example.invalid") }
    var native: Bool

    var body: some View {
        VStack {
            if native {
                CommitterPopUpButton(options: options, selection: .constant(nil)).frame(width: 185)
            } else {
                Picker("Committer", selection: Binding<BranchCommitter?>.constant(nil)) {
                    Text("All committers").tag(nil as BranchCommitter?)
                    ForEach(options) { Text($0.label).tag(Optional($0)) }
                }.frame(width: 185)
            }
            Table(rows) {
                TableColumn("Branch") { Text("branch-\($0.id)") }
                TableColumn("Committer") { Text("Developer \($0.id)") }
            }
        }
    }
}

@Suite(.serialized)
@MainActor
struct CachedTabRenderingTests {
    private func textField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField { return field }
        return view.subviews.lazy.compactMap { textField(in: $0) }.first
    }

    private func table(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { table(in: $0) }.first
    }

    private func settle(_ window: NSWindow) async {
        for _ in 0..<5 {
            window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func retainedHostsReceiveCurrentEnvironmentAndMetadata() async throws {
        _ = NSApplication.shared
        let store = PaneEnvironmentStore()
        func root(_ metadata: String, _ section: ProjectSection, _ updated: Bool) -> some View {
            EnvironmentPaneFixture(metadata: metadata, section: section)
                .environment(store)
                .environment(\.locale, Locale(identifier: updated ? "sv_SE" : "en_US"))
                .environment(\.colorScheme, updated ? .dark : .light)
                .disabled(updated)
        }
        let host = NSHostingView(rootView: root("old", .worktrees, false))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        await settle(window)
        let field = try #require(textField(in: host))
        #expect(field.stringValue == "old|en_US|false|true|initial store")
        host.rootView = root("old", .branches, false)
        await settle(window)
        store.name = "updated store"
        host.rootView = root("new", .branches, true)
        await settle(window)
        #expect(textField(in: host)?.stringValue == "new|sv_SE|true|false|updated store")
        host.rootView = root("new", .worktrees, true)
        await settle(window)
        #expect(textField(in: host) === field)
        #expect(field.stringValue == "new|sv_SE|true|false|updated store")
    }

    @Test func nativeTableAndScrollSurviveSwitchAndHostsAreProjectBounded() async throws {
        _ = NSApplication.shared
        let controller = RetainedProjectPanes.Controller()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.close() }
        func update(_ project: String, _ section: ProjectSection) {
            controller.update(projectID: project, selection: section) { _ in
                AnyView(SyntheticPane(native: true))
            }
        }
        update("one", .worktrees)
        await settle(window)
        #expect(controller.hosts.count == 1)
        let worktrees = try #require(controller.hosts[.worktrees])
        let firstTable = try #require(table(in: worktrees.view))
        #expect(firstTable.numberOfRows == 672)
        firstTable.scrollRowToVisible(300)
        await settle(window)
        let scroll = try #require(firstTable.enclosingScrollView)
        let origin = scroll.contentView.bounds.origin
        #expect(origin.y > 0)
        // SwiftUI Table keeps native row virtualization, not 672 live row views.
        var materialized = 0
        firstTable.enumerateAvailableRowViews { _, _ in materialized += 1 }
        #expect(materialized < 672)
        window.makeFirstResponder(firstTable)
        update("one", .branches)
        await settle(window)
        #expect(controller.hosts.count == 2)
        #expect(!firstTable.isDescendant(of: controller.view))
        #expect(window.firstResponder !== firstTable)
        update("one", .worktrees)
        await settle(window)
        #expect(controller.hosts[.worktrees] === worktrees)
        #expect(table(in: worktrees.view) === firstTable)
        #expect(scroll.contentView.bounds.origin == origin)
        weak let oldBranches = controller.hosts[.branches]
        update("two", .branches)
        await settle(window)
        #expect(controller.projectID == "two")
        #expect(controller.hosts.count == 1)
        #expect(controller.hosts[.worktrees] == nil)
        #expect(oldBranches == nil)
    }

    @Test func otherTabErrorsCannotReplaceARetainedWorktreeTable() async throws {
        _ = NSApplication.shared
        let settings = PaneProjectSettings()
        let store = AppStore(persistence: settings, editorLauncher: inertEditorLauncher())
        store.loadSelection()
        let session = try #require(store.selectedProjectSession)
        store.destination = nil // Cancel discovery before seeding a complete cache.
        let records = (0..<80).map {
            WorktreeRecord(path: "/pane-fixture/\($0)", branch: "topic-\($0)", head: "abc", isMain: $0 == 0)
        }
        session.reconcile(records, refresh: false)
        session.performBatchUpdates {
            for record in records {
                session.updateRow(record.id) {
                    $0.status = GitStatus(staged: 0, modified: 0, untracked: 0, conflicted: 0)
                    $0.usage = DiskUsage(bytes: 100, fileCount: 1, unreadableCount: 0)
                }
            }
            session.updateOverview {
                $0.gitUsage = DiskUsage(bytes: 100, fileCount: 1, unreadableCount: 0)
                $0.branches = BranchInspection(targetLabel: "main", byWorktreeID: [:])
            }
        }
        session.branchList.reconcile([])
        store.destination = .project(settings.project.id)
        let controller = RetainedProjectPanes.Controller()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 650),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { store.destination = nil; window.close() }
        func update(_ section: ProjectSection) {
            store.projectSection = section
            controller.update(projectID: settings.project.id, selection: section) { section in
                switch section {
                case .worktrees:
                    AnyView(WorktreesView(project: settings.project, session: session).environment(store))
                case .branches:
                    AnyView(BranchesView(project: settings.project, session: session.branchList).environment(store))
                }
            }
        }
        update(.worktrees)
        await settle(window)
        let worktrees = try #require(controller.hosts[.worktrees])
        let original = try #require(table(in: worktrees.view))
        update(.branches)
        session.branchLoading.error = "Synthetic branch load failure"
        await settle(window)
        worktrees.view.layoutSubtreeIfNeeded()
        #expect(table(in: worktrees.view) === original)
        update(.worktrees)
        await settle(window)
        #expect(table(in: worktrees.view) === original)
        #expect(original.numberOfRows == 80)
        #expect(store.loadError == nil)
    }

    /// Opt-in, diagnostic only: never assert machine-dependent timings.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DEVBOX_TAB_BENCHMARK"] == "1"))
    func cachedRemountBenchmark() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        for native in [false, true] {
            var samples: [Double] = []
            for iteration in 0..<6 {
                window.contentView = nil
                let start = ContinuousClock.now
                let host = NSHostingView(rootView: SyntheticPane(native: native))
                window.contentView = host
                host.frame = window.contentLayoutRect
                host.layoutSubtreeIfNeeded()
                let elapsed = start.duration(to: .now)
                if iteration > 0 {
                    samples.append(Double(elapsed.components.seconds) * 1000 +
                                   Double(elapsed.components.attoseconds) / 1e15)
                }
            }
            print("TAB BENCHMARK native=\(native), 672 rows/committers, warm remount ms: \(samples)")
        }
        let controller = RetainedProjectPanes.Controller()
        window.contentViewController = controller
        func update(_ selection: ProjectSection) {
            controller.update(projectID: "benchmark", selection: selection) { _ in
                AnyView(SyntheticPane(native: true))
            }
            controller.view.layoutSubtreeIfNeeded()
        }
        update(.worktrees)
        update(.branches)
        var samples: [Double] = []
        for _ in 0..<5 {
            let start = ContinuousClock.now
            update(.worktrees)
            update(.branches)
            let elapsed = start.duration(to: .now)
            samples.append((Double(elapsed.components.seconds) * 1000 +
                            Double(elapsed.components.attoseconds) / 1e15) / 2)
        }
        print("TAB BENCHMARK retained warm switch ms (round-trip/2): \(samples)")
    }
}
