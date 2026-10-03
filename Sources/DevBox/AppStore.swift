import AppKit
import DevBoxCore
import Foundation
import Observation

enum Destination: Hashable {
    case project(String)
    case connection(UUID)
}

enum SizeScanState {
    case idle
    case queued
    case scanning
}

struct WorktreeRow: Identifiable {
    let worktree: WorktreeRecord
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
        case databases(SavedConnection, [DatabaseRecord])
    }
    let id = UUID()
    let items: Items
    var count: Int {
        switch items {
        case .worktrees(_, let rows): rows.count
        case .databases(_, let rows): rows.count
        }
    }

    var entries: [OperationResult.Entry] {
        switch items {
        case .worktrees(_, let rows): rows.map { .init(name: $0.worktree.path) }
        case .databases(_, let rows): rows.map { .init(name: $0.name) }
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
        var id: String { name }
        let name: String
        var state: DeletionState = .queued
    }
}

enum AppSheet: Identifiable {
    case connection(ConnectionEditorRequest)
    case deletion(DeletionRequest)
    case results(OperationResult)

    var id: UUID {
        switch self {
        case .connection(let request): request.id
        case .deletion(let request): request.id
        case .results(let result): result.id
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
            databaseSelection = []
            loadSelection()
        }
    }
    private(set) var selectedProjectSession: ProjectSessionState?
    private(set) var databases: [DatabaseRecord] = []
    var worktreeSelection: Set<String> = []
    var databaseSelection: Set<String> = []
    private(set) var isRefreshing = false
    private(set) var isDeleting = false
    private(set) var progressText = ""
    var errorMessage: String?
    private(set) var loadError: String?
    private(set) var deletionError: String?
    private(set) var deletionEntries: [OperationResult.Entry] = []
    private(set) var deletionBatchID: UUID?
    var activeSheet: AppSheet?

    // Operations use value snapshots; table cells observe stable row objects.
    var worktrees: [WorktreeRow] { selectedProjectSession?.snapshots ?? [] }
    var projectOverview: ProjectOverview { selectedProjectSession?.overview ?? ProjectOverview() }

    let git = GitService()
    let databaseService = DatabaseService()
    private let persistence: any SettingsPersisting
    private let credentials: any CredentialsPersisting
    private let authenticate: @MainActor (String) async throws -> Void
    private let dropDatabase: @Sendable (DatabaseRecord, ConnectionSettings, String) async throws -> Void
    private let sizeQueue: WorktreeSizeQueue
    private let inspectBranches: @Sendable (ProjectRecord, [WorktreeRecord]) async throws -> BranchInspection
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var branchTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var settingsReadable = true
    private var queuedSheet: AppSheet?
    // The session models are the cache, not duplicate active/cache arrays.
    private var projectSessions: [String: ProjectSessionState] = [:]

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

    var isModalPresented: Bool { activeSheet != nil || queuedSheet != nil }

    func sheetDidDismiss() {
        guard let next = queuedSheet else { return }
        queuedSheet = nil
        activeSheet = next
    }

    init(
        persistence: any SettingsPersisting = SettingsStore(),
        credentials: any CredentialsPersisting = KeychainCredentials(),
        sizeQueue: WorktreeSizeQueue = WorktreeSizeQueue(),
        inspectBranches: @escaping @Sendable (ProjectRecord, [WorktreeRecord]) async throws -> BranchInspection = {
            try await BranchStatusService().inspect(project: $0, worktrees: $1)
        },
        dropDatabase: @escaping @Sendable (DatabaseRecord, ConnectionSettings, String) async throws -> Void = {
            try await DatabaseService().dropDatabase($0, settings: $1, password: $2)
        },
        authenticate: @escaping @MainActor (String) async throws -> Void = { reason in
            try await OwnerAuthentication.authorize(reason: reason)
        }
    ) {
        self.persistence = persistence
        self.credentials = credentials
        self.sizeQueue = sizeQueue
        self.inspectBranches = inspectBranches
        self.dropDatabase = dropDatabase
        self.authenticate = authenticate
        do {
            settings = try persistence.load()
            projectSessions = Dictionary(uniqueKeysWithValues: settings.projects.map {
                ($0.id, ProjectSessionState())
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
    }

    var selectedProject: ProjectRecord? {
        guard case .project(let id) = destination else { return nil }
        return settings.projects.first { $0.id == id }
    }

    var selectedConnection: SavedConnection? {
        guard case .connection(let id) = destination else { return nil }
        return settings.connections.first { $0.id == id }
    }

    var selectedWorktrees: [WorktreeRow] {
        guard let session = selectedProjectSession else { return [] }
        return worktreeSelection.sorted().compactMap { session.row(id: $0)?.row }
    }
    var selectedDatabases: [DatabaseRecord] { databases.filter { databaseSelection.contains($0.id) } }

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
        for session in projectSessions.values { session.refreshPresentation() }
    }

    func sizeSummary(for project: ProjectRecord) -> ProjectSizeSummary? {
        projectSessions[project.id]?.summary
    }

    var sizeProgressText: String {
        selectedProjectSession?.sizeProgressText ?? ""
    }

    var canDeleteSelection: Bool {
        guard !isRefreshing, !isDeleting, !isModalPresented else { return false }
        if selectedProject != nil {
            let selection = selectedWorktrees
            return !selection.isEmpty && selection.allSatisfy { $0.protectedReason == nil }
        }
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

    func saveConnection(_ connection: SavedConnection, password: String) throws {
        var next = settings
        if let index = next.connections.firstIndex(where: { $0.id == connection.id }) {
            next.connections[index] = connection
        } else {
            next.connections.append(connection)
        }
        guard settingsReadable else { throw SettingsError.unreadable }
        let existing = settings.connections.contains { $0.id == connection.id }
        // Preserve the old secret so a failed settings write cannot silently pair
        // old connection settings with a newly entered password.
        let previousPassword = existing ? try credentials.password(for: connection.id) : nil
        try credentials.save(password: password, for: connection.id)
        do {
            try persist(next)
        } catch {
            let settingsError = error
            do {
                if let previousPassword {
                    try credentials.save(password: previousPassword, for: connection.id)
                } else {
                    try credentials.remove(for: connection.id)
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
        destination = .connection(connection.id)
        refresh()
    }

    func forgetConnection(_ connection: SavedConnection) {
        do {
            var next = settings
            next.connections.removeAll { $0.id == connection.id }
            try persist(next)
            try credentials.remove(for: connection.id)
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
    }

    func password(for connectionID: UUID) throws -> String {
        guard let password = try credentials.password(for: connectionID) else {
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
        refresh(useCache: true)
    }

    /// Explicit refresh, including after deletion, always reads the repository again.
    func refresh() {
        refresh(useCache: false)
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
            projectSessions[project.id]?.updateOverview {
                $0.branches = nil
                $0.branchError = nil
                $0.isLoadingBranches = true
            }
            loadSelection()
        } catch { errorMessage = error.localizedDescription }
    }

    private func refresh(useCache: Bool) {
        guard !isDeleting else { return }
        refreshTask?.cancel()
        branchTask?.cancel()
        sizeQueue.cancelAll()
        selectedProjectSession?.pauseScans()
        let token = UUID()
        generation = token
        loadError = nil
        progressText = ""
        let project = selectedProject
        let connection = selectedConnection
        let session = project.flatMap { projectSessions[$0.id] }
        if selectedProjectSession !== session { selectedProjectSession = session }
        databases = []
        guard destination != nil else {
            isRefreshing = false
            return
        }
        if useCache, let session, session.hasLoadedInventory {
            let cachedRows = session.snapshots
            session.performBatchUpdates {
                for row in cachedRows {
                    updateRow(row.id) { $0.sizeState = .idle }
                }
                if let project { loadProjectOverview(project, token: token) }
                for row in cachedRows where row.needsSizeLoad {
                    enqueueSizeScan(row.worktree, token: token)
                }
            }
            worktreeSelection.formIntersection(Set(session.rows.map(\.id)))
            let missingStatuses = cachedRows.filter(\.needsStatusLoad).map(\.worktree)
            isRefreshing = !missingStatuses.isEmpty
            guard !missingStatuses.isEmpty else {
                refreshTask = nil
                return
            }
            progressText = "Loading remaining Git status…"
            refreshTask = Task {
                defer { finishRefresh(token: token) }
                await loadGitStatuses(missingStatuses, token: token)
            }
            return
        }
        // Preserve current content and identities while the new inventory loads.
        // A failed load invalidates reuse but doesn't destroy the visible snapshot.
        session?.invalidateInventory()
        isRefreshing = true
        progressText = "Refreshing…"
        refreshTask = Task {
            defer { finishRefresh(token: token) }
            guard generation == token, !Task.isCancelled else { return }
            do {
                if let project, let session {
                    let records = try await git.listWorktrees(project: project)
                    guard generation == token, !Task.isCancelled else { return }
                    session.performBatchUpdates {
                        session.reconcile(records, refresh: true)
                        // Reset load state but retain last successful measurements
                        // until replaced. Rows remain displayed during refresh.
                        session.updateOverview {
                            $0.branches = nil
                            $0.branchError = nil
                            $0.isLoadingBranches = true
                            $0.gitUsageError = nil
                            $0.gitRefreshPending = true
                        }
                        worktreeSelection.formIntersection(Set(records.map(\.id)))
                        loadProjectOverview(project, token: token)
                        for record in records where record.exists && !record.isBare {
                            enqueueSizeScan(record, token: token)
                        }
                    }
                    progressText = "Refreshing Git status…"
                    await loadGitStatuses(records, token: token)
                } else if let connection {
                    let password = try password(for: connection.id)
                    let records = try await databaseService.databases(settings: connection.settings, password: password)
                    guard generation == token, !Task.isCancelled else { return }
                    databases = records
                    databaseSelection.formIntersection(Set(records.map(\.id)))
                }
            } catch {
                guard generation == token, !Task.isCancelled else { return }
                loadError = error.localizedDescription
            }
        }
    }

    private func finishRefresh(token: UUID) {
        guard generation == token else { return }
        isRefreshing = false
        progressText = ""
    }

    private func loadGitStatuses(_ records: [WorktreeRecord], token: UUID) async {
        for record in records where record.exists && !record.isBare {
            guard generation == token, !Task.isCancelled else { return }
            do {
                let status = try await git.status(worktree: record)
                guard generation == token, !Task.isCancelled else { return }
                updateRow(record.id) {
                    $0.status = status
                    $0.statusError = nil
                    $0.statusRefreshPending = false
                }
            } catch {
                guard generation == token, !Task.isCancelled else { return }
                updateRow(record.id) {
                    $0.statusError = error.localizedDescription
                    $0.statusRefreshPending = false
                }
            }
        }
    }

    func canRefreshSize(_ row: WorktreeRow) -> Bool {
        selectedProject != nil && row.worktree.exists && !row.worktree.isBare
            && selectedProjectSession?.hasLoadedInventory == true
            && !row.isSizeBusy && !isDeleting && !isModalPresented
    }

    func refreshWorktreeSize(_ id: String) {
        guard let row = selectedProjectSession?.row(id: id)?.row, canRefreshSize(row) else { return }
        enqueueSizeScan(row.worktree, token: generation)
    }

    private func enqueueSizeScan(_ worktree: WorktreeRecord, token: UUID) {
        updateRow(worktree.id) {
            $0.sizeState = .queued
            $0.sizeRefreshPending = true
            $0.usageError = nil
        }
        sizeQueue.enqueue(worktree, onStarted: { [weak self] in
            guard let self, generation == token else { return }
            updateRow(worktree.id) { $0.sizeState = .scanning }
        }, onFinished: { [weak self] result in
            guard let self, generation == token else { return }
            updateRow(worktree.id) { row in
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

    private func updateOverview(_ update: (inout ProjectOverview) -> Void) {
        selectedProjectSession?.updateOverview(update)
    }

    private func loadProjectOverview(_ project: ProjectRecord, token: UUID) {
        if projectOverview.needsBranchLoad {
            let records = worktrees.map(\.worktree)
            updateOverview { $0.isLoadingBranches = true }
            branchTask = Task {
                do {
                    let inspection = try await inspectBranches(project, records)
                    guard generation == token, !Task.isCancelled else { return }
                    updateOverview {
                        $0.branches = inspection
                        $0.branchError = nil
                        $0.isLoadingBranches = false
                    }
                } catch {
                    guard generation == token, !Task.isCancelled else { return }
                    updateOverview {
                        $0.branchError = error.localizedDescription
                        $0.isLoadingBranches = false
                    }
                }
            }
        }
        if projectOverview.needsGitSizeLoad {
            updateOverview {
                $0.gitSizeState = .queued
                $0.gitRefreshPending = true
                $0.gitUsageError = nil
            }
            sizeQueue.enqueueGitStorage(project, onStarted: { [weak self] in
                guard let self, generation == token else { return }
                updateOverview { $0.gitSizeState = .scanning }
            }, onFinished: { [weak self] result in
                guard let self, generation == token else { return }
                updateOverview {
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
            // Do not keep traversing folders the user is about to remove.
            let ids = Set(selectedWorktrees.map(\.id))
            sizeQueue.cancel(worktreeIDs: ids)
            for id in ids { updateRow(id) { $0.sizeState = .idle } }
            deletionRequest = DeletionRequest(items: .worktrees(project, selectedWorktrees))
        } else if let connection = selectedConnection {
            deletionRequest = DeletionRequest(items: .databases(connection, selectedDatabases))
        }
    }

    func deletionState(for name: String, in request: DeletionRequest) -> DeletionState {
        guard deletionBatchID == request.id else { return .queued }
        return deletionEntries.first { $0.name == name }?.state ?? .queued
    }

    func delete(_ request: DeletionRequest) async {
        guard !isDeleting, deletionRequest?.id == request.id else { return }
        isDeleting = true
        deletionError = nil
        deletionBatchID = request.id
        deletionEntries = request.entries
        progressText = "Authenticating…"
        defer { isDeleting = false }
        do {
            try await authenticate("authorize permanent deletion of the \(request.count) selected items in DevBox")
        } catch {
            // Leave the confirmation open so authentication cancellation is non-destructive.
            deletionError = "\(error.localizedDescription)\nNothing was deleted."
            progressText = ""
            return
        }
        switch request.items {
        case .worktrees(let project, let rows):
            await runDeletionBatch { index in
                try await git.remove(worktree: rows[index].worktree, project: project, allowDirty: true)
            }
        case .databases(let connection, let rows):
            do {
                let password = try password(for: connection.id)
                await runDeletionBatch { index in
                    try await dropDatabase(rows[index], connection.settings, password)
                }
            } catch {
                for index in deletionEntries.indices {
                    deletionEntries[index].state = .notAttempted(error.localizedDescription)
                }
            }
        }
        progressText = ""
        worktreeSelection = []
        databaseSelection = []
        queuedSheet = .results(.init(title: "Deletion Results", entries: deletionEntries))
        deletionRequest = nil
        isDeleting = false
        refresh()
    }

    private func runDeletionBatch(_ operation: @MainActor (Int) async throws -> Void) async {
        // Deliberately sequential: the next item is submitted only after this await.
        for index in deletionEntries.indices {
            deletionEntries[index].state = .deleting
            progressText = "Deleting \(index + 1) of \(deletionEntries.count): \(deletionEntries[index].name)"
            do {
                try await operation(index)
                deletionEntries[index].state = .completed
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
