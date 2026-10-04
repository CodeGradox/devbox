import AppKit
import Testing
@testable import DevBox

@MainActor
struct EditorLauncherTests {
    private let editor = EditorApplication(
        url: URL(fileURLWithPath: "/Applications/Folder Editor.app", isDirectory: true),
        name: "Folder Editor",
        bundleIdentifier: "example.folder-editor"
    )

    private func makeFixture() throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = root.appendingPathComponent(".build/test-temp/editor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        return fixture
    }

    private func makeApplication(at url: URL, name: String, identifier: String) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        let executable = contents.appendingPathComponent("MacOS/Editor")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        let info = [
            "CFBundlePackageType": "APPL", "CFBundleExecutable": "Editor",
            "CFBundleIdentifier": identifier, "CFBundleDisplayName": name
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    @Test
    func realBundleReplacementDoesNotReuseCachedIdentityOrExecutable() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let original = fixture.appendingPathComponent("Original.app", isDirectory: true)
        let moved = fixture.appendingPathComponent("Moved.app", isDirectory: true)
        try makeApplication(at: original, name: "Original", identifier: "example.original")
        var recoveredURL: URL?
        var opened: [URL] = []
        let launcher = EditorLauncher(
            findApplication: { _ in recoveredURL },
            openURLs: { _, url, _ in opened.append(url) }
        )
        let saved = try #require(launcher.application(at: original))
        // Other framework code may have populated Foundation's per-path metadata cache.
        #expect(Bundle(url: original)?.bundleIdentifier == "example.original")
        try FileManager.default.moveItem(at: original, to: moved)
        try makeApplication(at: original, name: "Unrelated", identifier: "example.unrelated")

        #expect(launcher.application(at: original)?.bundleIdentifier == "example.unrelated")
        #expect(launcher.application(at: original)?.name == "Unrelated")
        #expect(launcher.resolvedApplication(saved) == nil)
        await #expect(throws: EditorLauncher.Failure.applicationNotInstalled("Original")) {
            try await launcher.open(worktreePath: fixture.path, application: saved)
        }
        recoveredURL = moved
        try await launcher.open(worktreePath: fixture.path, application: saved)
        #expect(opened == [moved])

        // Changing the executable in-place must also invalidate the old description.
        let info = [
            "CFBundlePackageType": "APPL", "CFBundleExecutable": "Missing",
            "CFBundleIdentifier": "example.original", "CFBundleDisplayName": "Original"
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: moved.appendingPathComponent("Contents/Info.plist"))
        #expect(launcher.resolvedApplication(saved) == nil)
    }

    @Test
    func opensIntactDirectoryInChosenApplicationAndActivates() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let directory = fixture.appendingPathComponent("space café 日本語 ' \" ; $(touch nope) & # %", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        var opened = false
        let launcher = EditorLauncher(
            describeApplication: { $0 == editor.url ? editor : nil },
            findApplication: { _ in
                Issue.record("An installed selection must win over bundle-ID discovery")
                return nil
            },
            openURLs: { urls, application, configuration in
                opened = true
                #expect(urls == [directory])
                #expect(urls.first?.path == directory.path)
                #expect(application == editor.url)
                #expect(configuration.activates)
            }
        )
        try await launcher.open(worktreePath: directory.path, application: editor)
        #expect(opened)
        #expect(try JSONDecoder().decode(EditorApplication.self, from: JSONEncoder().encode(editor)) == editor)
        #expect(editor.id == editor.url)
    }

    @Test
    func discoveryDescribesDeduplicatesAndSortsWithStableTies() {
        let alpha = EditorApplication(url: URL(fileURLWithPath: "/A.app"), name: "Alpha", bundleIdentifier: nil)
        let first = EditorApplication(url: URL(fileURLWithPath: "/B.app"), name: "Editor", bundleIdentifier: "b")
        let second = EditorApplication(url: URL(fileURLWithPath: "/C.app"), name: "Editor", bundleIdentifier: "c")
        let invalid = URL(fileURLWithPath: "/invalid.app")
        let apps = [alpha, first, second]
        let launcher = EditorLauncher(
            findApplications: { [second.url, invalid, first.url, alpha.url, first.url] },
            describeApplication: { url in apps.first { $0.url == url } },
            openURLs: { _, _, _ in Issue.record("Discovery must not launch") }
        )
        #expect(launcher.applicationsForFolders() == apps)
    }

    @Test
    func movedApplicationRecoversByIdentityEvenWhenOldPathIsReplaced() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let moved = EditorApplication(
            url: fixture.appendingPathComponent("Moved.app"),
            name: "Renamed Editor",
            bundleIdentifier: editor.bundleIdentifier
        )
        let unrelated = EditorApplication(url: editor.url, name: "Other", bundleIdentifier: "example.other")
        var oldPathOccupied = false
        var opened: [URL] = []
        let launcher = EditorLauncher(
            describeApplication: { url in
                if url == moved.url { return moved }
                return oldPathOccupied && url == editor.url ? unrelated : nil
            },
            findApplication: { identifier in
                #expect(identifier == editor.bundleIdentifier)
                return moved.url
            },
            openURLs: { _, url, _ in opened.append(url) }
        )
        #expect(launcher.resolvedApplication(editor) == moved)
        oldPathOccupied = true
        #expect(launcher.resolvedApplication(editor) == moved)
        try await launcher.open(worktreePath: fixture.path, application: editor)
        #expect(opened == [moved.url])
    }

    @Test
    func missingOrReplacedApplicationNeverLaunchesUnrelatedApp() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        var installed: EditorApplication? = nil
        let launcher = EditorLauncher(
            describeApplication: { _ in installed },
            findApplication: { _ in editor.url },
            openURLs: { _, _, _ in Issue.record("Must not substitute another app") }
        )
        for replacement in [nil, EditorApplication(url: editor.url, name: "Other", bundleIdentifier: "other")] {
            installed = replacement
            #expect(launcher.resolvedApplication(editor) == nil)
            await #expect(throws: EditorLauncher.Failure.applicationNotInstalled(editor.name)) {
                try await launcher.open(worktreePath: fixture.path, application: editor)
            }
        }
        #expect(EditorLauncher.Failure.applicationNotInstalled(editor.name).localizedDescription.contains("choose another"))
    }

    @Test
    func applicationWithoutBundleIdentifierUsesOnlySavedPath() {
        let anonymous = EditorApplication(url: editor.url, name: "Anonymous", bundleIdentifier: nil)
        var installed: EditorApplication? = anonymous
        let launcher = EditorLauncher(
            describeApplication: { _ in installed },
            findApplication: { _ in Issue.record("Cannot recover without identity"); return nil }
        )
        #expect(launcher.resolvedApplication(anonymous) == anonymous)
        installed = editor
        #expect(launcher.resolvedApplication(anonymous) == nil)
        installed = nil
        #expect(launcher.resolvedApplication(anonymous) == nil)
    }

    @Test
    func missingDirectoryAndRegularFileAreRejectedBeforeDiscovery() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let missing = fixture.appendingPathComponent("missing")
        let file = fixture.appendingPathComponent("file")
        try Data("not a directory".utf8).write(to: file)
        let launcher = EditorLauncher(
            describeApplication: { _ in Issue.record("Validate folder first"); return nil },
            findApplication: { _ in Issue.record("Validate folder first"); return nil },
            openURLs: { _, _, _ in Issue.record("Must not open invalid paths") }
        )
        await #expect(throws: EditorLauncher.Failure.missingDirectory(missing.path)) {
            try await launcher.open(worktreePath: missing.path, application: editor)
        }
        await #expect(throws: EditorLauncher.Failure.notDirectory(file.path)) {
            try await launcher.open(worktreePath: file.path, application: editor)
        }
        #expect(EditorLauncher.Failure.missingDirectory(missing.path).localizedDescription.contains(missing.path))
        #expect(EditorLauncher.Failure.notDirectory(file.path).localizedDescription.contains("not a folder"))
    }

    @Test
    func directoryAndApplicationAreValidatedAgainOnEveryInvocation() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let directory = fixture.appendingPathComponent("worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        var installed = true
        var openCount = 0
        let launcher = EditorLauncher(
            describeApplication: { _ in installed ? editor : nil },
            findApplication: { _ in nil },
            openURLs: { _, _, _ in openCount += 1 }
        )
        try await launcher.open(worktreePath: directory.path, application: editor)
        installed = false
        await #expect(throws: EditorLauncher.Failure.applicationNotInstalled(editor.name)) {
            try await launcher.open(worktreePath: directory.path, application: editor)
        }
        try FileManager.default.removeItem(at: directory)
        await #expect(throws: EditorLauncher.Failure.missingDirectory(directory.path)) {
            try await launcher.open(worktreePath: directory.path, application: editor)
        }
        #expect(openCount == 1)
    }

    @Test
    func nativeLaunchFailureIsPropagatedUnchanged() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let failure = NSError(domain: NSCocoaErrorDomain, code: 1234, userInfo: [
            NSLocalizedDescriptionKey: "Native launch failed"
        ])
        let launcher = EditorLauncher(
            describeApplication: { _ in editor },
            openURLs: { _, _, _ in throw failure }
        )
        do {
            try await launcher.open(worktreePath: fixture.path, application: editor)
            Issue.record("Expected the native launch error")
        } catch {
            #expect((error as NSError) === failure)
        }
    }

    @Test
    func nativeDescriptionRejectsNonApplicationsAndReadsRealBundleMetadata() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let app = fixture.appendingPathComponent("Sample.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let executable = contents.appendingPathComponent("MacOS/Sample")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        let info: [String: String] = [
            "CFBundlePackageType": "APPL", "CFBundleExecutable": "Sample",
            "CFBundleIdentifier": "example.sample", "CFBundleName": "Sample",
            "CFBundleDisplayName": "Sample Display"
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        // Only a fixture executable: tests never ask NSWorkspace to launch it.
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let launcher = EditorLauncher(openURLs: { _, _, _ in Issue.record("Must not launch fixtures") })
        #expect(launcher.application(at: app) == EditorApplication(
            url: app, name: "Sample Display", bundleIdentifier: "example.sample"
        ))
        #expect(launcher.application(at: fixture) == nil)
        #expect(launcher.application(at: executable) == nil)
        #expect(launcher.application(at: fixture.appendingPathComponent("Missing.app")) == nil)
        #expect(launcher.application(at: URL(string: "https://example.com/Sample.app")!) == nil)
    }
}
