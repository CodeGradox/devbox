import AppKit
import SwiftUI

/// The menu owns native items, not a SwiftUI subtree per identity. It is rebuilt
/// only when inventory changes; filtering and selection keep the same menu.
struct CommitterPopUpButton: NSViewRepresentable {
    let options: [BranchCommitter]
    @Binding var selection: BranchCommitter?
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.locale) private var locale

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = CommitterButton(frame: .zero, pullsDown: false)
        button.cell?.lineBreakMode = .byTruncatingMiddle
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        updateNSView(button, context: context)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.update(
            button, options: options, selection: $selection, isEnabled: isEnabled,
            allTitle: String(localized: "All committers", locale: locale),
            accessibilityLabel: String(localized: "Committer", locale: locale)
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width,
               height: nsView.intrinsicContentSize.height)
    }

    @MainActor
    final class Coordinator: NSObject {
        private var previousOptions: [BranchCommitter]?
        private var previousTitle: String?
        private var selection: Binding<BranchCommitter?>?

        func update(
            _ button: NSPopUpButton, options: [BranchCommitter],
            selection: Binding<BranchCommitter?>, isEnabled: Bool,
            allTitle: String = "All committers", accessibilityLabel: String = "Committer"
        ) {
            self.selection = selection
            if previousOptions != options || previousTitle != allTitle {
                let menu = NSMenu()
                menu.autoenablesItems = false
                menu.addItem(NSMenuItem(title: allTitle, action: nil, keyEquivalent: ""))
                for identity in options {
                    let item = NSMenuItem(title: identity.label, action: nil, keyEquivalent: "")
                    item.representedObject = identity
                    menu.addItem(item)
                }
                button.menu = menu
                previousOptions = options
                previousTitle = allTitle
            }
            button.select(button.itemArray.first {
                ($0.representedObject as? BranchCommitter) == selection.wrappedValue
            })
            button.isEnabled = isEnabled
            button.setAccessibilityLabel(accessibilityLabel)
            button.cell?.setAccessibilityLabel(accessibilityLabel)
            button.target = self
            button.action = #selector(selectionChanged(_:))
        }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            guard sender.isEnabled, let item = sender.selectedItem else { return }
            selection?.wrappedValue = item.representedObject as? BranchCommitter
        }
    }
}

private final class CommitterButton: NSPopUpButton {
    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width = min(size.width, 240)
        return size
    }
}
