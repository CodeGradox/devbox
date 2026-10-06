import CryptoKit
import DevBoxCore
import Foundation
import Observation

enum BranchFilter: String, CaseIterable, Identifiable {
    case all = "All", local = "Local", remote = "Remote"
    var id: Self { self }
}

struct BranchCommitter: Hashable, Identifiable {
    let name: String
    let email: String
    var id: Self { self }
    var label: String {
        let name = name.isEmpty ? "Unknown" : name
        return email.isEmpty ? "\(name) (no email)" : "\(name) <\(email)>"
    }
}

/// Compare whole rows so unknown dates stay last even when a table header reverses order.
struct BranchRowComparator: SortComparator {
    enum Column: Hashable { case branch, date, committer }
    var column: Column
    var order: SortOrder = .forward

    func compare(_ lhs: BranchRowPresentation, _ rhs: BranchRowPresentation) -> ComparisonResult {
        let result: ComparisonResult
        switch column {
        case .branch:
            result = lhs.displayName.localizedStandardCompare(rhs.displayName)
        case .committer:
            let name = lhs.committer.name.localizedStandardCompare(rhs.committer.name)
            result = name == .orderedSame
                ? lhs.committer.email.localizedStandardCompare(rhs.committer.email) : name
        case .date:
            switch (lhs.branch.committedAt, rhs.branch.committedAt) {
            case (nil, nil): return .orderedSame
            case (nil, _): return .orderedDescending
            case (_, nil): return .orderedAscending
            case let (left?, right?):
                result = left.compare(right)
            }
        }
        guard order == .reverse else { return result }
        switch result {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }
}

enum Gravatar {
    static func url(email: String) -> URL? {
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        let hash = SHA256.hash(data: Data(normalized.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return URL(string: "https://www.gravatar.com/avatar/\(hash)?s=64&d=404")
    }
}

struct BranchRowPresentation: Identifiable, Equatable {
    let branch: ManagedBranch
    var id: String { branch.reference }
    let displayName: String
    let commitDate: String
    let commitHelp: String
    let avatarURL: URL?
    let githubBranch: GitHubBranch?
    var committer: BranchCommitter {
        BranchCommitter(name: branch.committerName, email: branch.committerEmail)
    }

    init(_ branch: ManagedBranch) {
        self.branch = branch
        displayName = branch.remoteName.map { "\($0)/\(branch.name)" } ?? branch.name
        commitDate = branch.committedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Unknown"
        let timestamp = branch.committedAt.map {
            $0.formatted(date: .complete, time: .complete)
        } ?? "Unknown commit date"
        commitHelp = "Latest commit: \(timestamp)\nCommit: \(branch.commit)"
        avatarURL = Gravatar.url(email: branch.committerEmail)
        githubBranch = branch.githubURL.flatMap { GitHubBranch(branchURL: $0) }
    }
}

/// Inventory and presentation are session-local. Remote rows describe local tracking refs,
/// not a live view of the server.
@MainActor @Observable
final class BranchListState {
    let loading = ProjectLoadingState()
    private(set) var rows: [BranchRowPresentation] = []
    private(set) var visibleGitHubBranches: Set<GitHubBranch> = []
    private(set) var hasLoadedInventory = false
    var selection: Set<String> = []
    var filter: BranchFilter = .all {
        didSet { if filter != oldValue { updateRows() } }
    }
    var query = "" {
        didSet { if query != oldValue { updateRows() } }
    }
    var sortOrder = [BranchRowComparator(column: .date, order: .reverse)] {
        didSet { if sortOrder != oldValue { updateRows() } }
    }
    private(set) var committers: [BranchCommitter] = []
    var committer: BranchCommitter? {
        didSet { if committer != oldValue { updateRows() } }
    }
    var lastFetchedAt: Date? {
        didSet { updateFetchPresentation() }
    }
    private(set) var fetchDescription = "Remote branches are cached tracking refs; not fetched in this session."
    @ObservationIgnored private var inventory: [BranchRowPresentation] = []

    var selectedBranches: [ManagedBranch] {
        rows.filter { selection.contains($0.id) }.map(\.branch)
    }

    func reconcile(_ branches: [ManagedBranch]) {
        let previous = Dictionary(inventory.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen: Set<String> = []
        inventory = branches.filter { seen.insert($0.reference).inserted }.map { branch in
            if let row = previous[branch.reference], row.branch == branch { return row }
            return BranchRowPresentation(branch)
        }
        hasLoadedInventory = true
        updateCommitters()
        updateRows()
    }

    func invalidateInventory() {
        hasLoadedInventory = false
        selection.removeAll()
    }

    func removeConfirmedBranches(ids: Set<String>) {
        inventory.removeAll { ids.contains($0.id) }
        updateCommitters()
        updateRows()
    }

    func refreshPresentation() {
        inventory = inventory.map { BranchRowPresentation($0.branch) }
        updateRows()
        updateFetchPresentation()
    }

    private func updateFetchPresentation() {
        if let lastFetchedAt {
            fetchDescription = "Remote branches are cached tracking refs · Last fetched \(lastFetchedAt.formatted(date: .abbreviated, time: .standard))"
        } else {
            fetchDescription = "Remote branches are cached tracking refs; not fetched in this session."
        }
    }

    private func updateCommitters() {
        // Options come from the full inventory, never from the filtered rows.
        committers = Set(inventory.map(\.committer)).sorted {
            let result = $0.label.localizedStandardCompare($1.label)
            if result != .orderedSame { return result == .orderedAscending }
            return ($0.name, $0.email) < ($1.name, $1.email)
        }
        if let committer, !committers.contains(committer) { self.committer = nil }
    }

    private func updateRows() {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = inventory.filter { row in
            let branch = row.branch
            let matchesFilter = filter == .all || (filter == .remote) == branch.isRemote
            let matchesQuery = search.isEmpty ||
                row.displayName.localizedCaseInsensitiveContains(search) ||
                branch.committerName.localizedCaseInsensitiveContains(search) ||
                branch.committerEmail.localizedCaseInsensitiveContains(search)
            return matchesFilter && matchesQuery && (committer == nil || row.committer == committer)
        }.sorted { lhs, rhs in
            for comparator in sortOrder {
                let result = comparator.compare(lhs, rhs)
                if result != .orderedSame { return result == .orderedAscending }
            }
            // Stable ascending ties, independent of inventory order or sort direction.
            let order = lhs.displayName.localizedStandardCompare(rhs.displayName)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
        if rows != next { rows = next }
        let branches = Set(next.compactMap(\.githubBranch))
        if visibleGitHubBranches != branches { visibleGitHubBranches = branches }
        selection.formIntersection(Set(next.map(\.id)))
    }
}
