import AppKit
import DevBoxCore
import SwiftUI

/// Render the production project detail with synthetic data, without scanning,
/// reading saved settings, or accessing credentials. Built by profile-memory.sh.
@main
enum MemoryProfileApp {
    @MainActor
    static func main() {
        let args = CommandLine.arguments
        guard args.count == 4, let branches = Int(args[1]), branches >= 0,
              let rows = Int(args[2]), rows >= 0, ["detail", "detail-open", "model"].contains(args[3]) else {
            fatalError("Usage: DevBoxMemoryProfile <branch count> <row count> <detail|detail-open|model>")
        }
        let app = NSApplication.shared
        let delegate = ProfileDelegate(branches: branches, rows: rows, mode: args[3])
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
private final class ProfileDelegate: NSObject, NSApplicationDelegate {
    private let store: AppStore
    private let session: ProjectSessionState
    private let project: ProjectRecord
    private let mode: String
    private var window: NSWindow?
    private var menuObservers: [NSObjectProtocol] = []

    init(branches: Int, rows: Int, mode: String) {
        let project = ProjectRecord(
            id: "/memory-profile/project/.git", name: "Memory profile", path: "/memory-profile/project"
        )
        self.project = project
        self.mode = mode
        // The store restores the saved project and would start loading it at once. Give it nothing
        // to scan, so no Git process runs and the injected session below is all that is measured.
        store = AppStore(
            persistence: ProfileSettings(project: project),
            sizeQueue: WorktreeSizeQueue(
                scan: { _ in throw CancellationError() },
                gitStorageScan: { _ in throw CancellationError() }
            ),
            inspectBranches: { _, _ in BranchInspection(targetLabel: "main", availableTargets: [], byWorktreeID: [:]) },
            listWorktrees: { _ in [] }
        )
        let session = ProjectSessionState()
        let records = (0..<rows).map { index in
            WorktreeRecord(
                path: "/memory-profile/worktree-\(index)", branch: "feature-\(index)",
                head: String(repeating: "a", count: 40), isMain: index == 0
            )
        }
        session.reconcile(records, refresh: false)
        session.updateOverview {
            $0.branches = BranchInspection(
                targetLabel: "main",
                availableTargets: (0..<branches).map { index in
                    BranchTarget(reference: "refs/heads/feature-\(index)", label: "feature-\(index)")
                },
                byWorktreeID: Dictionary(uniqueKeysWithValues: records.map {
                    ($0.id, BranchLifecycle(mergeState: .notMerged, upstreamGone: false))
                })
            )
        }
        self.session = session
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Explicitly create a window: an unbundled SwiftUI App launched from the
        // terminal does not reliably receive the open-application Apple event.
        let content = Group {
            if mode == "model" {
                // Keep the same model alive but do not construct its controls.
                Text("\(session.rows.count) worktrees; \(session.branchPresentation.options.count) branch targets")
            } else {
                WorktreesView(project: project, session: session)
            }
        }
        .environment(store)
        .frame(minWidth: 900, minHeight: 560)
        .onAppear {
            FileHandle.standardOutput.write(Data("PROFILE_READY\n".utf8))
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1140, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "DevBox memory profile"
        window.contentView = NSHostingView(rootView: content)
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        if mode == "detail-open" {
            for (name, marker) in [
                (NSMenu.didBeginTrackingNotification, "PROFILE_MENU_OPEN"),
                (NSMenu.didEndTrackingNotification, "PROFILE_MENU_CLOSED"),
            ] {
                menuObservers.append(NotificationCenter.default.addObserver(
                    forName: name, object: nil, queue: .main
                ) { _ in
                    FileHandle.standardOutput.write(Data("\(marker)\n".utf8))
                })
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let view = self?.window?.contentView,
                      let popup = Self.findPopup(in: view) else { return }
                popup.performClick(nil)
            }
        }
    }

    private static func findPopup(in view: NSView) -> NSPopUpButton? {
        if let popup = view as? NSPopUpButton { return popup }
        for child in view.subviews {
            if let popup = findPopup(in: child) { return popup }
        }
        return nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

private struct ProfileSettings: SettingsPersisting {
    let project: ProjectRecord
    func load() throws -> AppSettings { AppSettings(projects: [project]) }
    func save(_ settings: AppSettings) throws {
        // The profiling app never persists changes.
    }
}
