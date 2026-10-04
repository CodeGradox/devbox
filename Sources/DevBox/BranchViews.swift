import DevBoxCore
import SwiftUI

struct BranchesView: View {
    let project: ProjectRecord
    let session: BranchListState
    @Environment(AppStore.self) private var store
    @AppStorage("devbox.gravatarEnabled") private var gravatarEnabled = false
    @State private var showsOptions = false

    private var busy: Bool { store.isRefreshing || store.isDeleting || store.isModalPresented }

    var body: some View {
        @Bindable var session = session
        VStack(spacing: 0) {
            controls
            if let error = store.loadError, session.rows.isEmpty {
                LoadErrorView(message: error, retry: store.refresh)
            } else {
                if let error = store.loadError {
                    Label("Refresh failed. Showing last-known branches.", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange).help(error)
                        .padding(.vertical, 8)
                }
                Table(session.rows, selection: $session.selection, sortOrder: $session.sortOrder) {
                    TableColumn("Branch", sortUsing: BranchRowComparator(column: .branch)) { row in
                        BranchNameCell(row: row)
                    }
                        .width(min: 150, ideal: 230)
                    TableColumn("Latest commit date", sortUsing: BranchRowComparator(column: .date)) { row in
                        Text(row.commitDate).help(row.commitHelp)
                    }
                    .width(min: 140, ideal: 175)
                    TableColumn("Committer", sortUsing: BranchRowComparator(column: .committer)) { row in
                        BranchCommitterCell(row: row, gravatarEnabled: gravatarEnabled)
                    }
                    .width(min: 150, ideal: 200)
                    TableColumn("GitHub") { row in BranchGitHubCell(url: row.branch.githubURL) }
                        .width(min: 60, ideal: 70, max: 90)
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    Button("Delete selected…", role: .destructive) {
                        session.selection = ids
                        store.prepareDeletion()
                    }
                    .disabled(!canDelete(ids))
                }
                .overlay {
                    if session.rows.isEmpty {
                        if store.isRefreshing {
                            ProgressView("Reading branches…")
                        } else {
                            ContentUnavailableView(
                                "No Branches", systemImage: "arrow.triangle.branch",
                                description: Text("No branches match the current filter.")
                            )
                        }
                    }
                }
            }
            StatusFooter {
                Text("\(session.rows.count) branches · \(session.selectedBranches.count) selected")
            }
        }
    }

    private var controls: some View {
        @Bindable var session = session
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Search branches or committers", text: $session.query)
                    .textFieldStyle(.roundedBorder)
                Picker("Show", selection: $session.filter) {
                    ForEach(BranchFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().frame(width: 100)
                Picker("Committer", selection: $session.committer) {
                    Text("All committers").tag(nil as BranchCommitter?)
                    ForEach(session.committers) { Text($0.label).tag(Optional($0)) }
                }
                .labelsHidden().frame(width: 185)
                Button("Fetch & Prune", action: store.fetchBranches)
                    .help("Contacts all remotes, fetches branches, and prunes obsolete remote tracking refs.")
                    .disabled(busy)
                Button {
                    showsOptions.toggle()
                } label: {
                    Image(systemName: "info.circle")
                }
                .accessibilityLabel("Branch information and options")
                .popover(isPresented: $showsOptions) { options }
            }
            if !session.hasLoadedInventory && !store.isRefreshing {
                Label("Inventory needs verification. Refresh local refs, or Fetch & Prune to check remotes, before deleting.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .layoutPriority(1)
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Branch information").font(.headline)
            Text("Latest commit is a proxy for activity, not the last checkout or view. Committer is the commit identity, not the server pusher.")
            Text(session.fetchDescription)
            Text("Refresh rereads local refs without contacting the server. Fetch & Prune contacts all remotes and removes obsolete tracking refs.")
            Divider()
            Toggle("Load committer icons from Gravatar", isOn: $gravatarEnabled)
                .toggleStyle(.checkbox)
            Text("Off by default. Enabling sends a hash of each commit email to Gravatar to load icons.")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(16)
        .frame(width: 360)
    }

    private func canDelete(_ ids: Set<String>) -> Bool {
        let branches = session.rows.filter { ids.contains($0.id) }
        return !busy && session.hasLoadedInventory && !ids.isEmpty &&
            branches.count == ids.count && branches.allSatisfy { $0.branch.protectedReason == nil }
    }
}

struct BranchNameCell: View {
    let row: BranchRowPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(row.displayName).fontWeight(.medium).lineLimit(1)
                .help(row.branch.reference)
            HStack(spacing: 5) {
                Text(row.branch.isRemote ? "Remote" : "Local")
                if let reason = row.branch.protectedReason {
                    Label(reason, systemImage: "lock").lineLimit(1).help(reason)
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct BranchCommitterCell: View {
    let row: BranchRowPresentation
    let gravatarEnabled: Bool

    var body: some View {
        HStack(spacing: 7) {
            BranchAvatar(url: gravatarEnabled ? row.avatarURL : nil)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.branch.committerName.isEmpty ? "Unknown" : row.branch.committerName)
                Text(row.branch.committerEmail.isEmpty ? "—" : row.branch.committerEmail)
                    .font(.caption).foregroundStyle(.secondary)
            }
            .lineLimit(1)
        }
        .help("\(row.branch.committerName)\n\(row.branch.committerEmail)")
    }
}

struct BranchAvatar: View {
    let url: URL?

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: 24, height: 24)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        Image(systemName: "person.crop.circle.fill")
            .resizable().scaledToFit().foregroundStyle(.secondary)
    }
}

struct BranchGitHubCell: View {
    let url: URL?

    var body: some View {
        if let url {
            Link(destination: url) {
                Label("Open", systemImage: "arrow.up.right.square")
            }
            .help("Open branch on GitHub")
        } else {
            Text("—").foregroundStyle(.secondary)
                .help("No GitHub link: this branch is unpublished or its remote is not GitHub.")
        }
    }
}
