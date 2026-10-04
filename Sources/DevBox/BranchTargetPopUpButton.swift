import AppKit
import SwiftUI

/// One native control and menu, rather than a SwiftUI view for every branch.
struct BranchTargetPopUpButton: NSViewRepresentable {
    let options: [BranchPickerPresentation.Option]
    @Binding var selection: String?
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = WidthConstrainedPopUpButton(frame: .zero, pullsDown: false)
        button.cell?.lineBreakMode = .byTruncatingMiddle
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        updateNSView(button, context: context)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.update(
            button, options: options, selection: $selection, isEnabled: isEnabled
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width,
               height: nsView.intrinsicContentSize.height)
    }

    @MainActor
    final class Coordinator: NSObject {
        private var previousOptions: [BranchPickerPresentation.Option]?
        private var previousFallback: String?
        private var selection: Binding<String?>?

        func update(
            _ button: NSPopUpButton,
            options: [BranchPickerPresentation.Option],
            selection: Binding<String?>,
            isEnabled: Bool
        ) {
            // Bindings may capture a different project after a SwiftUI refresh.
            self.selection = selection
            let selected = selection.wrappedValue
            let fallback = selected.flatMap { reference in
                options.contains { $0.reference == reference } ? nil : reference
            }
            if previousOptions != options || previousFallback != fallback {
                let menu = NSMenu()
                menu.autoenablesItems = false
                menu.addItem(NSMenuItem(title: "Main checkout (default)", action: nil, keyEquivalent: ""))
                for option in options {
                    let item = NSMenuItem(title: option.label, action: nil, keyEquivalent: "")
                    item.representedObject = option.reference
                    menu.addItem(item)
                }
                if let fallback {
                    let item = NSMenuItem(title: fallback, action: nil, keyEquivalent: "")
                    item.representedObject = fallback
                    menu.addItem(item)
                }
                button.menu = menu
                previousOptions = options
                previousFallback = fallback
            }
            // representedObject, not the title or index, is the persistent identity.
            let item = button.itemArray.first { ($0.representedObject as? String) == selected }
            button.select(item)
            button.isEnabled = isEnabled
            button.setAccessibilityLabel("Merge target")
            // AppKit exposes the popup cell as the actual AXPopUpButton element.
            button.cell?.setAccessibilityLabel("Merge target")
            button.target = self
            button.action = #selector(selectionChanged(_:))
        }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            guard sender.isEnabled, let item = sender.selectedItem else { return }
            selection?.wrappedValue = item.representedObject as? String
        }
    }
}

/// Long references must not establish a huge minimum width in a SwiftUI HStack.
/// The open native menu still contains the complete, untruncated titles.
private final class WidthConstrainedPopUpButton: NSPopUpButton {
    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width = min(size.width, 240)
        return size
    }
}
