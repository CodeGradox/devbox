import AppKit

/// Opens folders in stable Zed without relying on its optional command-line tool.
@MainActor
struct ZedLauncher {
    enum Failure: LocalizedError, Equatable {
        case missingDirectory(String)
        case notDirectory(String)
        case zedNotInstalled

        var errorDescription: String? {
            switch self {
            case .missingDirectory(let path):
                "The worktree folder no longer exists at “\(path)”. Restore the folder or refresh the worktree list before opening it."
            case .notDirectory(let path):
                "The worktree path “\(path)” is not a folder. Choose an existing worktree folder."
            case .zedNotInstalled:
                "Zed is not installed. Install the stable Zed app from https://zed.dev and try again."
            }
        }
    }

    private let findApplication: @MainActor (String) -> URL?
    private let openURLs: @MainActor ([URL], URL, NSWorkspace.OpenConfiguration) async throws -> Void

    init(
        findApplication: @escaping @MainActor (String) -> URL? = {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        },
        openURLs: @escaping @MainActor ([URL], URL, NSWorkspace.OpenConfiguration) async throws -> Void = {
            _ = try await NSWorkspace.shared.open($0, withApplicationAt: $1, configuration: $2)
        }
    ) {
        self.findApplication = findApplication
        self.openURLs = openURLs
    }

    func open(worktreePath: String) async throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: worktreePath, isDirectory: &isDirectory) else {
            throw Failure.missingDirectory(worktreePath)
        }
        guard isDirectory.boolValue else {
            throw Failure.notDirectory(worktreePath)
        }
        guard let applicationURL = findApplication("dev.zed.Zed") else {
            throw Failure.zedNotInstalled
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        try await openURLs(
            [URL(fileURLWithPath: worktreePath, isDirectory: true)],
            applicationURL,
            configuration
        )
    }
}
