import AppKit
import DevBoxCore
import SwiftUI

struct ContentView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.locale) private var locale
    @Binding var theme: AppTheme

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            SidebarView(theme: $theme)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 340)
                .disabled(store.isDeleting)
        } detail: {
            VStack(spacing: 0) {
                if let project = store.selectedProject, let session = store.selectedProjectSession {
                    ProjectView(project: project, session: session)
                } else if let connection = store.selectedConnection, let session = store.selectedDatabaseSession {
                    DatabasesView(connection: connection, session: session)
                } else {
                    WelcomeView()
                }
            }
            .navigationTitle(store.selectedProject?.name ?? store.selectedConnection?.name ?? "DevBox")
            .toolbar {
                WorkspaceToolbar()
            }
        }
        .sheet(item: $store.activeSheet, onDismiss: store.sheetDidDismiss) { sheet in
            switch sheet {
            case .connection(let request):
                ConnectionEditor(connection: request.connection).environment(store)
            case .deletion(let request):
                DeletionConfirmation(request: request).environment(store)
            case .results(let result):
                OperationResultsView(result: result)
            case .github:
                GitHubAccountView(session: store.github)
            }
        }
        .alert("DevBox", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
        .onChange(of: locale.identifier) { store.refreshPresentations() }
    }

}

private struct WorkspaceToolbar: ToolbarContent {
    @Environment(AppStore.self) private var store

    var body: some ToolbarContent {
        if store.destination != nil {
            ToolbarItemGroup {
                if store.selectedProject != nil && store.projectSection == .worktrees {
                    Button { [ids = store.worktreeSelection] in
                        Task { await store.openInEditor(ids) }
                    } label: {
                        Label(store.openInEditorTitle, systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    .help("Open the selected worktree in your preferred editor (⇧⌘O)")
                    .disabled(!store.canOpenInEditor(store.worktreeSelection))
                    OpenWithMenu(store: store, ids: store.worktreeSelection)
                }
                Button {
                    store.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help(store.selectedProject != nil && store.projectSection == .branches
                      ? "Refresh local branch information without contacting remotes (⌘R)"
                      : "Refresh status, sizes, and database statistics (⌘R)")
                .disabled(store.isRefreshing || store.isDeleting)
                Button(role: .destructive) {
                    store.prepareDeletion()
                } label: {
                    Label("Delete Selected…", systemImage: "trash")
                }
                .help("Delete the selected items…")
                .disabled(!store.canDeleteSelection)
            }
        }
    }
}

private struct SidebarView: View {
    @Environment(AppStore.self) private var store
    @Binding var theme: AppTheme

    var body: some View {
        @Bindable var store = store
        List(selection: $store.destination) {
            Section("Projects") {
                ForEach(store.settings.projects) { project in
                    SidebarProjectRow(project: project, session: store.projectSession(for: project))
                        .tag(Destination.project(project.id))
                        .help(project.path)
                        .contextMenu {
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.path)
                            }
                            Divider()
                            Button("Remove from Sidebar") { store.forgetProject(project) }
                        }
                }
                Button(action: store.addProject) {
                    Label("Add Project…", systemImage: "plus")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Section("MariaDB") {
                ForEach(store.settings.connections) { connection in
                    Label(connection.name, systemImage: "externaldrive")
                        .tag(Destination.connection(connection.id))
                        .contextMenu {
                            Button("Edit Connection…") {
                                store.connectionEditor = .init(connection: connection)
                            }
                            Button("Remove Connection") { store.forgetConnection(connection) }
                        }
                }
                Button {
                    store.connectionEditor = .init()
                } label: {
                    Label("Add Connection…", systemImage: "plus")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                GitHubAccountButton(session: store.github) { store.activeSheet = .github() }
                    .disabled(store.isDeleting || store.isModalPresented)
                Text("Appearance")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Appearance", selection: $theme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Choose Light, Dark, or follow the system appearance")
                HStack {
                    Image(systemName: "hammer")
                    Text("DevBox").fontWeight(.medium)
                    Spacer()
                    Text("v0").foregroundStyle(.tertiary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(14)
        }
    }

}

private struct SidebarProjectRow: View {
    let project: ProjectRecord
    let session: ProjectSessionState?

    var body: some View {
        HStack {
            Label(project.name, systemImage: "folder").lineLimit(1)
            Spacer(minLength: 4)
            if let presentation = session?.sizePresentation, let total = presentation.sidebarTotal {
                Text(total)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if presentation.state != .complete {
                    Image(systemName: presentation.state == .calculating ? "clock" : "exclamationmark.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help("Project total is incomplete or being refreshed.")
                }
            }
        }
    }
}

private struct WelcomeView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        ContentUnavailableView {
            Label("Your Local Workspace", systemImage: "square.stack.3d.up")
        } description: {
            Text("Manage Git worktrees, branches, and local MariaDB databases.\nAdd a project or connection to get started.")
        } actions: {
            HStack {
                Button("Add Project…", action: store.addProject)
                    .buttonStyle(.borderedProminent)
                Button("Connect to MariaDB…") { store.connectionEditor = .init() }
            }
        }
    }
}

private struct ProjectView: View {
    @Environment(AppStore.self) private var store
    let project: ProjectRecord
    let session: ProjectSessionState

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            HStack {
                Picker("Repository view", selection: $store.projectSection) {
                    ForEach(ProjectSection.allCases) { section in
                        Text(section.rawValue).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(store.isDeleting || store.isModalPresented)
                Spacer()
                if store.projectSection == .worktrees {
                    CompactProjectSizeView(session: session)
                } else {
                    Text(project.path)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(project.path)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .help(project.path)
            Divider()
            switch store.projectSection {
            case .worktrees:
                WorktreesView(project: project, session: session)
            case .branches:
                BranchesView(project: project, session: session.branchList)
            }
        }
    }
}

struct WorktreesView: View {
    let project: ProjectRecord
    let session: ProjectSessionState

    var body: some View {
        VStack(spacing: 0) {
            WorktreeCleanupSuggestions(session: session)
            WorktreeControls(session: session)
            WorktreeTable(session: session)
            WorktreesFooter(session: session)
        }
    }
}

private struct WorktreeControls: View {
    let session: ProjectSessionState

    var body: some View {
        @Bindable var session = session
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Picker("Show worktrees", selection: $session.filter) {
                    ForEach(WorktreeFilter.allCases) { filter in
                        Text("\(filter.rawValue) \(session.filterCounts[filter])").tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 310)
                Spacer(minLength: 0)
                MergeTargetPicker(session: session)
            }
            if let warning = session.branchPresentation.warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

private struct WorktreeTable: View {
    @Environment(AppStore.self) private var store
    let session: ProjectSessionState

    var body: some View {
        @Bindable var store = store
        @Bindable var session = session
        if let error = store.loadError {
            LoadErrorView(message: error, retry: store.refresh)
        } else {
            Table(session.tableRows, selection: $store.worktreeSelection, sortOrder: $session.sortOrder) {
                TableColumn("Worktree", sortUsing: WorktreeSort(column: .name)) { row in
                    WorktreeNameCell(state: row.state)
                }
                .width(min: 110, ideal: 170)
                TableColumn("Branch", sortUsing: WorktreeSort(column: .branch)) { row in
                    WorktreeBranchCell(state: row.state)
                }
                .width(min: 90, ideal: 120)
                TableColumn("Changes", sortUsing: WorktreeSort(column: .changes)) { row in
                    WorktreeStatusCell(state: row.state)
                }
                .width(min: 95, ideal: 105, max: 120)
                TableColumn("Merged", sortUsing: WorktreeSort(column: .merged)) { row in
                    WorktreeLifecycleCell(state: row.state)
                }
                .width(min: 70, ideal: 80, max: 100)
                TableColumn("Disk", sortUsing: WorktreeSort(column: .size)) { row in
                    WorktreeSizeCell(state: row.state, store: store)
                }
                .width(min: 110, ideal: 120, max: 155)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                WorktreeContextMenu(session: session, store: store, ids: ids)
            } primaryAction: { ids in
                Task { await store.openInEditor(ids) }
            }
            .overlay {
                if session.tableRows.isEmpty {
                    if store.isRefreshing {
                        ProgressView("Loading worktrees…")
                    } else {
                        ContentUnavailableView(
                            "No Worktrees", systemImage: "folder",
                            description: Text("No worktrees match the current filter.")
                        )
                    }
                }
            }
            .onChange(of: session.tableRows.map(\.id), initial: true) { _, ids in
                let selection = store.worktreeSelection.intersection(ids)
                if selection != store.worktreeSelection { store.worktreeSelection = selection }
            }
        }
    }
}

private struct WorktreesFooter: View {
    @Environment(AppStore.self) private var store
    let session: ProjectSessionState

    var body: some View {
        StatusFooter(session: session) {
            if let reason = store.selectedWorktrees.compactMap(\.protectedReason).first {
                Label(reason, systemImage: "lock")
            } else if !store.worktreeSelection.isEmpty {
                Text("\(store.worktreeSelection.count) selected")
            } else {
                Text("Select worktrees to manage · Main checkout is protected")
            }
        }
    }
}

private struct MergeTargetPicker: View {
    @Environment(AppStore.self) private var store
    let session: ProjectSessionState

    private var mergeTargetLabel: String {
        session.branchPresentation.targetLabel
            ?? store.selectedProject?.mergeTarget
            ?? "main checkout"
    }

    var body: some View {
        HStack(spacing: 6) {
            Text("Compare with")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            BranchTargetPopUpButton(
                options: session.branchPresentation.options,
                selection: Binding<String?>(
                    get: { store.selectedProject?.mergeTarget },
                    set: { store.changeMergeTarget($0) }
                )
            )
        }
        .frame(maxWidth: 330)
        .disabled(store.isDeleting || store.isModalPresented || session.branchPresentation.isLoading)
        .help("Commit ancestry compared with \(mergeTargetLabel). Uncommitted changes are shown separately.")
    }

}

/// Table cells may be hosted outside the parent's SwiftUI environment. Keep this
/// cell self-contained: the parent supplies both presentation state and its action.
struct WorktreeDiskUsageCell: View {
    let row: WorktreeRow
    let canRefresh: Bool
    let onRefresh: () -> Void
    var presentation: WorktreePresentation? = nil

    var body: some View {
        let display = presentation ?? WorktreePresentation(row: row)
        HStack(spacing: 8) {
            Text(display.sizeText)
                .monospacedDigit()
                .foregroundStyle(row.usage == nil ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .trailing)
            if row.usage != nil && (row.usageError != nil || (row.usage?.unreadableCount ?? 0) > 0
                || (row.sizeRefreshPending && !row.isSizeBusy)) {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Partial or last-known measurement")
            }
            if row.worktree.exists && !row.worktree.isBare {
                Button {
                    onRefresh()
                } label: {
                    if row.sizeState == .scanning {
                        ProgressView().controlSize(.mini).frame(width: 14, height: 14)
                    } else {
                        Image(systemName: row.sizeState == .queued ? "clock" : "arrow.clockwise")
                            .frame(width: 14, height: 14)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(!canRefresh)
                .help(row.isSizeBusy ? "Size measurement pending" : "Refresh this worktree’s size and file count")
                .accessibilityLabel("Refresh size and file count for \(display.folderName)")
            }
        }
        .lineLimit(1)
        .help([display.sizeDetail, display.sizeHelp].compactMap { $0 }.joined(separator: "\n"))
    }
}

struct DetailHeader<Accessory: View>: View {
    let title: String
    let subtitle: String
    let symbol: String
    let accessory: Accessory

    init(title: String, subtitle: String, symbol: String, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title2.weight(.semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            accessory
        }
        .padding(20)
        Divider()
    }
}

struct StatusFooter<Content: View>: View {
    @Environment(AppStore.self) private var store
    let session: ProjectSessionState?
    let content: Content

    init(session: ProjectSessionState? = nil, @ViewBuilder content: () -> Content) {
        self.session = session
        self.content = content()
    }

    var body: some View {
        Divider()
        HStack(spacing: 8) {
            content.lineLimit(1)
            Spacer()
            if store.isRefreshing || store.isDeleting {
                ProgressView().controlSize(.mini)
                Text(store.progressText).lineLimit(1).truncationMode(.middle)
            } else if let session, session.isMeasuringSizes {
                ProgressView().controlSize(.mini)
                Text(session.sizeProgressText).lineLimit(1)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .frame(height: 34)
        .background(.bar)
    }
}

struct LoadErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Unable to Load", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message).textSelection(.enabled)
        } actions: {
            Button("Try Again", action: retry)
        }
    }
}
