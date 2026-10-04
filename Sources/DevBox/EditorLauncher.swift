import AppKit
import UniformTypeIdentifiers

struct EditorApplication: Codable, Hashable, Identifiable {
    let url: URL
    let name: String
    let bundleIdentifier: String?

    var id: URL { url }
}

/// Discovers native folder handlers and opens folders without command-line tools.
@MainActor
struct EditorLauncher {
    enum Failure: LocalizedError, Equatable {
        case missingDirectory(String)
        case notDirectory(String)
        case applicationNotInstalled(String)

        var errorDescription: String? {
            switch self {
            case .missingDirectory(let path):
                "The worktree folder no longer exists at “\(path)”. Restore the folder or refresh the worktree list before opening it."
            case .notDirectory(let path):
                "The worktree path “\(path)” is not a folder. Choose an existing worktree folder."
            case .applicationNotInstalled(let name):
                "“\(name)” is no longer installed at its saved location. Reinstall the app or choose another application with Open With → Other…."
            }
        }
    }

    private let findApplications: @MainActor () -> [URL]
    private let describeApplication: @MainActor (URL) -> EditorApplication?
    private let findApplication: @MainActor (String) -> URL?
    private let openURLs: @MainActor ([URL], URL, NSWorkspace.OpenConfiguration) async throws -> Void

    init(
        findApplications: @escaping @MainActor () -> [URL] = {
            NSWorkspace.shared.urlsForApplications(toOpen: UTType.folder)
        },
        describeApplication: @escaping @MainActor (URL) -> EditorApplication? = {
            EditorLauncher.describeInstalledApplication(at: $0)
        },
        findApplication: @escaping @MainActor (String) -> URL? = {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        },
        openURLs: @escaping @MainActor ([URL], URL, NSWorkspace.OpenConfiguration) async throws -> Void = {
            _ = try await NSWorkspace.shared.open($0, withApplicationAt: $1, configuration: $2)
        }
    ) {
        self.findApplications = findApplications
        self.describeApplication = describeApplication
        self.findApplication = findApplication
        self.openURLs = openURLs
    }

    func applicationsForFolders() -> [EditorApplication] {
        var seen: Set<URL> = []
        return findApplications().compactMap { url in
            guard let application = application(at: url),
                  seen.insert(application.url.standardizedFileURL).inserted else { return nil }
            return application
        }.sorted { lhs, rhs in
            let order = lhs.name.localizedStandardCompare(rhs.name)
            return order == .orderedSame
                ? lhs.url.absoluteString < rhs.url.absoluteString
                : order == .orderedAscending
        }
    }

    func application(at url: URL) -> EditorApplication? {
        describeApplication(url)
    }

    func application(withBundleIdentifier identifier: String) -> EditorApplication? {
        guard !identifier.isEmpty,
              let url = findApplication(identifier),
              let application = application(at: url),
              application.bundleIdentifier == identifier else { return nil }
        return application
    }

    func resolvedApplication(_ application: EditorApplication) -> EditorApplication? {
        // Keep the chosen installation when multiple copies share a bundle identifier.
        if let installed = self.application(at: application.url),
           installed.bundleIdentifier == application.bundleIdentifier {
            return installed
        }
        guard let identifier = application.bundleIdentifier else { return nil }
        return self.application(withBundleIdentifier: identifier)
    }

    private static func describeInstalledApplication(at url: URL) -> EditorApplication? {
        // Bundle(url:) caches metadata by path, even after another app replaces it.
        // Read identity and executable metadata afresh before trusting a saved location.
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        guard url.isFileURL,
              let values = try? url.resourceValues(forKeys: [.isApplicationKey, .isDirectoryKey]),
              values.isApplication == true, values.isDirectory == true,
              let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let executableName = info["CFBundleExecutable"] as? String, !executableName.isEmpty,
              !executableName.contains("/") else { return nil }
        let executable = contents.appendingPathComponent("MacOS").appendingPathComponent(executableName)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        let name = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? FileManager.default.displayName(atPath: url.path)
        return EditorApplication(
            url: url.standardizedFileURL,
            name: name,
            bundleIdentifier: info["CFBundleIdentifier"] as? String
        )
    }

    func open(worktreePath: String, application: EditorApplication) async throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: worktreePath, isDirectory: &isDirectory) else {
            throw Failure.missingDirectory(worktreePath)
        }
        guard isDirectory.boolValue else {
            throw Failure.notDirectory(worktreePath)
        }
        guard let installed = resolvedApplication(application) else {
            throw Failure.applicationNotInstalled(application.name)
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        try await openURLs(
            [URL(fileURLWithPath: worktreePath, isDirectory: true)],
            installed.url,
            configuration
        )
    }
}
