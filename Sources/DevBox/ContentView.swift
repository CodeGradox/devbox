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
                    WorktreesView(project: project, session: session)
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
                Button {
                    store.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh status, sizes, and database statistics (⌘R)")
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
            Text("Manage Git worktrees and local MariaDB databases.\nAdd a project or connection to get started.")
        } actions: {
            HStack {
                Button("Add Project…", action: store.addProject)
                    .buttonStyle(.borderedProminent)
                Button("Connect to MariaDB…") { store.connectionEditor = .init() }
            }
        }
    }
}

struct WorktreesView: View {
    let project: ProjectRecord
    let session: ProjectSessionState

    var body: some View {
        VStack(spacing: 0) {
            WorktreesHeader(project: project, session: session)
            MergeTargetPicker(project: project, session: session)
            WorktreeTable(session: session)
            WorktreesFooter(session: session)
        }
    }
}

private struct WorktreesHeader: View {
    let project: ProjectRecord
    let session: ProjectSessionState

    var body: some View {
        DetailHeader(
            title: "Worktrees",
            subtitle: project.path,
            symbol: "arrow.triangle.branch"
        ) {
            ProjectSizeView(
                summary: session.summary,
                presentation: session.sizePresentation
            )
        }
    }
}

private struct WorktreeTable: View {
    @Environment(AppStore.self) private var store
    let session: ProjectSessionState

    var body: some View {
        @Bindable var store = store
        if let error = store.loadError {
            LoadErrorView(message: error, retry: store.refresh)
        } else {
            Table(session.rows, selection: $store.worktreeSelection) {
                TableColumn("Worktree") { state in
                    WorktreeNameCell(state: state)
                }
                .width(min: 180, ideal: 300)
                TableColumn("Branch") { state in
                    WorktreeBranchCell(state: state)
                }
                .width(min: 90, ideal: 150)
                TableColumn("Git Status") { state in
                    WorktreeStatusCell(state: state)
                }
                .width(min: 130, ideal: 190)
                TableColumn("Merge Status") { state in
                    WorktreeLifecycleCell(state: state)
                }
                .width(min: 115, ideal: 150)
                TableColumn("Disk Usage") { state in
                    WorktreeSizeCell(state: state, store: store)
                }
                .width(min: 155, ideal: 180)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                WorktreeContextMenu(session: session, store: store, ids: ids)
            }
            .overlay {
                if session.rows.isEmpty && store.isRefreshing { ProgressView("Loading worktrees…") }
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
    let project: ProjectRecord
    let session: ProjectSessionState

    private var mergeTargetLabel: String {
        session.branchPresentation.targetLabel
            ?? store.selectedProject?.mergeTarget
            ?? "main checkout"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                HStack(spacing: 8) {
                    Text("Merge target").accessibilityHidden(true)
                    BranchTargetPopUpButton(
                        options: session.branchPresentation.options,
                        selection: Binding<String?>(
                            get: { store.selectedProject?.mergeTarget },
                            set: { store.changeMergeTarget($0) }
                        )
                    )
                }
                .frame(maxWidth: 300)
                .disabled(store.isDeleting || store.isModalPresented || session.branchPresentation.isLoading)
                Spacer()
                Text("Compared with \(mergeTargetLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let warning = session.branchPresentation.warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
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
        HStack(spacing: 10) {
            VStack(alignment: .trailing, spacing: 3) {
                if let presentation {
                    Text(presentation.sizeText)
                        .monospacedDigit()
                        .foregroundStyle(row.usage == nil ? .secondary : .primary)
                    if let detail = presentation.sizeDetail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let usage = row.usage {
                    Text(ByteCountFormatter.string(fromByteCount: usage.bytes, countStyle: .file))
                        .monospacedDigit()
                    Text(detail(usage))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(placeholder).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .help(presentation?.sizeHelp ?? usageHelp)
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
                .help(row.isSizeBusy ? placeholder : "Refresh this worktree’s size and file count")
                .accessibilityLabel("Refresh size and file count for \(presentation?.folderName ?? URL(fileURLWithPath: row.worktree.path).lastPathComponent)")
            }
        }
    }

    private var placeholder: String {
        if !row.worktree.exists || row.worktree.isBare { return "—" }
        switch row.sizeState {
        case .queued: return "Queued…"
        case .scanning: return "Scanning…"
        case .idle: return row.usageError == nil ? "Not measured" : "Unavailable"
        }
    }

    private func detail(_ usage: DiskUsage) -> String {
        let count = "\(usage.fileCount.formatted()) files"
        if row.sizeState == .queued { return count + " · queued" }
        if row.sizeState == .scanning { return count + " · updating" }
        if row.usageError != nil { return count + " · update failed" }
        return count + (usage.unreadableCount > 0 ? " · partial" : "")
    }

    private var usageHelp: String {
        var text = "Exclusive allocated disk usage, including ignored files. Shared Git storage and registered nested worktrees are excluded. APFS sharing means actual space recovered may differ."
        if let date = row.measuredAt { text += "\nLast measured \(date.formatted(date: .abbreviated, time: .standard))." }
        if let usage = row.usage, usage.unreadableCount > 0 { text += "\n\(usage.unreadableCount) entries could not be read." }
        if let error = row.usageError { text += "\nRefresh failed: \(error)" }
        return text
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
