import AppKit
import UniformTypeIdentifiers

enum EditorApplicationPicker {
    @MainActor
    static func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Open With"
        panel.message = "Choose an application to open worktree folders. DevBox will remember it as your preferred editor."
        panel.prompt = "Open"
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        return panel.runModal() == .OK ? panel.url : nil
    }
}
