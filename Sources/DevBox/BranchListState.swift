import CryptoKit
import DevBoxCore
import Foundation
import Observation

enum BranchFilter: String, CaseIterable, Identifiable {
    case all = "All", local = "Local", remote = "Remote"
    var id: Self { self }
}

enum BranchSort: String, CaseIterable, Identifiable {
    case newest = "Newest commit", oldest = "Oldest commit", name = "Name"
    var id: Self { self }
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

    init(_ branch: ManagedBranch) {
        self.branch = branch
        displayName = branch.remoteName.map { "\($0)/\(branch.name)" } ?? branch.name
        commitDate = branch.committedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Unknown"
        let timestamp = branch.committedAt.map {
            $0.formatted(date: .complete, time: .complete)
        } ?? "Unknown commit date"
        commitHelp = "Latest commit: \(timestamp)\nCommit: \(branch.commit)"
        avatarURL = Gravatar.url(email: branch.committerEmail)
    }
}

/// Inventory and presentation are session-local. Remote rows describe local tracking refs,
/// not a live view of the server.
@MainActor @Observable
final class BranchListState {
    private(set) var rows: [BranchRowPresentation] = []
    private(set) var hasLoadedInventory = false
    var selection: Set<String> = []
    var filter: BranchFilter = .all {
        didSet { if filter != oldValue { updateRows() } }
    }
    var query = "" {
        didSet { if query != oldValue { updateRows() } }
    }
    var sort: BranchSort = .newest {
        didSet { if sort != oldValue { updateRows() } }
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
        updateRows()
    }

    func invalidateInventory() {
        hasLoadedInventory = false
        selection.removeAll()
    }

    func removeConfirmedBranches(ids: Set<String>) {
        inventory.removeAll { ids.contains($0.id) }
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

    private func updateRows() {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = inventory.filter { row in
            let branch = row.branch
            let matchesFilter = filter == .all || (filter == .remote) == branch.isRemote
            let matchesQuery = search.isEmpty ||
                row.displayName.localizedCaseInsensitiveContains(search) ||
                branch.committerName.localizedCaseInsensitiveContains(search) ||
                branch.committerEmail.localizedCaseInsensitiveContains(search)
            return matchesFilter && matchesQuery
        }.sorted { lhs, rhs in
            if sort != .name, lhs.branch.committedAt != rhs.branch.committedAt {
                // Unknown dates always follow known dates, in either direction.
                guard let left = lhs.branch.committedAt else { return false }
                guard let right = rhs.branch.committedAt else { return true }
                return sort == .newest ? left > right : left < right
            }
            let order = lhs.displayName.localizedStandardCompare(rhs.displayName)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
        if rows != next { rows = next }
        selection.formIntersection(Set(next.map(\.id)))
    }
}
