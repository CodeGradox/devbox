import AppKit
import DevBoxCore
import Foundation
import Observation

enum Destination: Hashable {
    case project(String)
    case connection(UUID)
}

enum ProjectSection: String, CaseIterable, Identifiable {
    case worktrees = "Worktrees"
    case branches = "Branches"

    var id: Self { self }
}

enum SizeScanState {
    case idle
    case queued
    case scanning
}

struct WorktreeRow: Identifiable {
    var worktree: WorktreeRecord
    var status: GitStatus?
    var statusError: String?
    var statusRefreshPending = false
    var usage: DiskUsage?
    var usageError: String?
    var measuredAt: Date?
    var sizeState: SizeScanState = .idle
    // A refresh may be paused for deletion confirmation while its old value remains.
    var sizeRefreshPending = false
    var id: String { worktree.id }
    var isSizeBusy: Bool { sizeState != .idle }

    var needsStatusLoad: Bool {
        worktree.exists && !worktree.isBare
            && (statusRefreshPending || (status == nil && statusError == nil))
    }

    var needsSizeLoad: Bool {
        worktree.exists && !worktree.isBare
            && (sizeRefreshPending || isSizeBusy || (usage == nil && usageError == nil))
    }

    var protectedReason: String? {
        if worktree.isMain { return "The main checkout is protected." }
        if worktree.isBare { return "Bare repositories are protected." }
        if worktree.isLocked { return "Unlock this worktree with Git before deleting it." }
        if !worktree.exists { return "The folder is missing. Clean up its registration with Git." }
        if !worktree.nestedWorktreePaths.isEmpty {
            return "Contains registered worktrees. Remove the nested worktrees first, then refresh."
        }
        return nil
    }

    var statusDescription: String {
        if !worktree.exists { return "Folder missing" }
        if worktree.isBare { return "No checkout" }
        if let statusError { return statusError }
        guard let status else { return "Checking…" }
        if status.isClean { return "Clean" }
        var parts: [String] = []
        if status.conflicted > 0 { parts.append("\(status.conflicted) conflicted") }
        if status.staged > 0 { parts.append("\(status.staged) staged") }
        if status.modified > 0 { parts.append("\(status.modified) modified") }
        if status.untracked > 0 { parts.append("\(status.untracked) untracked") }
        return parts.joined(separator: ", ")
    }
}

struct DeletionRequest: Identifiable {
    enum Items {
        case worktrees(ProjectRecord, [WorktreeRow])
        case branches(ProjectRecord, [ManagedBranch])
        case databases(SavedConnection, [DatabaseRecord])
    }
    let id = UUID()
    let items: Items
    var statisticsSummary: String?
    var count: Int {
        switch items {
        case .worktrees(_, let rows): rows.count
        case .branches(_, let rows): rows.count
        case .databases(_, let rows): rows.count
        }
    }

    var entries: [OperationResult.Entry] {
        switch items {
        case .worktrees(_, let rows): rows.map { .init(name: $0.worktree.path) }
        case .branches(_, let rows): rows.map { .init(name: $0.reference) }
        case .databases(_, let rows): rows.map { .init(name: $0.name, identity: $0.id) }
        }
    }
}

enum DeletionState: Equatable {
    case queued
    case deleting
    case completed
    case failed(String)
    case uncertain(String)
    case notAttempted(String)

    var title: String {
        switch self {
        case .queued: "Queued"
        case .deleting: "Deleting"
        case .completed: "Completed"
        case .failed: "Failed"
        case .uncertain: "Uncertain"
        case .notAttempted: "Not attempted"
        }
    }

    var detail: String? {
        switch self {
        case .failed(let message), .uncertain(let message), .notAttempted(let message): message
        default: nil
        }
    }
}

struct OperationResult: Identifiable {
    let id = UUID()
    let title: String
    let entries: [Entry]
    struct Entry: Identifiable {
        let name: String
        /// For items whose name can't tell them apart, such as databases (see `DatabaseRecord.id`).
        var identity: String?
        var id: String { identity ?? name }
        var state: DeletionState = .queued
        var startedAt: Date?
        var elapsed: TimeInterval?
    }
}

enum AppSheet: Identifiable {
    case connection(ConnectionEditorRequest)
    case deletion(DeletionRequest)
    case results(OperationResult)
    case github(UUID = UUID())

    var id: UUID {
        switch self {
        case .connection(let request): request.id
        case .deletion(let request): request.id
        case .results(let result): result.id
        case .github(let id): id
        }
    }
}

@MainActor @Observable
final class AppStore {
    private(set) var settings = AppSettings()
    var destination: Destination? {
        didSet {
            guard destination != oldValue else { return }
            worktreeSelection = []
            selectedProjectSession?.branchList.selection = []
            databaseSelection = []
            loadSelection()
        }
    }
    var projectSection: ProjectSection = .worktrees {
        didSet {
            guard projectSection != oldValue else { return }
            ensureProjectSectionLoaded()
        }
    }
    private(set) var selectedProjectSession: ProjectSessionState?
    private(set) var selectedDatabaseSession: DatabaseSessionState?
    var worktreeSelection: Set<String> = []
    var databaseSelection: Set<String> = []
    private var databaseRefreshing = false
    var isRefreshing: Bool { selectedProjectLoading?.isLoading ?? databaseRefreshing }
    private(set) var isDeleting = false
    private var deletionProgressText = ""
    private var databaseProgressText = ""
    var progressText: String {
        isDeleting ? deletionProgressText : (selectedProjectLoading?.progress ?? databaseProgressText)
    }
    private(set) var editorApplications: [EditorApplication] = []
    private(set) var preferredEditor: EditorApplication?
    private(set) var isChoosingEditor = false
    var errorMessage: String?
    private var databaseLoadError: String?
    var loadError: String? {
        if let selectedProjectLoading { return selectedProjectLoading.error }
        return databaseLoadError
    }
    private(set) var deletionError: String?
    private(set) var deletionEntries: [OperationResult.Entry] = []
    private(set) var deletionBatchID: UUID?
    var activeSheet: AppSheet?

    // Operations use value snapshots; table cells observe stable row objects.
    var worktrees: [WorktreeRow] { selectedProjectSession?.snapshots ?? [] }
    var projectOverview: ProjectOverview { selectedProjectSession?.overview ?? ProjectOverview() }
    var databases: [DatabaseRecord] { selectedDatabaseSession?.records ?? [] }

    let git = GitService()
    let databaseService = DatabaseService()
    let github: GitHubSession
    private let persistence: any SettingsPersisting
    private let credentials: any CredentialsPersisting
    private let authenticate: @MainActor (String) async throws -> Void
    private let dropDatabase: @Sendable (DatabaseRecord, ConnectionSettings, String) async throws -> Void
    private let removeWorktree: @Sendable (WorktreeRecord, ProjectRecord, Bool) async throws -> Void
    private let listDatabases: @Sendable (ConnectionSettings, String) async throws -> [DatabaseRecord]
    private let loadStatistics: @Sendable (ConnectionSettings, String) async throws -> [String: DatabaseStatistics]
    private let listWorktrees: @Sendable (ProjectRecord) async throws -> [WorktreeRecord]
    private let loadGitStatus: @Sendable (WorktreeRecord) async throws -> GitStatus
    private let editorLauncher: EditorLauncher
    private let chooseEditor: @MainActor () -> URL?
    private let openWorktreeInEditor: @MainActor (String, EditorApplication) async throws -> Void
    private let sizeQueue: WorktreeSizeQueue
    private let inspectBranches: @Sendable (ProjectRecord, [WorktreeRecord]) async throws -> BranchInspection
    private let listManagedBranches: @Sendable (ProjectRecord) async throws -> [ManagedBranch]
    private let fetchManagedBranches: @Sendable (ProjectRecord) async throws -> Void
    private let deleteBranch: @Sendable (ManagedBranch, ProjectRecord, Bool) async throws -> Void
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var pullRequestTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var settingsReadable = true
    private var queuedSheet: AppSheet?
    // The session models are the cache, not duplicate active/cache arrays.
    private var projectSessions: [String: ProjectSessionState] = [:]
    private var databaseSessions: [UUID: DatabaseSessionState] = [:]

    var deletionRequest: DeletionRequest? {
        get {
            if case .deletion(let request) = activeSheet { return request }
            return nil
        }
        set { activeSheet = newValue.map(AppSheet.deletion) }
    }

    var connectionEditor: ConnectionEditorRequest? {
        get {
            if case .connection(let request) = activeSheet { return request }
            return nil
        }
        set { activeSheet = newValue.map(AppSheet.connection) }
    }

    var isModalPresented: Bool { activeSheet != nil || queuedSheet != nil || isChoosingEditor }

    func sheetDidDismiss() {
        guard let next = queuedSheet else { return }
        queuedSheet = nil
        activeSheet = next
    }

    init(
        persistence: any SettingsPersisting = SettingsStore(),
        credentials: any CredentialsPersisting = KeychainCredentials(),
        github: GitHubSession = GitHubSession(),
        sizeQueue: WorktreeSizeQueue = WorktreeSizeQueue(),
        inspectBranches: @escaping @Sendable (ProjectRecord, [WorktreeRecord]) async throws -> BranchInspection = {
            try await BranchStatusService().inspect(project: $0, worktrees: $1)
        },
        listManagedBranches: @escaping @Sendable (ProjectRecord) async throws -> [ManagedBranch] = {
            try await BranchManagementService().list(project: $0)
        },
        fetchManagedBranches: @escaping @Sendable (ProjectRecord) async throws -> Void = {
            try await BranchManagementService().fetch(project: $0)
        },
        deleteBranch: @escaping @Sendable (ManagedBranch, ProjectRecord, Bool) async throws -> Void = {
            try await BranchManagementService().delete(branch: $0, project: $1, force: $2)
        },
        dropDatabase: @escaping @Sendable (DatabaseRecord, ConnectionSettings, String) async throws -> Void = {
            try await DatabaseService().dropDatabase($0, settings: $1, password: $2)
        },
        removeWorktree: @escaping @Sendable (WorktreeRecord, ProjectRecord, Bool) async throws -> Void = {
            try await GitService().remove(worktree: $0, project: $1, allowDirty: $2)
        },
        listDatabases: @escaping @Sendable (ConnectionSettings, String) async throws -> [DatabaseRecord] = {
            try await DatabaseService().databases(settings: $0, password: $1)
        },
        loadStatistics: @escaping @Sendable (ConnectionSettings, String) async throws -> [String: DatabaseStatistics] = {
            try await DatabaseService().databaseStatistics(settings: $0, password: $1)
        },
        listWorktrees: @escaping @Sendable (ProjectRecord) async throws -> [WorktreeRecord] = {
            try await GitService().listWorktrees(project: $0)
        },
        loadGitStatus: @escaping @Sendable (WorktreeRecord) async throws -> GitStatus = {
            try await GitService().status(worktree: $0)
        },
        editorLauncher: EditorLauncher = EditorLauncher(),
        chooseEditor: @escaping @MainActor () -> URL? = { EditorApplicationPicker.choose() },
        openWorktreeInEditor: (@MainActor (String, EditorApplication) async throws -> Void)? = nil,
        authenticate: @escaping @MainActor (String) async throws -> Void = { reason in
            try await OwnerAuthentication.authorize(reason: reason)
        }
    ) {
        self.persistence = persistence
        self.credentials = credentials
        self.github = github
        self.sizeQueue = sizeQueue
        self.inspectBranches = inspectBranches
        self.listManagedBranches = listManagedBranches
        self.fetchManagedBranches = fetchManagedBranches
        self.deleteBranch = deleteBranch
        self.dropDatabase = dropDatabase
        self.removeWorktree = removeWorktree
        self.listDatabases = listDatabases
        self.loadStatistics = loadStatistics
        self.listWorktrees = listWorktrees
        self.loadGitStatus = loadGitStatus
        self.editorLauncher = editorLauncher
        self.chooseEditor = chooseEditor
        self.openWorktreeInEditor = openWorktreeInEditor ?? { path, application in
            try await editorLauncher.open(worktreePath: path, application: application)
        }
        self.authenticate = authenticate
        do {
            var loaded = try persistence.load()
            // Duplicate ids can only come from a hand-edited or merged file. Keep the first
            // of each, instead of trapping on every launch.
            var projectIDs: Set<String> = []
            loaded.projects = loaded.projects.filter { projectIDs.insert($0.id).inserted }
            var connectionIDs: Set<UUID> = []
            loaded.connections = loaded.connections.filter { connectionIDs.insert($0.id).inserted }
            settings = loaded
            projectSessions = Dictionary(uniqueKeysWithValues: settings.projects.map {
                ($0.id, ProjectSessionState())
            })
            databaseSessions = Dictionary(uniqueKeysWithValues: settings.connections.map {
                ($0.id, DatabaseSessionState())
            })
            if let first = settings.projects.first {
                destination = .project(first.id)
            } else if let first = settings.connections.first {
                destination = .connection(first.id)
            }
        } catch {
            settingsReadable = false
            errorMessage = "Could not read settings. Existing settings will not be overwritten.\n\(error.localizedDescription)"
        }
        refreshEditorApplications()
    }

    isolated deinit {
        pullRequestTask?.cancel()
        refreshTask?.cancel()
        for session in projectSessions.values { session.cancelLoading() }
        sizeQueue.cancelAll()
    }

    var selectedProject: ProjectRecord? {
        guard case .project(let id) = destination else { return nil }
        return settings.projects.first { $0.id == id }
    }

    var selectedConnection: SavedConnection? {
        guard case .connection(let id) = destination else { return nil }
        return settings.connections.first { $0.id == id }
    }

    private var selectedProjectLoading: ProjectLoadingState? {
        guard let session = selectedProjectSession else { return nil }
        return projectSection == .worktrees ? session.worktreeLoading : session.branchLoading
    }

    var selectedWorktrees: [WorktreeRow] {
        guard let session = selectedProjectSession else { return [] }
        // A filter may change before SwiftUI reconciles its native selection.
        // Never include hidden rows in a destructive action during that interval.
        let visible = Set(session.tableRows.map(\.id))
        return worktreeSelection.intersection(visible).sorted().compactMap { session.row(id: $0)?.row }
    }
    var selectedDatabases: [DatabaseRecord] { databases.filter { databaseSelection.contains($0.id) } }

    var selectedBranches: [ManagedBranch] {
        selectedProjectSession?.branchList.selectedBranches ?? []
    }

    var openInEditorTitle: String {
        preferredEditor.map { "Open in \($0.name)" } ?? "Open in Editor…"
    }

    /// Discover outside view bodies, at launch and when returning to DevBox.
    /// A manually chosen app remains available even if it does not advertise folder support.
    func refreshEditorApplications() {
        // A preference saved before Archive Utility was filtered out of the menu is ignored,
        // not rewritten, so the toolbar can't keep archiving folders.
        if let saved = settings.preferredEditor, !saved.archivesFolders {
            preferredEditor = editorLauncher.resolvedApplication(saved) ?? saved
        } else {
            preferredEditor = editorLauncher.application(withBundleIdentifier: "dev.zed.Zed")
        }
        var applications = editorLauncher.applicationsForFolders()
        if let preferredEditor, let installed = editorLauncher.resolvedApplication(preferredEditor),
           !applications.contains(where: { $0.id == installed.id }) {
            applications.insert(installed, at: 0)
        }
        if editorApplications != applications { editorApplications = applications }
    }

    func canOpenInEditor(_ ids: Set<String>) -> Bool {
        worktreeToOpenInEditor(ids) != nil
    }

    /// An explicit Open With choice becomes the preference only after opening succeeds.
    func openInEditor(_ ids: Set<String>, application: EditorApplication? = nil) async {
        guard let worktree = worktreeToOpenInEditor(ids) else { return }
        guard let editor = application ?? preferredEditor else {
            await chooseAndOpenEditor(ids)
            return
        }
        do {
            try await openWorktreeInEditor(worktree.path, editor)
        } catch {
            errorMessage = "Could not open \(worktree.path) in \(editor.name).\n\(error.localizedDescription)"
            return
        }
        if application != nil, settings.preferredEditor != editor {
            var next = settings
            next.preferredEditor = editor
            do {
                try persist(next)
                refreshEditorApplications()
            } catch {
                errorMessage = "Opened in \(editor.name), but could not save your preferred editor.\n\(error.localizedDescription)"
            }
        }
    }

    func chooseAndOpenEditor(_ ids: Set<String>) async {
        guard canOpenInEditor(ids) else { return }
        let projectID = selectedProject?.id
        isChoosingEditor = true
        let url = chooseEditor()
        isChoosingEditor = false
        // The native panel runs a nested event loop. Recheck the original target afterward.
        guard let url, selectedProject?.id == projectID, canOpenInEditor(ids) else { return }
        guard let application = editorLauncher.application(at: url) else {
            errorMessage = "The selected application is unavailable. Choose an installed app with Open With → Other…."
            return
        }
        await openInEditor(ids, application: application)
    }

    private func worktreeToOpenInEditor(_ ids: Set<String>) -> WorktreeRecord? {
        guard projectSection == .worktrees, !isDeleting, !isModalPresented, ids.count == 1,
              let id = ids.first, let worktree = selectedProjectSession?.row(id: id)?.row.worktree,
              worktree.exists, !worktree.isBare else { return nil }
        return worktree
    }

    var isMeasuringSizes: Bool {
        selectedProjectSession?.isMeasuringSizes ?? false
    }

    var projectSizeSummary: ProjectSizeSummary {
        selectedProjectSession?.summary ?? ProjectSizeSummary(rows: [WorktreeRow](), overview: ProjectOverview())
    }

    func projectSession(for project: ProjectRecord) -> ProjectSessionState? {
        projectSessions[project.id]
    }

    func refreshPresentations() {
        for session in projectSessions.values {
            session.refreshPresentation()
            session.branchList.refreshPresentation()
        }
        for session in databaseSessions.values { session.refreshPresentation() }
    }

    func sizeSummary(for project: ProjectRecord) -> ProjectSizeSummary? {
        projectSessions[project.id]?.summary
    }

    var sizeProgressText: String {
        selectedProjectSession?.sizeProgressText ?? ""
    }

    var canDeleteSelection: Bool {
        guard !isRefreshing, !isDeleting, !isModalPresented,
              selectedProjectSession?.isFetchingBranches != true else { return false }
        if selectedProject != nil {
            if projectSection == .branches {
                guard selectedProjectSession?.branchList.hasLoadedInventory == true else { return false }
                return !selectedBranches.isEmpty && selectedBranches.allSatisfy { $0.protectedReason == nil }
            }
            let selection = selectedWorktrees
            return !selection.isEmpty && selection.allSatisfy { $0.protectedReason == nil }
        }
        guard selectedDatabaseSession?.hasLoadedInventory == true else { return false }
        return !selectedDatabases.isEmpty && selectedDatabases.allSatisfy { !$0.isSystem }
    }

    func addProject() {
        let panel = NSOpenPanel()
        panel.title = "Add Git Project"
        panel.message = "Choose a repository or any of its worktrees."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add Project"
        guard panel.runModal() == .OK else { return }
        let paths = panel.urls.map(\.path)
        Task {
            for path in paths {
                do {
                    let project = try await git.discoverProject(at: path)
                    if !settings.projects.contains(where: { $0.id == project.id }) {
                        var next = settings
                        next.projects.append(project)
                        next.projects.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                        try persist(next)
                    }
                    destination = .project(project.id)
                } catch { errorMessage = error.localizedDescription }
            }
        }
    }

    func forgetProject(_ project: ProjectRecord) {
        do {
            var next = settings
            next.projects.removeAll { $0.id == project.id }
            try persist(next)
            projectSessions.removeValue(forKey: project.id)
            if destination == .project(project.id) { destination = nil }
        } catch { errorMessage = error.localizedDescription }
    }

    @ObservationIgnored private var credentialEdits: Set<UUID> = []

    private func beginCredentialEdit(_ id: UUID) throws {
        guard credentialEdits.insert(id).inserted else {
            throw NSError(domain: "DevBox.Keychain", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "This connection’s credentials are being updated. Try again when the update finishes."
            ])
        }
    }

    func saveConnection(_ connection: SavedConnection, password: String) async throws {
        guard settingsReadable else { throw SettingsError.unreadable }
        try beginCredentialEdit(connection.id)
        defer { credentialEdits.remove(connection.id) }
        let existing = settings.connections.contains { $0.id == connection.id }
        // Preserve the old secret so a failed settings write cannot silently pair
        // old connection settings with a newly entered password.
        let previousPassword = existing ? try await credentials.password(for: connection.id) : nil
        try await credentials.save(password: password, for: connection.id)
        do {
            // Merge only after suspension: unrelated settings edits must survive.
            var next = settings
            if let index = next.connections.firstIndex(where: { $0.id == connection.id }) {
                next.connections[index] = connection
            } else {
                next.connections.append(connection)
            }
            try persist(next)
        } catch {
            let settingsError = error
            do {
                if let previousPassword {
                    try await credentials.save(password: previousPassword, for: connection.id)
                } else {
                    try await credentials.remove(for: connection.id)
                }
            } catch {
                throw NSError(
                    domain: "DevBox.Settings",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Settings could not be saved, and the previous Keychain password could not be restored. Re-enter the connection credentials before using it.\n\(settingsError.localizedDescription)\n\(error.localizedDescription)"]
                )
            }
            throw settingsError
        }
        // A changed endpoint or credential must never reuse the old server's metadata.
        databaseSessions[connection.id] = DatabaseSessionState()
        if destination == .connection(connection.id) {
            loadSelection()
        } else {
            destination = .connection(connection.id)
        }
    }

    func forgetConnection(_ connection: SavedConnection) async {
        do {
            guard settingsReadable else { throw SettingsError.unreadable }
            try beginCredentialEdit(connection.id)
            defer { credentialEdits.remove(connection.id) }
            let previousPassword = try await credentials.password(for: connection.id)
            try await credentials.remove(for: connection.id)
            var next = settings
            next.connections.removeAll { $0.id == connection.id }
            do {
                try persist(next)
            } catch {
                let settingsError = error
                if let previousPassword {
                    do { try await credentials.save(password: previousPassword, for: connection.id) }
                    catch {
                        throw NSError(domain: "DevBox.Settings", code: 1, userInfo: [
                            NSLocalizedDescriptionKey: "Settings could not be saved, and the previous Keychain password could not be restored. Re-enter the connection credentials before using it."
                        ])
                    }
                }
                throw settingsError
            }
            databaseSessions.removeValue(forKey: connection.id)
            if destination == .connection(connection.id) { destination = nil }
        } catch { errorMessage = error.localizedDescription }
    }

    private func persist(_ next: AppSettings) throws {
        guard settingsReadable else { throw SettingsError.unreadable }
        try persistence.save(next)
        settings = next
        for project in next.projects where projectSessions[project.id] == nil {
            projectSessions[project.id] = ProjectSessionState()
        }
        for connection in next.connections where databaseSessions[connection.id] == nil {
            databaseSessions[connection.id] = DatabaseSessionState()
        }
    }

    func password(for connectionID: UUID) async throws -> String {
        guard !credentialEdits.contains(connectionID) else {
            throw NSError(domain: "DevBox.Keychain", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "This connection’s credentials are being updated. Try again when the update finishes."
            ])
        }
        guard let password = try await credentials.password(for: connectionID) else {
            throw NSError(
                domain: "DevBox.Keychain",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No saved password was found in Keychain. Edit the connection and save its password again."]
            )
        }
        return password
    }

    /// Reuse this session's snapshot on selection. A new app instance has none.
    func loadSelection() {
        guard !isDeleting else { return }
        refreshTask?.cancel()
        refreshTask = nil
        selectedProjectSession?.cancelLoading(preservingFetch: true)
        selectedDatabaseSession?.pauseStatistics()
        sizeQueue.cancelAll()
        pullRequestTask?.cancel()
        pullRequestTask = nil
        github.pullRequests.cancelLoading()
        generation = UUID()
        databaseRefreshing = false
        databaseProgressText = ""
        databaseLoadError = nil
        selectedProjectSession = selectedProject.flatMap { projectSessions[$0.id] }
        selectedDatabaseSession = selectedConnection.flatMap { databaseSessions[$0.id] }
        if selectedProject != nil {
            ensureProjectSectionLoaded()
        } else if let connection = selectedConnection, let session = selectedDatabaseSession {
            loadDatabase(connection, session: session, useCache: true)
        }
    }

    /// Explicit refresh reloads inventory and measurements; deletion only updates the cache.
    func refresh() {
        guard !isDeleting else { return }
        if let project = selectedProject, let session = selectedProjectSession {
            if projectSection == .branches {
                guard !session.isFetchingBranches else { return }
                loadBranchList(project, session: session, useCache: false)
            } else {
                sizeQueue.cancelAll()
                session.worktreeLoading.cancel()
                session.inspectionLoading.cancel()
                session.pauseScans()
                loadWorktrees(project, session: session, useCache: false)
            }
        } else if let connection = selectedConnection, let session = selectedDatabaseSession {
            loadDatabase(connection, session: session, useCache: false)
        }
    }

    /// Network access is explicit; ordinary Refresh only rereads local refs.
    func fetchBranches() {
        guard selectedProject != nil, projectSection == .branches,
              !isRefreshing, !isDeleting, !isModalPresented else { return }
        guard let project = selectedProject, let session = selectedProjectSession else { return }
        loadBranchList(project, session: session, useCache: false, fetchRemotes: true)
    }

    func changeMergeTarget(_ reference: String?) {
        guard !isDeleting, !isModalPresented, let project = selectedProject,
              reference != project.mergeTarget else { return }
        guard reference == nil || projectOverview.branches?.availableTargets.contains(where: {
            $0.reference == reference
        }) == true else { return }
        do {
            var next = settings
            guard let index = next.projects.firstIndex(where: { $0.id == project.id }) else { return }
            next.projects[index] = ProjectRecord(
                id: project.id, name: project.name, path: project.path, mergeTarget: reference
            )
            try persist(next)
            guard let session = projectSessions[project.id],
                  let updatedProject = selectedProject else { return }
            session.inspectionLoading.cancel()
            session.updateOverview {
                $0.branches = nil
                $0.branchError = nil
                $0.isLoadingBranches = false
            }
            session.invalidateBranchInventory()
            loadProjectOverview(updatedProject, session: session)
        } catch { errorMessage = error.localizedDescription }
    }

    /// Tabs express demand; the project session, not a view, owns ongoing jobs.
    private func ensureProjectSectionLoaded() {
        guard !isDeleting, let project = selectedProject, let session = selectedProjectSession else { return }
        if projectSection == .branches {
            observePullRequestDemand(session)
            loadBranchList(project, session: session, useCache: true)
        } else {
            loadWorktrees(project, session: session, useCache: true)
        }
    }

    private struct PullRequestDemand: Equatable {
        let account: UUID
        let branches: Set<GitHubBranch>
        let ready: Bool
    }

    private func observePullRequestDemand(_ session: ProjectSessionState) {
        guard pullRequestTask == nil else { return }
        let github = github
        pullRequestTask = Task {
            var previous: PullRequestDemand?
            for await demand in Observations({
                PullRequestDemand(
                    account: github.accountGeneration,
                    branches: session.branchList.visibleGitHubBranches,
                    ready: session.branchList.hasLoadedInventory && !github.isSigningOut
                )
            }) {
                guard !Task.isCancelled else { return }
                guard demand.ready, previous != demand else { continue }
                previous = demand
                github.pullRequests.load(demand.branches, session: github)
            }
        }
    }

    private func loadDatabase(_ connection: SavedConnection, session: DatabaseSessionState, useCache: Bool) {
        refreshTask?.cancel()
        session.pauseStatistics()
        let token = UUID()
        generation = token
        databaseLoadError = nil
        databaseProgressText = ""
        if useCache, session.hasLoadedInventory {
            databaseRefreshing = false
            guard session.needsStatisticsLoad else {
                refreshTask = nil
                return
            }
            refreshTask = Task {
                guard generation == token, !Task.isCancelled else { return }
                do {
                    let secret = try await password(for: connection.id)
                    guard generation == token, !Task.isCancelled else { return }
                    await loadDatabaseStatistics(connection, session: session, password: secret, token: token)
                } catch {
                    guard generation == token, !Task.isCancelled else { return }
                    session.failStatistics(error.localizedDescription)
                }
            }
            return
        }
        session.invalidateInventory()
        databaseRefreshing = true
        databaseProgressText = "Refreshing…"
        refreshTask = Task {
            defer { finishRefresh(token: token) }
            guard generation == token, !Task.isCancelled else { return }
            do {
                let password = try await password(for: connection.id)
                guard generation == token, !Task.isCancelled else { return }
                let records = try await listDatabases(connection.settings, password)
                guard generation == token, !Task.isCancelled else { return }
                session.reconcile(records)
                databaseSelection.formIntersection(Set(records.map(\.id)))
                finishRefresh(token: token)
                await loadDatabaseStatistics(connection, session: session, password: password, token: token)
            } catch {
                guard generation == token, !Task.isCancelled else { return }
                databaseLoadError = error.localizedDescription
                session.failStatistics("The database list could not be refreshed. \(error.localizedDescription)")
            }
        }
    }

    private func loadWorktrees(_ project: ProjectRecord, session: ProjectSessionState, useCache: Bool) {
        let loading = session.worktreeLoading
        if useCache, loading.isLoading { return }
        if useCache, session.hasLoadedInventory {
            let cachedRows = session.snapshots
            let missingStatuses = cachedRows.filter(\.needsStatusLoad).map(\.worktree)
            let token = missingStatuses.isEmpty ? loading.revision : loading.begin("Loading remaining Git status…")
            session.performBatchUpdates {
                loadProjectOverview(project, session: session)
                for row in cachedRows where row.needsSizeLoad && !row.isSizeBusy {
                    enqueueSizeScan(row.worktree, session: session, token: token)
                }
            }
            worktreeSelection.formIntersection(Set(session.rows.map(\.id)))
            guard !missingStatuses.isEmpty else { return }
            loading.task = Task {
                defer { loading.finish(token) }
                await loadGitStatuses(missingStatuses, session: session, token: token)
            }
            return
        }
        session.invalidateInventory()
        let token = loading.begin("Refreshing…")
        loading.task = Task {
            defer { loading.finish(token) }
            guard loading.accepts(token), !Task.isCancelled else { return }
            do {
                let records = try await listWorktrees(project)
                guard loading.accepts(token), !Task.isCancelled else { return }
                let currentProject = settings.projects.first { $0.id == project.id } ?? project
                // Both the worktree inventory and merge target are inspection
                // inputs. Fence an inspection started before this reconciliation.
                session.inspectionLoading.cancel()
                session.performBatchUpdates {
                    session.reconcile(records, refresh: true)
                    session.invalidateBranchInventory()
                    session.updateOverview {
                        $0.branches = nil
                        $0.branchError = nil
                        $0.isLoadingBranches = false
                        $0.gitUsageError = nil
                        $0.gitRefreshPending = true
                    }
                    worktreeSelection.formIntersection(Set(records.map(\.id)))
                    loadProjectOverview(currentProject, session: session)
                    for record in records where record.exists && !record.isBare {
                        enqueueSizeScan(record, session: session, token: token)
                    }
                }
                // A hidden worktree refresh may invalidate the visible branch list.
                // Let an existing branch operation finish its own verification.
                if selectedProjectSession === session, projectSection == .branches {
                    loadBranchList(project, session: session, useCache: true)
                }
                loading.progress = "Refreshing Git status…"
                await loadGitStatuses(records, session: session, token: token)
            } catch {
                guard loading.accepts(token), !Task.isCancelled else { return }
                loading.error = error.localizedDescription
            }
        }
    }

    private func loadBranchList(
        _ project: ProjectRecord, session: ProjectSessionState, useCache: Bool, fetchRemotes: Bool = false
    ) {
        let list = session.branchList
        let loading = session.branchLoading
        if useCache && (list.hasLoadedInventory || loading.isLoading) { return }
        list.invalidateInventory()
        let token = loading.begin(fetchRemotes ? "Fetching and pruning remote branches…" : "Loading branches…")
        session.isFetchingBranches = fetchRemotes
        loading.task = Task {
            defer {
                if loading.accepts(token) {
                    session.isFetchingBranches = false
                    loading.finish(token)
                    // Fetch may partially update refs even when it fails.
                    if fetchRemotes, selectedProjectSession === session, projectSection == .worktrees {
                        loadProjectOverview(selectedProject ?? project, session: session)
                    }
                }
            }
            guard loading.accepts(token), !Task.isCancelled else { return }
            do {
                if fetchRemotes {
                    // Even a failed fetch may update some refs. Don't reuse merge badges.
                    session.inspectionLoading.cancel()
                    session.updateOverview {
                        $0.branches = nil; $0.branchError = nil; $0.isLoadingBranches = false
                    }
                    try await fetchManagedBranches(project)
                    guard loading.accepts(token), !Task.isCancelled else { return }
                    list.lastFetchedAt = Date()
                }
                // Worktree reconciliation may invalidate protection information
                // during this read. Reverify that snapshot, without repeating a
                // Fetch & Prune or canceling the other tab's jobs.
                while loading.accepts(token), !Task.isCancelled {
                    let inventoryRevision = session.branchInventoryRevision
                    let snapshotProject = settings.projects.first { $0.id == project.id } ?? project
                    let records = try await listManagedBranches(snapshotProject)
                    guard loading.accepts(token), !Task.isCancelled else { return }
                    guard inventoryRevision == session.branchInventoryRevision else { continue }
                    list.reconcile(records)
                    break
                }
            } catch {
                guard loading.accepts(token), !Task.isCancelled else { return }
                loading.error = error.localizedDescription
            }
        }
    }

    private func loadDatabaseStatistics(
        _ connection: SavedConnection, session: DatabaseSessionState, password: String, token: UUID
    ) async {
        guard generation == token, !Task.isCancelled else { return }
        session.beginStatistics()
        do {
            let statistics = try await loadStatistics(connection.settings, password)
            guard generation == token, !Task.isCancelled else { return }
            session.receive(statistics)
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            session.failStatistics(error.localizedDescription)
        }
    }

    private func finishRefresh(token: UUID) {
        guard generation == token else { return }
        databaseRefreshing = false
        databaseProgressText = ""
    }

    private func loadGitStatuses(
        _ records: [WorktreeRecord], session: ProjectSessionState, token: UUID
    ) async {
        let load = loadGitStatus
        let loading = session.worktreeLoading
        await withTaskGroup(of: (String, Result<GitStatus, Error>).self) { group in
            var remaining = records.lazy.filter { $0.exists && !$0.isBare }.makeIterator()
            var inFlight = 0
            // Keep only two child tasks alive, replenishing after each published
            // result. The shared I/O executor separately bounds global workers.
            while loading.accepts(token), !Task.isCancelled {
                while inFlight < 2, let record = remaining.next() {
                    guard loading.accepts(token), !Task.isCancelled else {
                        group.cancelAll()
                        return
                    }
                    let added = group.addTaskUnlessCancelled {
                        do {
                            try Task.checkCancellation()
                            return (record.id, .success(try await load(record)))
                        } catch {
                            return (record.id, .failure(error))
                        }
                    }
                    if !added { break }
                    inFlight += 1
                }
                guard let (id, result) = await group.next() else { return }
                inFlight -= 1
                guard loading.accepts(token), !Task.isCancelled else { break }
                session.updateRow(id) {
                    switch result {
                    case .success(let status):
                        $0.status = status
                        $0.statusError = nil
                    case .failure(let error):
                        $0.statusError = error.localizedDescription
                    }
                    $0.statusRefreshPending = false
                }
            }
            group.cancelAll()
        }
    }

    func canRefreshSize(_ row: WorktreeRow) -> Bool {
        selectedProject != nil && row.worktree.exists && !row.worktree.isBare
            && selectedProjectSession?.hasLoadedInventory == true
            && !row.isSizeBusy && !isDeleting && !isModalPresented
    }

    func refreshWorktreeSize(_ id: String) {
        guard let session = selectedProjectSession,
              let row = session.row(id: id)?.row, canRefreshSize(row) else { return }
        enqueueSizeScan(row.worktree, session: session, token: session.worktreeLoading.revision)
    }

    private func enqueueSizeScan(_ worktree: WorktreeRecord, session: ProjectSessionState, token: UUID) {
        session.updateRow(worktree.id) {
            $0.sizeState = .queued
            $0.sizeRefreshPending = true
            $0.usageError = nil
        }
        sizeQueue.enqueue(worktree, onStarted: { [weak session] in
            guard let session, session.worktreeLoading.accepts(token) else { return }
            session.updateRow(worktree.id) { $0.sizeState = .scanning }
        }, onFinished: { [weak session] result in
            guard let session, session.worktreeLoading.accepts(token) else { return }
            session.updateRow(worktree.id) { row in
                row.sizeState = .idle
                row.sizeRefreshPending = false
                switch result {
                case .success(let usage):
                    row.usage = usage
                    row.measuredAt = Date()
                    row.usageError = nil
                case .failure(let error):
                    // Keep the last known measurement, but make failed refreshes visible.
                    row.usageError = error.localizedDescription
                }
            }
        })
    }

    private func updateRow(_ id: String, _ update: (inout WorktreeRow) -> Void) {
        selectedProjectSession?.updateRow(id, update)
    }

    private func loadProjectOverview(_ project: ProjectRecord, session: ProjectSessionState) {
        let loading = session.inspectionLoading
        if session.overview.needsBranchLoad, !loading.isLoading, !session.isFetchingBranches {
            let records = session.snapshots.map(\.worktree)
            let token = loading.begin()
            session.updateOverview { $0.isLoadingBranches = true }
            loading.task = Task {
                defer { loading.finish(token) }
                do {
                    let inspection = try await inspectBranches(project, records)
                    guard loading.accepts(token), !Task.isCancelled else { return }
                    session.updateOverview {
                        $0.branches = inspection
                        $0.branchError = nil
                        $0.isLoadingBranches = false
                    }
                } catch {
                    guard loading.accepts(token), !Task.isCancelled else { return }
                    session.updateOverview {
                        $0.branchError = error.localizedDescription
                        $0.isLoadingBranches = false
                    }
                }
            }
        }
        if session.overview.needsGitSizeLoad, session.overview.gitSizeState == .idle {
            let token = session.worktreeLoading.revision
            session.updateOverview {
                $0.gitSizeState = .queued
                $0.gitRefreshPending = true
                $0.gitUsageError = nil
            }
            sizeQueue.enqueueGitStorage(project, onStarted: { [weak session] in
                guard let session, session.worktreeLoading.accepts(token) else { return }
                session.updateOverview { $0.gitSizeState = .scanning }
            }, onFinished: { [weak session] result in
                guard let session, session.worktreeLoading.accepts(token) else { return }
                session.updateOverview {
                    $0.gitSizeState = .idle
                    $0.gitRefreshPending = false
                    switch result {
                    case .success(let usage):
                        $0.gitUsage = usage
                        $0.gitMeasuredAt = Date()
                        $0.gitUsageError = nil
                    case .failure(let error):
                        $0.gitUsageError = error.localizedDescription
                    }
                }
            })
        }
    }

    func prepareDeletion() {
        guard canDeleteSelection else { return }
        deletionError = nil
        if let project = selectedProject {
            if projectSection == .branches {
                deletionRequest = DeletionRequest(items: .branches(project, selectedBranches))
                return
            }
            // Do not keep traversing folders the user is about to remove.
            let ids = Set(selectedWorktrees.map(\.id))
            sizeQueue.cancel(worktreeIDs: ids)
            for id in ids { updateRow(id) { $0.sizeState = .idle } }
            deletionRequest = DeletionRequest(items: .worktrees(project, selectedWorktrees))
        } else if let connection = selectedConnection {
            deletionRequest = DeletionRequest(
                items: .databases(connection, selectedDatabases),
                statisticsSummary: selectedDatabaseSession?.selectedSummary(databaseSelection).text
            )
        }
    }

    func deletionState(for name: String, in request: DeletionRequest) -> DeletionState {
        deletionEntry(for: name, in: request).state
    }

    /// `name` is the item's id: the path, branch reference or `DatabaseRecord.id`.
    func deletionEntry(for name: String, in request: DeletionRequest) -> OperationResult.Entry {
        guard deletionBatchID == request.id else { return .init(name: name) }
        return deletionEntries.first { $0.id == name } ?? .init(name: name)
    }

    func delete(_ request: DeletionRequest, forceBranches: Bool = false) async {
        guard !isDeleting, deletionRequest?.id == request.id else { return }
        isDeleting = true
        deletionError = nil
        deletionBatchID = request.id
        deletionEntries = request.entries
        deletionProgressText = "Authenticating…"
        defer { isDeleting = false }
        do {
            try await authenticate("authorize permanent deletion of the \(request.count) selected items in DevBox")
        } catch {
            // Leave the confirmation open so authentication cancellation is non-destructive.
            deletionError = "\(error.localizedDescription)\nNothing was deleted."
            deletionProgressText = ""
            return
        }
        // A hidden tab can still have reads in flight. Fence those snapshots at
        // the mutation boundary so they cannot repopulate a deleted row/ref.
        selectedProjectSession?.cancelLoading()
        sizeQueue.cancelAll()
        switch request.items {
        case .worktrees(let project, let rows):
            await runDeletionBatch { index in
                // The sheet showed each row's cached status. Only a row shown with changes, or
                // without a known status, may be forced; anything shown Clean must still be
                // clean now, so edits made since then are never destroyed unseen.
                let shownClean = rows[index].status?.isClean == true
                try await removeWorktree(rows[index].worktree, project, !shownClean)
            }
        case .branches(let project, let rows):
            await runDeletionBatch { index in
                try await deleteBranch(rows[index], project, forceBranches && !rows[index].isRemote)
            }
        case .databases(let connection, let rows):
            do {
                let password = try await password(for: connection.id)
                try Task.checkCancellation()
                await runDeletionBatch { index in
                    try await dropDatabase(rows[index], connection.settings, password)
                }
            } catch {
                for index in deletionEntries.indices {
                    deletionEntries[index].state = .notAttempted(error.localizedDescription)
                }
            }
        }
        let completed = Set(deletionEntries.filter { $0.state == .completed }.map(\.id))
        switch request.items {
        case .worktrees(let project, _):
            sizeQueue.cancel(worktreeIDs: completed)
            projectSessions[project.id]?.removeConfirmedWorktrees(ids: completed)
            if !completed.isEmpty { projectSessions[project.id]?.invalidateBranchInventory() }
        case .branches(let project, _):
            let session = projectSessions[project.id]
            session?.branchList.removeConfirmedBranches(ids: completed)
            if deletionEntries.contains(where: {
                if case .uncertain = $0.state { return true }
                return false
            }) {
                session?.invalidateBranchInventory()
            }
            // Recompute upstream/merge information when returning to Worktrees.
            session?.updateOverview { $0.branches = nil; $0.branchError = nil }
        case .databases(let connection, _):
            databaseSessions[connection.id]?.removeConfirmedDatabases(ids: completed)
        }
        deletionProgressText = ""
        worktreeSelection = []
        selectedProjectSession?.branchList.selection = []
        databaseSelection = []
        queuedSheet = .results(.init(title: "Deletion Results", entries: deletionEntries))
        deletionRequest = nil
        isDeleting = false
    }

    private func runDeletionBatch(_ operation: @MainActor (Int) async throws -> Void) async {
        // Deliberately sequential: the next item is submitted only after this await.
        for index in deletionEntries.indices {
            let clock = ContinuousClock()
            let start = clock.now
            deletionEntries[index].startedAt = Date()
            defer {
                let duration = start.duration(to: clock.now).components
                deletionEntries[index].elapsed = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
            }
            deletionEntries[index].state = .deleting
            deletionProgressText = "Deleting \(index + 1) of \(deletionEntries.count): \(deletionEntries[index].name)"
            do {
                try await operation(index)
                deletionEntries[index].state = .completed
            } catch BranchManagementError.deletionOutcomeUnknown(let message) {
                deletionEntries[index].state = .uncertain(
                    BranchManagementError.deletionOutcomeUnknown(message).localizedDescription
                )
                for remaining in deletionEntries.indices where remaining > index {
                    deletionEntries[remaining].state = .notAttempted(
                        "The batch stopped because the previous remote deletion's outcome is uncertain. Fetch & Prune before trying again."
                    )
                }
                return
            } catch DatabaseServiceError.deletionOutcomeUnknown(let code) {
                deletionEntries[index].state = .uncertain(
                    DatabaseServiceError.deletionOutcomeUnknown(code: code).localizedDescription
                )
                for remaining in deletionEntries.indices where remaining > index {
                    deletionEntries[remaining].state = .notAttempted(
                        "The batch stopped because the previous deletion's outcome is uncertain. No delete was submitted for this item."
                    )
                }
                // A timed-out server operation may still be running. Do not overlap
                // another destructive operation with it or automatically retry.
                return
            } catch {
                deletionEntries[index].state = .failed(error.localizedDescription)
            }
        }
    }

    private enum SettingsError: LocalizedError {
        case unreadable
        var errorDescription: String? { "Repair or restore DevBox’s settings.json before saving changes." }
    }
}

struct ConnectionEditorRequest: Identifiable {
    let id = UUID()
    var connection: SavedConnection?
}
