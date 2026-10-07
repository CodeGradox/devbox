import Foundation
import Testing
@testable import DevBox
@testable import DevBoxCore

private enum EditorPreferenceFailure: Error { case expected }

@MainActor
private final class EditorPreferenceSettings: SettingsPersisting {
    var value = AppSettings()
    var writes = 0
    var failWrite = false

    func load() throws -> AppSettings { value }

    func save(_ settings: AppSettings) throws {
        writes += 1
        if failWrite { throw EditorPreferenceFailure.expected }
        value = settings
    }
}

@MainActor
private struct EditorPreferenceCredentials: CredentialsPersisting {
    func password(for id: UUID) throws -> String? { nil }
    func save(password: String, for id: UUID) throws {}
    func remove(for id: UUID) throws {}
}

/// All discovery, panels, launches, and background filesystem work are substituted.
@MainActor
private final class EditorPreferenceFixture {
    let persistence = EditorPreferenceSettings()
    let project = ProjectRecord(id: "editor-tests", name: "Editor Tests", path: "/editor-tests/main")
    let worktree = WorktreeRecord(
        path: "/editor-tests/linked", branch: "feature", head: "abc", isMain: false
    )
    let generic = EditorApplication(
        url: URL(fileURLWithPath: "/editor-tests/Writer.app"),
        name: "Writer", bundleIdentifier: "example.writer"
    )
    let zed = EditorApplication(
        url: URL(fileURLWithPath: "/editor-tests/Zed.app"),
        name: "Zed", bundleIdentifier: "dev.zed.Zed"
    )
    var installed: [EditorApplication] = []
    var advertised: [EditorApplication] = []
    var chosenURL: URL?
    var onChoose: (() -> Void)?
    var chooserCalls = 0
    var launches: [(path: String, application: EditorApplication)] = []
    var failLaunch = false

    var ids: Set<String> { [worktree.id] }

    init() {
        persistence.value.projects = [project]
    }

    func makeStore() -> AppStore {
        let launcher = EditorLauncher(
            findApplications: { self.advertised.map(\.url) },
            describeApplication: { url in self.installed.first { $0.url == url } },
            findApplication: { identifier in
                self.installed.first { $0.bundleIdentifier == identifier }?.url
            },
            openURLs: { _, _, _ in
                Issue.record("AppStore should use the injected launch operation.")
                throw EditorPreferenceFailure.expected
            }
        )
        let store = AppStore(
            persistence: persistence,
            credentials: EditorPreferenceCredentials(),
            sizeQueue: WorktreeSizeQueue(
                scan: { _ in DiskUsage(bytes: 0, fileCount: 0, unreadableCount: 0) },
                gitStorageScan: { _ in DiskUsage(bytes: 0, fileCount: 0, unreadableCount: 0) }
            ),
            inspectBranches: { _, _ in throw EditorPreferenceFailure.expected },
            editorLauncher: launcher,
            chooseEditor: {
                self.chooserCalls += 1
                self.onChoose?()
                return self.chosenURL
            },
            openWorktreeInEditor: { path, application in
                self.launches.append((path, application))
                if self.failLaunch { throw EditorPreferenceFailure.expected }
            }
        )
        // Select an already-loaded EMPTY inventory so loadSelection cannot run git
        // status on the fake paths. Populate the actionable row only afterward.
        store.projectSession(for: project)?.reconcile([], refresh: false)
        store.loadSelection()
        store.projectSession(for: project)?.reconcile([worktree], refresh: false)
        return store
    }
}

@Test @MainActor
func editorPreferenceDecodesLegacySettingsAndRoundTrips() throws {
    let legacy = Data(#"{"projects":[],"connections":[]}"#.utf8)
    var settings = try JSONDecoder().decode(AppSettings.self, from: legacy)
    #expect(settings.preferredEditor == nil)
    let editor = EditorApplication(
        url: URL(fileURLWithPath: "/editor-tests/My Editor.app"),
        name: "My Editor", bundleIdentifier: nil
    )
    settings.preferredEditor = editor
    let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
    #expect(decoded.preferredEditor == editor)
    #expect(decoded.preferredEditor?.id == editor.id)
}

@Test @MainActor
func editorQuickActionWithoutZedChoosesGenericApplication() async {
    let fixture = EditorPreferenceFixture()
    fixture.installed = [fixture.generic]
    fixture.chosenURL = fixture.generic.url
    let store = fixture.makeStore()
    #expect(store.preferredEditor == nil)
    #expect(store.openInEditorTitle == "Open in Editor…")
    #expect(store.canOpenInEditor(fixture.ids))

    await store.openInEditor(fixture.ids)

    #expect(fixture.chooserCalls == 1)
    #expect(fixture.launches.count == 1)
    #expect(fixture.launches.first?.path == fixture.worktree.path)
    #expect(fixture.launches.first?.application == fixture.generic)
    #expect(fixture.persistence.value.preferredEditor == fixture.generic)
    #expect(store.preferredEditor == fixture.generic)
    #expect(store.openInEditorTitle == "Open in Writer")
    // This app does not advertise folder support, but a successful choice stays in the menu.
    #expect(store.editorApplications.contains(fixture.generic))

    let reloaded = fixture.makeStore()
    #expect(reloaded.preferredEditor == fixture.generic)
    #expect(reloaded.editorApplications.contains(fixture.generic))
    await reloaded.openInEditor(fixture.ids)
    #expect(fixture.chooserCalls == 1)
    #expect(fixture.launches.count == 2)
    #expect(fixture.persistence.writes == 1)
}

@Test @MainActor
func installedZedIsOnlyAnUnpersistedInitialDefault() async {
    let fixture = EditorPreferenceFixture()
    fixture.installed = [fixture.zed, fixture.generic]
    let store = fixture.makeStore()
    #expect(store.preferredEditor == fixture.zed)
    #expect(store.openInEditorTitle == "Open in Zed")
    await store.openInEditor(fixture.ids)
    #expect(fixture.launches.first?.application == fixture.zed)
    #expect(fixture.chooserCalls == 0)
    #expect(fixture.persistence.writes == 0)
    #expect(fixture.persistence.value.preferredEditor == nil)

    await store.openInEditor(fixture.ids, application: fixture.generic)
    #expect(fixture.persistence.value.preferredEditor == fixture.generic)
    #expect(fixture.makeStore().preferredEditor == fixture.generic)
}

private func archiveUtility() -> EditorApplication {
    EditorApplication(
        url: URL(fileURLWithPath: "/editor-tests/Archive Utility.app"),
        name: "Archive Utility", bundleIdentifier: "com.apple.archiveutility"
    )
}

@Test @MainActor
func openWithListOmitsArchiveUtilityBecauseItWritesAnArchiveInsteadOfOpening() {
    let fixture = EditorPreferenceFixture()
    let archiver = archiveUtility()
    fixture.installed = [fixture.zed, archiver, fixture.generic]
    fixture.advertised = [archiver, fixture.zed, fixture.generic]
    let store = fixture.makeStore()
    #expect(archiver.archivesFolders)
    #expect(!fixture.zed.archivesFolders)
    #expect(store.editorApplications.map(\.name) == ["Writer", "Zed"])
}

@Test @MainActor
func savedArchiveUtilityPreferenceFallsBackWithoutRewritingSettings() async {
    let fixture = EditorPreferenceFixture()
    let archiver = archiveUtility()
    fixture.installed = [fixture.zed, archiver]
    fixture.advertised = [archiver, fixture.zed]
    fixture.persistence.value.preferredEditor = archiver
    let store = fixture.makeStore()
    #expect(store.preferredEditor == fixture.zed)
    #expect(store.openInEditorTitle == "Open in Zed")
    await store.openInEditor(fixture.ids)
    #expect(fixture.launches.map(\.application) == [fixture.zed])
    #expect(fixture.persistence.writes == 0)
    #expect(fixture.persistence.value.preferredEditor == archiver)

    // With nothing else to fall back to, the toolbar asks instead of archiving.
    let bare = EditorPreferenceFixture()
    bare.installed = [archiver]
    bare.advertised = [archiver]
    bare.persistence.value.preferredEditor = archiver
    let bareStore = bare.makeStore()
    #expect(bareStore.preferredEditor == nil)
    #expect(bareStore.openInEditorTitle == "Open in Editor…")
    #expect(bareStore.editorApplications.isEmpty)
}

@Test @MainActor
func failedEditorLaunchDoesNotChangePreference() async {
    let fixture = EditorPreferenceFixture()
    fixture.installed = [fixture.zed, fixture.generic]
    fixture.persistence.value.preferredEditor = fixture.zed
    fixture.failLaunch = true
    let store = fixture.makeStore()

    await store.openInEditor(fixture.ids, application: fixture.generic)

    #expect(fixture.launches.count == 1)
    #expect(fixture.persistence.writes == 0)
    #expect(fixture.persistence.value.preferredEditor == fixture.zed)
    #expect(store.preferredEditor == fixture.zed)
    #expect(store.errorMessage?.contains("Could not open") == true)
    #expect(store.errorMessage?.contains(fixture.generic.name) == true)
}

@Test @MainActor
func failedEditorPreferenceSaveReportsSuccessfulLaunchAndKeepsOldPreference() async {
    let fixture = EditorPreferenceFixture()
    fixture.installed = [fixture.zed, fixture.generic]
    fixture.persistence.value.preferredEditor = fixture.zed
    fixture.persistence.failWrite = true
    let store = fixture.makeStore()

    await store.openInEditor(fixture.ids, application: fixture.generic)

    #expect(fixture.launches.count == 1)
    #expect(fixture.launches.first?.application == fixture.generic)
    #expect(fixture.persistence.writes == 1)
    #expect(fixture.persistence.value.preferredEditor == fixture.zed)
    #expect(store.settings.preferredEditor == fixture.zed)
    #expect(store.preferredEditor == fixture.zed)
    #expect(store.errorMessage?.contains("Opened in Writer") == true)
    #expect(store.errorMessage?.contains("could not save") == true)
}

@Test @MainActor
func editorChooserCancellationIsNoOpAndBlocksModalActionsWhileOpen() async {
    let fixture = EditorPreferenceFixture()
    let store = fixture.makeStore()
    fixture.onChoose = {
        #expect(store.isModalPresented)
        #expect(!store.canOpenInEditor(fixture.ids))
        #expect(!store.canDeleteSelection)
    }
    await store.chooseAndOpenEditor(fixture.ids)
    fixture.onChoose = nil

    #expect(fixture.chooserCalls == 1)
    #expect(fixture.launches.isEmpty)
    #expect(fixture.persistence.writes == 0)
    #expect(store.errorMessage == nil)
    #expect(!store.isModalPresented)
    #expect(store.canOpenInEditor(fixture.ids))
}

@Test @MainActor
func editorChooserRevalidatesRemovedWorktreeAfterNestedEventLoop() async {
    let fixture = EditorPreferenceFixture()
    fixture.installed = [fixture.generic]
    fixture.chosenURL = fixture.generic.url
    let store = fixture.makeStore()
    fixture.onChoose = {
        store.projectSession(for: fixture.project)?.reconcile([], refresh: false)
    }
    await store.chooseAndOpenEditor(fixture.ids)
    fixture.onChoose = nil

    #expect(fixture.chooserCalls == 1)
    #expect(fixture.launches.isEmpty)
    #expect(fixture.persistence.writes == 0)
    #expect(!store.isModalPresented)
}

@Test @MainActor
func editorChooserRevalidatesDestinationAfterNestedEventLoop() async {
    let fixture = EditorPreferenceFixture()
    fixture.installed = [fixture.generic]
    fixture.chosenURL = fixture.generic.url
    let store = fixture.makeStore()
    fixture.onChoose = { store.destination = nil }
    await store.chooseAndOpenEditor(fixture.ids)
    fixture.onChoose = nil

    #expect(fixture.chooserCalls == 1)
    #expect(fixture.launches.isEmpty)
    #expect(fixture.persistence.writes == 0)
    #expect(!store.isModalPresented)
}

@Test @MainActor
func editorMenuRefreshKeepsMissingPreferredNameWithoutFallingBackToZed() async {
    let fixture = EditorPreferenceFixture()
    fixture.installed = [fixture.generic, fixture.zed]
    fixture.advertised = [fixture.generic]
    fixture.persistence.value.preferredEditor = fixture.generic
    let store = fixture.makeStore()
    #expect(store.editorApplications.contains(fixture.generic))

    fixture.installed = [fixture.zed]
    fixture.advertised = [fixture.zed]
    store.refreshEditorApplications()

    #expect(store.editorApplications == [fixture.zed])
    #expect(store.preferredEditor == fixture.generic)
    #expect(store.openInEditorTitle == "Open in Writer")
    fixture.failLaunch = true
    await store.openInEditor(fixture.ids)
    #expect(fixture.launches.first?.application == fixture.generic)
    #expect(fixture.chooserCalls == 0)
    #expect(fixture.persistence.writes == 0)
    #expect(store.errorMessage?.contains("Writer") == true)
}
