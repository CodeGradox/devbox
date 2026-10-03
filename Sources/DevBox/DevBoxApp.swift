import AppKit
import SwiftUI

@main
struct DevBoxApp: App {
    @State private var store = AppStore()
    @AppStorage("appearance") private var theme: AppTheme = .system
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("DevBox", id: "main") {
            ContentView(theme: $theme)
                .environment(store)
                .frame(minWidth: 900, minHeight: 560)
                .onChange(of: theme, initial: true) { _, selection in
                    // One app-wide override covers SwiftUI, sheets, and AppKit panels.
                    NSApp.appearance = selection.appearance
                }
                .task {
                    delegate.store = store
                    store.loadSelection()
                }
        }
        .defaultSize(width: 1140, height: 720)
        .commands {
            DevBoxCommands(store: store, theme: $theme)
        }
    }
}

/// Keep command enablement dependencies out of the app/scene body.
private struct DevBoxCommands: Commands {
    let store: AppStore
    @Binding var theme: AppTheme

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Add Project…") { store.addProject() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(store.isDeleting || store.isModalPresented)
            Button("Add MariaDB Connection…") {
                store.connectionEditor = .init()
            }
            .disabled(store.isDeleting || store.isModalPresented)
        }
        CommandGroup(replacing: .undoRedo) {}
        CommandGroup(after: .toolbar) {
            Menu("Appearance") {
                Picker("Appearance", selection: $theme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                .pickerStyle(.inline)
            }
        }
        CommandMenu("Actions") {
            Button("Refresh") { store.refresh() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(store.destination == nil || store.isDeleting || store.isModalPresented)
            Button("Delete Selected…", role: .destructive) { store.prepareDeletion() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!store.canDeleteSelection)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: AppStore?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard store?.isDeleting == true else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Deletion is still in progress"
        alert.informativeText = "Wait for the batch results before quitting DevBox."
        alert.addButton(withTitle: "Keep DevBox Open")
        alert.runModal()
        return .terminateCancel
    }
}
