import AppKit
import SwiftUI

/// Shared by the toolbar, Actions menu, and row context menu.
struct OpenWithMenu: View {
    let store: AppStore
    let ids: Set<String>

    var body: some View {
        Menu("Open With") {
            ForEach(store.editorApplications) { application in
                Button { [ids] in
                    Task { await store.openInEditor(ids, application: application) }
                } label: {
                    Label {
                        Text(application.name)
                    } icon: {
                        Image(nsImage: store.editorIcon(for: application))
                    }
                }
            }
            if !store.editorApplications.isEmpty { Divider() }
            Button("Other…") { [ids] in
                Task { await store.chooseAndOpenEditor(ids) }
            }
        }
        .help("Open with an application and remember it as your preferred editor")
        .disabled(!store.canOpenInEditor(ids))
    }

    static func menuIcon(_ source: NSImage) -> NSImage {
        // Native menus use the NSImage's logical size, not SwiftUI layout modifiers.
        // Copy before resizing so NSWorkspace's shared icon is left untouched.
        let image = source.copy() as! NSImage
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}
