import AppKit
import SwiftUI

/// Only the selected project's two panes are retained. AppKit removes the hidden
/// pane from layout, hit testing and accessibility while preserving its Table.
/// Session state remains the source of truth; this object owns UI lifetime only.
struct RetainedProjectPanes: NSViewControllerRepresentable {
    let projectID: String
    let selection: ProjectSection
    let worktrees: () -> AnyView
    let branches: () -> AnyView

    func makeNSViewController(context: Context) -> Controller { Controller() }

    func updateNSViewController(_ controller: Controller, context: Context) {
        controller.update(projectID: projectID, selection: selection) { section in
            let pane = section == .worktrees ? worktrees() : branches()
            // Hosting controllers are environment boundaries. Forward the complete
            // current environment, including store, locale, theme and enabled state.
            return AnyView(pane.environment(\.self, context.environment))
        }
    }

    @MainActor
    final class Controller: NSTabViewController {
        private(set) var projectID: String?
        private(set) var hosts: [ProjectSection: NSHostingController<AnyView>] = [:]

        override func loadView() {
            super.loadView()
            tabStyle = .unspecified
            tabView.tabViewType = .noTabsNoBorder
        }

        func update(projectID: String, selection: ProjectSection, content: (ProjectSection) -> AnyView) {
            _ = view
            if self.projectID != projectID {
                for item in tabViewItems { removeTabViewItem(item) }
                hosts.removeAll()
                self.projectID = projectID
            }
            for (section, host) in hosts { host.rootView = content(section) }
            if hosts[selection] == nil {
                let host = NSHostingController(rootView: content(selection))
                hosts[selection] = host
                let item = NSTabViewItem(viewController: host)
                item.label = selection.rawValue
                addTabViewItem(item)
            }
            guard let host = hosts[selection],
                  let index = tabViewItems.firstIndex(where: { $0.viewController === host }) else { return }
            if selectedTabViewItemIndex != index {
                // Do not leave keyboard focus in a detached, hidden pane.
                if let responder = view.window?.firstResponder as? NSView,
                   responder.isDescendant(of: view) {
                    view.window?.makeFirstResponder(nil)
                }
                selectedTabViewItemIndex = index
            }
        }
    }
}
