import AppKit
import SwiftUI
import Testing
@testable import DevBox

@Suite(.serialized)
@MainActor
struct CommitterPopUpButtonTests {
    private func button(in view: NSView) -> NSPopUpButton? {
        if let button = view as? NSPopUpButton { return button }
        return view.subviews.lazy.compactMap { button(in: $0) }.first
    }

    @Test func highCardinalityHostedControlPreservesFullLabelsAndAccessibility() throws {
        _ = NSApplication.shared
        let options = (0..<672).map {
            BranchCommitter(name: String(repeating: "Long name ", count: 20) + "\($0)",
                            email: "developer\($0)@example.invalid")
        }
        let host = NSHostingView(rootView:
            CommitterPopUpButton(options: options, selection: .constant(options[671]))
                .disabled(true).frame(width: 185)
        )
        host.frame = NSRect(x: 0, y: 0, width: 185, height: 40)
        host.layoutSubtreeIfNeeded()
        let popup = try #require(button(in: host))
        #expect(popup.numberOfItems == 673)
        #expect(popup.title == options[671].label)
        #expect(popup.frame.width <= 185)
        #expect(popup.intrinsicContentSize.width <= 240)
        #expect(!popup.isEnabled)
        #expect(popup.cell?.isAccessibilityElement() == true)
        #expect(popup.cell?.accessibilityRole() == .popUpButton)
        #expect(popup.cell?.accessibilityLabel() == "Committer")
    }

    @Test func identityMenuReuseAndActionRouting() throws {
        _ = NSApplication.shared
        let options = [
            BranchCommitter(name: "Same", email: "a@example.invalid"),
            BranchCommitter(name: "Same", email: "b@example.invalid"),
            BranchCommitter(name: "", email: ""),
            BranchCommitter(name: "Other", email: "a@example.invalid")
        ]
        var selected: BranchCommitter?
        var writes = 0
        let binding = Binding(get: { selected }, set: { selected = $0; writes += 1 })
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        let coordinator = CommitterPopUpButton.Coordinator()
        coordinator.update(button, options: options, selection: binding, isEnabled: true)
        let menu = try #require(button.menu)
        let items = button.itemArray
        #expect(button.indexOfSelectedItem == 0)
        #expect(button.itemTitles == ["All committers"] + options.map(\.label))
        for (index, option) in options.enumerated() {
            menu.performActionForItem(at: index + 1)
            #expect(selected == option)
        }
        menu.performActionForItem(at: 0)
        #expect(selected == nil)
        #expect(writes == 5)
        selected = options[1]
        coordinator.update(button, options: options, selection: binding, isEnabled: false)
        #expect(button.menu === menu)
        #expect(zip(items, button.itemArray).allSatisfy { $0 === $1 })
        #expect(button.indexOfSelectedItem == 2)
        #expect(button.cell?.accessibilityLabel() == "Committer")
        #expect(button.cell?.accessibilityRole() == .popUpButton)
        button.selectItem(at: 1)
        coordinator.selectionChanged(button)
        #expect(writes == 5)
        var fresh: BranchCommitter?
        coordinator.update(button, options: options.reversed(),
                           selection: Binding(get: { fresh }, set: { fresh = $0 }), isEnabled: true,
                           allTitle: "Everyone", accessibilityLabel: "Author")
        #expect(button.menu !== menu)
        button.menu?.performActionForItem(at: 1)
        #expect(fresh == options.last)
        #expect(selected == options[1])
        #expect(button.itemTitles.first == "Everyone")
        #expect(button.cell?.accessibilityLabel() == "Author")
    }
}
