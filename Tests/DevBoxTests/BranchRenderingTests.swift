import AppKit
import Observation
import ScreenCaptureKit
import SwiftUI
import Testing
import Vision
@testable import DevBox
import DevBoxCore

@MainActor
private final class RenderingBranchSettings: SettingsPersisting {
    var value = AppSettings()
    func load() throws -> AppSettings { value }
    func save(_ settings: AppSettings) throws { value = settings }
}

@MainActor
private final class RenderingGitHubCredentials: GitHubCredentialsPersisting {
    var token: GitHubToken? = GitHubToken(accessToken: "rendering-fixture")
    func load() throws -> GitHubToken? { token }
    func save(_ token: GitHubToken) throws { self.token = token }
    func remove() throws { token = nil }
}

@Suite(.serialized)
@MainActor
struct BranchRenderingTests {
    @Test func cellsRenderWithoutEnvironmentOrNetwork() throws {
        _ = NSApplication.shared
        let branch = ManagedBranch(
            reference: "refs/heads/topic", name: "topic", commit: "abc123",
            committerName: "Pat", committerEmail: "pat@example.com",
            protectedReason: "Current branch"
        )
        let row = BranchRowPresentation(branch)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: HStack {
            BranchNameCell(row: row)
            BranchCommitterCell(row: row, gravatarEnabled: false)
            BranchAvatar(url: nil)
            BranchGitHubCell(url: nil)
        })
        window.contentView = host
        defer { window.close() }
        host.frame = NSRect(x: 0, y: 0, width: 660, height: 100)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(bitmap.pixelsWide > 0)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func fullBranchViewAndMixedConfirmationRenderWithoutNetwork(prFails: Bool) async throws {
        _ = NSApplication.shared
        let persistence = RenderingBranchSettings()
        persistence.value.projects = [.init(id: "/test/repo/.git", name: "Example", path: "/Projects/example")]
        let branches = [
            ManagedBranch(
                reference: "refs/heads/main", name: "main", commit: "0123456789",
                committerName: "Taylor", committerEmail: "taylor@example.invalid",
                committedAt: Date(timeIntervalSince1970: 1_700_000_000), protectedReason: "Checked out in a worktree."
            ),
            ManagedBranch(
                reference: "refs/heads/feature/branch-manager", name: "feature/branch-manager", commit: "abcdef1234",
                committerName: "Morgan", committerEmail: "morgan@example.invalid",
                committedAt: Date(timeIntervalSince1970: 1_690_000_000),
                githubURL: URL(string: "https://github.com/example/repo/tree/feature%2Fbranch-manager")
            ),
            ManagedBranch(
                reference: "refs/remotes/origin/feature/branch-manager", name: "feature/branch-manager", commit: "abcdef1234",
                committerName: "Morgan", committerEmail: "morgan@example.invalid",
                committedAt: Date(timeIntervalSince1970: 1_690_000_000),
                remoteName: "origin", remoteBranchName: "feature/branch-manager",
                githubURL: URL(string: "https://github.com/example/repo/tree/feature%2Fbranch-manager")
            )
        ]
        let github = GitHubSession(
            credentials: RenderingGitHubCredentials(),
            pullRequests: GitHubPullRequestCache(
                repositories: { repository, _ in [repository] },
                lookup: { branches, _, _ in
                    let request = GitHubPullRequest(
                        number: 42, title: "Add branch management",
                        url: URL(string: "https://github.com/example/repo/pull/42")!,
                        state: .merged, createdAt: Date(timeIntervalSince1970: 1_700_000_000)
                    )
                    return GitHubPullRequestBatch(results: Dictionary(uniqueKeysWithValues: branches.map {
                        ($0, prFails ? .failure(.notFound) : .success(request))
                    }))
                }
            ),
            loadUser: { _ in GitHubUser(login: "example", id: 1) },
            openBrowser: { _ in }
        )
        await github.restore()
        let store = AppStore(
            persistence: persistence, github: github, listManagedBranches: { _ in branches },
            editorLauncher: inertEditorLauncher()
        )
        store.projectSection = .branches
        for await refreshing in Observations({ store.isRefreshing }) {
            if !refreshing { break }
        }
        let defaultsName = "devbox.branch-rendering.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defaults.set(false, forKey: "devbox.gravatarEnabled")
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        for width in [900.0, 1140.0] {
            let size = NSSize(width: width, height: 720)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .resizable], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: ContentView(theme: .constant(.light))
                .environment(store).defaultAppStorage(defaults)
                .environment(\.locale, Locale(identifier: "en_US"))
                .frame(width: width, height: 720))
            window.contentView = host
            defer { window.close() }
            host.frame = NSRect(origin: .zero, size: size)
            window.orderFront(nil)
            // NavigationSplitView installs its native children on the next
            // application run-loop pass, not during the initial layout call.
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            #expect(bitmap.pixelsWide >= Int(width))
            let table = try #require(tables(in: host).first {
                $0.numberOfRows == branches.count && $0.tableColumns.count == 5
            })
            let list = try #require(store.selectedProjectSession?.branchList)
            for (index, column) in [
                BranchRowComparator.Column.branch, .date, .committer
            ].enumerated() {
                let descriptor = try #require(table.tableColumns[index].sortDescriptorPrototype)
                for direction in [SortOrder.forward, .reverse] {
                    table.sortDescriptors = [direction == .forward
                        ? descriptor : descriptor.reversedSortDescriptor as! NSSortDescriptor]
                    try await Task.sleep(for: .milliseconds(50))
                    #expect(list.sortOrder.first?.column == column)
                    #expect(list.sortOrder.first?.order == direction)
                    #expect(table.numberOfRows == branches.count)
                }
            }
            #expect(table.tableColumns[3].sortDescriptorPrototype == nil)
            #expect(table.tableColumns[4].sortDescriptorPrototype == nil)
            // Native table membership and cacheDisplay can pass while SwiftUI's
            // on-screen content is completely blank. Opt in on a GUI session:
            // DEVBOX_UI_TESTS=1 sh scripts/test.sh --filter BranchRenderingTests
            if ProcessInfo.processInfo.environment["DEVBOX_UI_TESTS"] == "1" {
                let image = try await capture(window)
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["en-US"]
                try VNImageRequestHandler(cgImage: image).perform([request])
                let text = request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n") ?? ""
                for label in ["Projects", "Branches", "Latest commit", "Taylor", "Fetch & Prune"] {
                    #expect(text.contains(label), "Visible window is missing \(label) at width \(width). OCR: \(text)")
                }
                if width == 1140 {
                    let labels = prFails ? ["Latest PR", "Unavailable", "1 PR lookup failed"] : ["Latest PR", "Merged", "PRs cached"]
                    for label in labels {
                        #expect(text.contains(label), "Visible PR UI is missing \(label). OCR: \(text)")
                    }
                }
                if let path = ProcessInfo.processInfo.environment["DEVBOX_BRANCH_SCREENSHOT"] {
                    let screenshot = NSBitmapImageRep(cgImage: image)
                    let url = URL(fileURLWithPath: path).deletingPathExtension()
                        .appendingPathExtension("\(prFails ? "unavailable." : "")\(Int(width)).png")
                    try #require(screenshot.representation(using: .png, properties: [:])).write(to: url)
                }
            }
        }

        let project = try #require(store.selectedProject)
        let request = DeletionRequest(items: .branches(project, Array(branches.dropFirst())))
        let host = NSHostingView(rootView: DeletionConfirmation(request: request).environment(store))
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 600)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width >= 560)
    }

    @Test(.timeLimit(.minutes(1)))
    func gitHubFailureDetailsExposeRepositoryAndRecoveryWithoutNetwork() async throws {
        _ = NSApplication.shared
        #expect(NSImage(systemSymbolName: "arrow.triangle.pull", accessibilityDescription: nil) != nil)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 500),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: GitHubPullRequestFailureDetails(
            failures: [.init(repository: "example/project", message: GitHubPullRequestError.notFound.localizedDescription,
                             branchCount: 3)],
            canRetry: true, retry: {}, showAccount: {}
        ).environment(\.locale, Locale(identifier: "en_US")).lineLimit(1))
        window.contentView = host
        defer { window.close() }
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width == 380)
        if ProcessInfo.processInfo.environment["DEVBOX_UI_TESTS"] == "1" {
            let image = try await capture(window)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: image).perform([request])
            let text = request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n") ?? ""
            for label in ["Pull requests unavailable", "example/project", "3 affected branches", "NOT_FOUND", "Retry PRs"] {
                #expect(text.contains(label), "PR failure details are missing \(label). OCR: \(text)")
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func gitHubAccountSheetRendersDeviceCodeWithoutNetwork() async throws {
        _ = NSApplication.shared
        let session = GitHubSession(
            credentials: RenderingGitHubCredentials(),
            startAuthorization: {
                GitHubDeviceAuthorization(
                    deviceCode: "fixture-device", userCode: "ABCD-EFGH",
                    verificationURL: URL(string: "https://github.com/login/device")!,
                    expiresAt: Date().addingTimeInterval(900), interval: 5
                )
            },
            poll: { _ in
                try await Task.sleep(for: .seconds(60))
                throw CancellationError()
            },
            openBrowser: { _ in }
        )
        session.beginSignIn()
        defer { session.cancelSignIn() }
        for await ready in Observations({ session.authorization != nil }) {
            if ready { break }
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 500),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: GitHubAccountView(session: session)
            .environment(\.locale, Locale(identifier: "en_US")))
        window.contentView = host
        defer { window.close() }
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width == 480)
        if ProcessInfo.processInfo.environment["DEVBOX_UI_TESTS"] == "1" {
            let image = try await capture(window)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: image).perform([request])
            let text = request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n") ?? ""
            for label in ["GitHub Account", "ABCD-EFGH", "Copy code", "Open GitHub", "Cancel sign-in"] {
                #expect(text.contains(label), "Account sheet is missing \(label). OCR: \(text)")
            }
        }
    }

    private func tables(in view: NSView) -> [NSTableView] {
        (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap { tables(in: $0) }
    }

    private func capture(_ window: NSWindow) async throws -> CGImage {
        // Own-process capture needs no screen-recording consent and never captures
        // other applications or the desktop, even when they overlap this window.
        let content = try await SCShareableContent.currentProcess
        let target = try #require(content.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width * 2)
        configuration.height = Int(window.frame.height * 2)
        configuration.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
}
