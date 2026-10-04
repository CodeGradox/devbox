import Foundation

enum WorktreeFilter: String, CaseIterable, Identifiable {
    case all = "All", changed = "Uncommitted", merged = "Merged"
    var id: Self { self }
}

struct WorktreeFilterCounts: Equatable {
    var all = 0
    var changed = 0
    var merged = 0

    subscript(_ filter: WorktreeFilter) -> Int {
        switch filter {
        case .all: all
        case .changed: changed
        case .merged: merged
        }
    }
}

extension WorktreeState {
    var sortName: String { presentation.folderName }
    var sortBranch: String { presentation.branchLabel }
    var sortChanges: Int? {
        guard row.worktree.exists, !row.worktree.isBare, row.statusError == nil,
              let status = row.status else { return nil }
        return status.staged + status.modified + status.untracked + status.conflicted
    }
    var sortMerge: Int? {
        guard !branchLoading, branchError == nil else { return nil }
        switch lifecycle?.mergeState {
        case .base: return 0
        case .merged: return 1
        case .notMerged: return 2
        case .unknown, nil: return nil
        }
    }
    var sortBytes: Int64? { row.usage?.bytes }

    func matches(_ filter: WorktreeFilter) -> Bool {
        switch filter {
        case .all: true
        case .changed: (sortChanges ?? 0) > 0
        case .merged: sortMerge == 1
        }
    }
}

/// Native sorting uses immutable values, without reaching across the observable
/// models' actor boundary. Cells still receive the same stable state references.
struct WorktreeListRow: Identifiable, Equatable {
    let id: String
    let state: WorktreeState
    let name: String
    let branch: String
    let changes: Int?
    let merged: Int?
    let bytes: Int64?

    @MainActor
    init(_ state: WorktreeState) {
        id = state.id
        self.state = state
        name = state.sortName
        branch = state.sortBranch
        changes = state.sortChanges
        merged = state.sortMerge
        bytes = state.sortBytes
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.state === rhs.state && lhs.name == rhs.name && lhs.branch == rhs.branch
            && lhs.changes == rhs.changes && lhs.merged == rhs.merged && lhs.bytes == rhs.bytes
    }
}

/// Unknown measurements/statuses go last in either direction, not among zeros.
struct WorktreeSort: SortComparator {
    enum Column: Hashable { case name, branch, changes, merged, size }
    var column: Column
    var order: SortOrder = .forward

    func compare(_ lhs: WorktreeListRow, _ rhs: WorktreeListRow) -> ComparisonResult {
        switch column {
        case .name: return directed(lhs.name.localizedStandardCompare(rhs.name))
        case .branch: return directed(lhs.branch.localizedStandardCompare(rhs.branch))
        case .changes: return compareOptional(lhs.changes, rhs.changes)
        case .merged: return compareOptional(lhs.merged, rhs.merged)
        case .size: return compareOptional(lhs.bytes, rhs.bytes)
        }
    }

    private func compareOptional<T: Comparable>(_ lhs: T?, _ rhs: T?) -> ComparisonResult {
        switch (lhs, rhs) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        case let (left?, right?):
            return directed(left == right ? .orderedSame : left < right ? .orderedAscending : .orderedDescending)
        }
    }

    private func directed(_ result: ComparisonResult) -> ComparisonResult {
        guard order == .reverse else { return result }
        switch result {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }

    static func precedes(_ lhs: WorktreeListRow, _ rhs: WorktreeListRow, using comparators: [Self]) -> Bool {
        for comparator in comparators {
            let result = comparator.compare(lhs, rhs)
            if result != .orderedSame { return result == .orderedAscending }
        }
        let result = lhs.name.localizedStandardCompare(rhs.name)
        return result == .orderedSame ? lhs.id < rhs.id : result == .orderedAscending
    }
}
