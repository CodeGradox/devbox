import SwiftUI

/// Previous implementation, retained only as the memory benchmark's A/B control.
/// The script substitutes this for the AppKit-backed production component while
/// keeping the surrounding UI, fixtures, and external visible label identical.
struct BranchTargetPopUpButton: View {
    let options: [BranchPickerPresentation.Option]
    @Binding var selection: String?

    var body: some View {
        Picker("Merge target", selection: $selection) {
            Text("Main checkout (default)").tag(String?.none)
            ForEach(options) { target in
                Text(target.label).tag(Optional(target.reference))
            }
            if let saved = selection, !options.contains(where: { $0.reference == saved }) {
                Text(saved).tag(Optional(saved))
            }
        }
        .labelsHidden()
    }
}
