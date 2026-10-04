import AppKit
import Testing
@testable import DevBox

@MainActor
struct ZedLauncherTests {
    private let applicationURL = URL(fileURLWithPath: "/Applications/Zed.app", isDirectory: true)

    /// Keep fixtures inside the checkout, including when SwiftPM runs from another directory.
    private func makeFixture() throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = root.appendingPathComponent(".build/test-temp/zed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        return fixture
    }

    @Test
    func opensIntactDirectoryInStableZedAndActivates() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let directory = fixture.appendingPathComponent("space café 日本語 ' \" ; $(touch nope) &", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        var identifiers: [String] = []
        var opened = false
        let launcher = ZedLauncher(
            findApplication: {
                identifiers.append($0)
                return applicationURL
            },
            openURLs: { urls, application, configuration in
                opened = true
                #expect(urls == [directory])
                #expect(urls.first?.path == directory.path)
                #expect(application == applicationURL)
                #expect(configuration.activates)
            }
        )

        try await launcher.open(worktreePath: directory.path)

        #expect(identifiers == ["dev.zed.Zed"])
        #expect(opened)
    }

    @Test
    func missingZedDoesNotOpenAnotherApplication() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let launcher = ZedLauncher(
            findApplication: { identifier in
                #expect(identifier == "dev.zed.Zed")
                return nil
            },
            openURLs: { _, _, _ in Issue.record("Must not open without Zed") }
        )

        await #expect(throws: ZedLauncher.Failure.zedNotInstalled) {
            try await launcher.open(worktreePath: fixture.path)
        }
        #expect(ZedLauncher.Failure.zedNotInstalled.localizedDescription.contains("Install"))
    }

    @Test
    func missingDirectoryAndRegularFileAreRejectedBeforeDiscovery() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let missing = fixture.appendingPathComponent("missing")
        let file = fixture.appendingPathComponent("file")
        try Data("not a directory".utf8).write(to: file)
        let launcher = ZedLauncher(
            findApplication: { _ in
                Issue.record("Invalid paths must be rejected before app discovery")
                return applicationURL
            },
            openURLs: { _, _, _ in Issue.record("Must not open invalid paths") }
        )

        await #expect(throws: ZedLauncher.Failure.missingDirectory(missing.path)) {
            try await launcher.open(worktreePath: missing.path)
        }
        await #expect(throws: ZedLauncher.Failure.notDirectory(file.path)) {
            try await launcher.open(worktreePath: file.path)
        }
        #expect(ZedLauncher.Failure.missingDirectory(missing.path).localizedDescription.contains(missing.path))
        #expect(ZedLauncher.Failure.notDirectory(file.path).localizedDescription.contains("not a folder"))
    }

    @Test
    func directoryIsValidatedAgainOnEveryInvocation() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let directory = fixture.appendingPathComponent("worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        var openCount = 0
        let launcher = ZedLauncher(
            findApplication: { _ in applicationURL },
            openURLs: { _, _, _ in openCount += 1 }
        )
        try await launcher.open(worktreePath: directory.path)
        try FileManager.default.removeItem(at: directory)

        await #expect(throws: ZedLauncher.Failure.missingDirectory(directory.path)) {
            try await launcher.open(worktreePath: directory.path)
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
        let launcher = ZedLauncher(
            findApplication: { _ in applicationURL },
            openURLs: { _, _, _ in throw failure }
        )

        do {
            try await launcher.open(worktreePath: fixture.path)
            Issue.record("Expected the native launch error")
        } catch {
            #expect((error as NSError) === failure)
        }
    }
}
