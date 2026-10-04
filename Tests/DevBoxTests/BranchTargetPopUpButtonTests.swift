import AppKit
import SwiftUI
import Testing
@testable import DevBox

@Suite(.serialized)
@MainActor
struct BranchTargetPopUpButtonTests {
    private typealias Option = BranchPickerPresentation.Option

    @MainActor
    private final class Selection {
        var value: String?
        var writes: [String?] = []

        init(_ value: String? = nil) { self.value = value }

        var binding: Binding<String?> {
            Binding(get: { self.value }, set: {
                self.value = $0
                self.writes.append($0)
            })
        }
    }

    private func button() -> NSPopUpButton {
        _ = NSApplication.shared
        return NSPopUpButton(frame: .zero, pullsDown: false)
    }

    private let options = [
        Option(reference: "refs/heads/main", label: "main"),
        Option(reference: "refs/heads/feature", label: "same"),
        Option(reference: "refs/remotes/origin/feature", label: "same"),
        Option(reference: "refs/remotes/origin/main", label: "origin/main (remote)")
    ]

    @Test
    func defaultAndDuplicateLabelsUseReferenceIdentity() {
        let button = button()
        let coordinator = BranchTargetPopUpButton.Coordinator()
        let selection = Selection()
        coordinator.update(button, options: options, selection: selection.binding, isEnabled: true)
        #expect(button.itemTitles == ["Main checkout (default)", "main", "same", "same", "origin/main (remote)"])
        #expect(button.indexOfSelectedItem == 0)
        #expect(button.selectedItem?.representedObject == nil)
        #expect(button.accessibilityLabel() == "Merge target")
        #expect(button.cell?.accessibilityLabel() == "Merge target")
        for option in options {
            selection.value = option.reference
            coordinator.update(button, options: options, selection: selection.binding, isEnabled: true)
            #expect(button.selectedItem?.representedObject as? String == option.reference)
            #expect(button.title == option.label)
        }
        selection.value = nil
        coordinator.update(button, options: options, selection: selection.binding, isEnabled: true)
        #expect(button.indexOfSelectedItem == 0)
        #expect(selection.writes.isEmpty)
    }

    @Test
    func unavailableReferenceAppearsThenDisappearsWithoutDuplicateFallback() {
        let button = button()
        let coordinator = BranchTargetPopUpButton.Coordinator()
        let saved = "refs/heads/deleted"
        let selection = Selection(saved)
        coordinator.update(button, options: options, selection: selection.binding, isEnabled: true)
        #expect(button.numberOfItems == options.count + 2)
        #expect(button.title == saved)
        #expect(button.selectedItem?.representedObject as? String == saved)
        let reappeared = options + [Option(reference: saved, label: "restored")]
        coordinator.update(button, options: reappeared, selection: selection.binding, isEnabled: true)
        #expect(button.numberOfItems == reappeared.count + 1)
        #expect(button.title == "restored")
        coordinator.update(button, options: options, selection: selection.binding, isEnabled: true)
        #expect(button.title == saved)
        selection.value = options[0].reference
        coordinator.update(button, options: options, selection: selection.binding, isEnabled: true)
        #expect(button.numberOfItems == options.count + 1)
        #expect(!button.itemTitles.contains(saved))
        selection.value = "refs/heads/another-missing"
        coordinator.update(button, options: [], selection: selection.binding, isEnabled: true)
        #expect(button.itemTitles == ["Main checkout (default)", "refs/heads/another-missing"])
        selection.value = nil
        coordinator.update(button, options: [], selection: selection.binding, isEnabled: true)
        #expect(button.itemTitles == ["Main checkout (default)"])
        #expect(selection.writes.isEmpty)
    }

    @Test
    func reorderingAndRemovingOptionsPreservesSelection() {
        let button = button()
        let coordinator = BranchTargetPopUpButton.Coordinator()
        let selected = options[2].reference
        let selection = Selection(selected)
        coordinator.update(button, options: options, selection: selection.binding, isEnabled: true)
        coordinator.update(button, options: options.reversed(), selection: selection.binding, isEnabled: true)
        #expect(button.indexOfSelectedItem == 2)
        #expect(button.selectedItem?.representedObject as? String == selected)
        coordinator.update(button, options: [], selection: selection.binding, isEnabled: true)
        #expect(button.itemTitles == ["Main checkout (default)", selected])
        #expect(button.selectedItem?.representedObject as? String == selected)
        #expect(selection.writes.isEmpty)
    }

    @Test
    func menuActionUsesFreshBindingAndDisabledControlDoesNotWrite() throws {
        let button = button()
        let coordinator = BranchTargetPopUpButton.Coordinator()
        let old = Selection()
        let current = Selection()
        coordinator.update(button, options: options, selection: old.binding, isEnabled: true)
        coordinator.update(button, options: options, selection: current.binding, isEnabled: true)
        // Exercise AppKit's menu -> popup cell -> control target/action routing,
        // not just a direct call to the coordinator after selecting an index.
        let menu = try #require(button.menu)
        menu.performActionForItem(at: 3)
        #expect(old.writes.isEmpty)
        #expect(current.writes == [options[2].reference])
        menu.performActionForItem(at: 0)
        #expect(current.writes == [options[2].reference, nil])
        coordinator.update(button, options: options, selection: current.binding, isEnabled: false)
        #expect(!button.isEnabled)
        button.selectItem(at: 1)
        coordinator.selectionChanged(button)
        #expect(current.writes.count == 2)
    }

    @Test
    func unchangedMenuRetainsItemIdentityAcrossSelectionAndEnabledUpdates() {
        let button = button()
        let coordinator = BranchTargetPopUpButton.Coordinator()
        let selection = Selection()
        coordinator.update(button, options: options, selection: selection.binding, isEnabled: true)
        let menu = button.menu
        let items = button.itemArray
        selection.value = options[2].reference
        coordinator.update(button, options: options, selection: selection.binding, isEnabled: false)
        #expect(button.menu === menu)
        #expect(zip(button.itemArray, items).allSatisfy { $0 === $1 })
        let renamed = [Option(reference: options[0].reference, label: "renamed")] + options.dropFirst()
        coordinator.update(button, options: renamed, selection: selection.binding, isEnabled: true)
        #expect(button.itemTitles[1] == "renamed")
        #expect(button.selectedItem?.representedObject as? String == options[2].reference)
    }

    @Test
    func hundredsOfLongTitlesFitHostedControlAndHonorEnvironment() throws {
        _ = NSApplication.shared
        let many = (0..<672).map {
            Option(reference: "refs/heads/branch-\($0)", label: String(repeating: "long-", count: 100) + "\($0)")
        }
        let host = NSHostingView(rootView:
            BranchTargetPopUpButton(options: many, selection: .constant(many[671].reference))
                .disabled(true)
                .frame(width: 180)
        )
        host.frame = NSRect(x: 0, y: 0, width: 180, height: 40)
        host.layoutSubtreeIfNeeded()
        let button = try #require(findButton(in: host))
        #expect(button.numberOfItems == 673)
        #expect(button.title == many[671].label)
        #expect(button.frame.width <= 180)
        #expect(button.intrinsicContentSize.width <= 240)
        #expect(button.cell?.lineBreakMode == .byTruncatingMiddle)
        #expect(!button.isEnabled)
        #expect(button.accessibilityLabel() == "Merge target")
        #expect(button.cell?.isAccessibilityElement() == true)
        #expect(button.cell?.accessibilityRole() == .popUpButton)
        #expect(button.cell?.accessibilityLabel() == "Merge target")
    }

    private func findButton(in view: NSView) -> NSPopUpButton? {
        if let button = view as? NSPopUpButton { return button }
        return view.subviews.lazy.compactMap { findButton(in: $0) }.first
    }
}
