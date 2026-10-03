import Foundation

public enum BranchMergeState: String, Sendable {
    case base, merged, notMerged, unknown
}

public struct BranchLifecycle: Sendable, Equatable {
    public let mergeState: BranchMergeState
    public let upstreamGone: Bool
    public let detail: String?

    public init(mergeState: BranchMergeState, upstreamGone: Bool, detail: String? = nil) {
        self.mergeState = mergeState
        self.upstreamGone = upstreamGone
        self.detail = detail
    }
}

public struct BranchTarget: Identifiable, Hashable, Sendable {
    public let reference: String
    public let label: String
    public var id: String { reference }

    public init(reference: String, label: String) {
        self.reference = reference
        self.label = label
    }
}

public struct BranchInspection: Sendable, Equatable {
    public let targetLabel: String
    public let targetReference: String?
    public let targetCommit: String?
    public let availableTargets: [BranchTarget]
    public let byWorktreeID: [String: BranchLifecycle]
    public let warning: String?

    public init(
        targetLabel: String, targetReference: String? = nil, targetCommit: String? = nil,
        availableTargets: [BranchTarget] = [], byWorktreeID: [String: BranchLifecycle] = [:],
        warning: String? = nil
    ) {
        self.targetLabel = targetLabel
        self.targetReference = targetReference
        self.targetCommit = targetCommit
        self.availableTargets = availableTargets
        self.byWorktreeID = byWorktreeID
        self.warning = warning
    }
}

/// Local ref/history inspection only; never fetches, prunes, or infers patch equivalence.
public struct BranchStatusService: Sendable {
    public init() {}

    public func inspect(project: ProjectRecord, worktrees: [WorktreeRecord]) async throws -> BranchInspection {
        try await GitService().background {
            try Self.inspectSnapshot(project: project, worktrees: worktrees)
        }
    }

    private struct Ref {
        let name: String
        let hash: String
        let upstream: String
        let symbolic: String
    }

    private static func inspectSnapshot(project: ProjectRecord, worktrees: [WorktreeRecord]) throws -> BranchInspection {
        func git(_ args: [String]) throws -> String {
            let data = try GitService.git(["--git-dir", project.id] + args)
            guard let text = String(data: data, encoding: .utf8) else { throw GitServiceError.invalidOutput }
            return text
        }
        // Ref names cannot contain tabs/newlines; worktree paths are never parsed here.
        func refs() throws -> [String: Ref] {
            let text = try git(["for-each-ref", "--format=%(refname)%09%(objectname)%09%(upstream)%09%(symref)"])
            var result: [String: Ref] = [:]
            for line in text.split(separator: "\n") {
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard fields.count == 4 else { throw GitServiceError.invalidOutput }
                result[fields[0]] = Ref(name: fields[0], hash: fields[1], upstream: fields[2], symbolic: fields[3])
            }
            return result
        }
        func optional<T>(_ operation: () throws -> T) throws -> T? {
            do { return try operation() }
            catch is CancellationError { throw CancellationError() }
            catch { try BlockingIOExecutor.checkCancellation(); return nil }
        }
        func resolve(_ revision: String) throws -> String? {
            try optional {
                try git(["rev-parse", "--verify", "--end-of-options", revision + "^{commit}"])
                    .trimmingCharacters(in: .newlines)
            }
        }
        func validHash(_ value: String) -> Bool {
            (value.count == 40 || value.count == 64) && value.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            } && value.contains(where: { $0 != "0" })
        }
        func label(_ reference: String) -> String {
            for prefix in ["refs/heads/", "refs/remotes/"] where reference.hasPrefix(prefix) {
                return String(reference.dropFirst(prefix.count))
            }
            return reference
        }
        let initial = try optional { try refs() } ?? [:]
        let targets = initial.values.filter {
            ($0.name.hasPrefix("refs/heads/") || $0.name.hasPrefix("refs/remotes/")) && $0.symbolic.isEmpty
        }.map { BranchTarget(reference: $0.name, label: label($0.name)) }
            .sorted { $0.reference < $1.reference }
        let primary = worktrees.first(where: \.isMain)
        let targetRef = project.mergeTarget ?? primary?.branch.map { "refs/heads/" + $0 }
        let targetLabel = targetRef.map(label) ?? (primary?.isBare == true ? "Bare repository" : "Main checkout HEAD")
        var warning: String?
        var targetHash: String?
        if let explicit = project.mergeTarget {
            // Membership in Git's own ref listing validates full refs and excludes revision expressions/options.
            if targets.contains(where: { $0.reference == explicit }) {
                targetHash = try resolve(explicit)
                if let resolved = targetHash, resolved != initial[explicit]?.hash {
                    targetHash = nil
                    warning = "The selected comparison target changed during inspection. Refresh before comparing."
                }
            }
            if targetHash == nil && warning == nil { warning = "The selected comparison target is missing or invalid." }
        } else if let primary, primary.exists, !primary.isBare, validHash(primary.head) {
            if let targetRef, initial[targetRef]?.hash != primary.head {
                warning = "The main checkout branch changed. Refresh before comparing."
            } else {
                targetHash = try resolve(primary.head)
                if targetHash == nil { warning = "The main checkout history is unavailable." }
            }
        } else {
            warning = "The main checkout is missing, bare, or has no commits. Select a comparison target."
        }
        let shallow = try optional { try git(["rev-parse", "--is-shallow-repository"]) }
        let isShallow = shallow?.trimmingCharacters(in: .newlines) != "false"
        var merged: [String: String]?
        if let targetHash {
            merged = try optional {
                let output = try git(["for-each-ref", "--merged=" + targetHash,
                                      "--format=%(refname)%09%(objectname)", "refs/heads/"])
                var result: [String: String] = [:]
                for line in output.split(separator: "\n") {
                    let fields = line.split(separator: "\t").map(String.init)
                    guard fields.count == 2 else { throw GitServiceError.invalidOutput }
                    result[fields[0]] = fields[1]
                }
                return result
            }
            if merged == nil { warning = "Git could not inspect the comparison history." }
        }
        var statuses: [String: BranchLifecycle] = [:]
        for worktree in worktrees {
            try BlockingIOExecutor.checkCancellation()
            let ref = worktree.branch.map { "refs/heads/" + $0 }
            let upstream = ref.flatMap { initial[$0]?.upstream } ?? ""
            let gone = !upstream.isEmpty && initial[upstream] == nil
            var state: BranchMergeState = .unknown
            var detail: String? = warning
            if worktree.isBare || !worktree.exists {
                detail = "This checkout is bare or missing."
            } else if !validHash(worktree.head) {
                detail = "This checkout has no captured commit."
            } else if let ref, initial[ref]?.hash != worktree.head {
                detail = "The branch moved since the worktree snapshot. Refresh before comparing."
            } else if let targetHash, let merged {
                if (ref != nil && ref == targetRef) || (project.mergeTarget == nil && worktree.isMain) {
                    state = .base
                } else if let ref {
                    state = merged[ref] == worktree.head ? .merged : (isShallow ? .unknown : .notMerged)
                } else if let count = try optional({
                    let output = try git(["rev-list", "--count", worktree.head, "--not", targetHash])
                    guard let count = Int(output.trimmingCharacters(in: .newlines)) else {
                        throw GitServiceError.invalidOutput
                    }
                    return count
                }) {
                    state = count == 0 ? .merged : (isShallow ? .unknown : .notMerged)
                }
                detail = state == .unknown ? "Available history cannot prove ancestry (it may be shallow or incomplete)." : nil
            }
            statuses[worktree.id] = BranchLifecycle(mergeState: state, upstreamGone: gone, detail: detail)
        }
        // Detect concurrent ref movement, including movement between enumeration and --merged.
        let final = try optional { try refs() }
        let targetMoved = targetRef.map { initial[$0]?.hash != final?[$0]?.hash } ?? false
        for worktree in worktrees {
            let ref = worktree.branch.map { "refs/heads/" + $0 }
            let moved = ref.map { initial[$0]?.hash != final?[$0]?.hash } ?? false
            // Upstream config and remote-tracking refs can change without moving
            // the local branch. Use the final snapshot for this independent badge.
            let upstream = ref.flatMap { final?[$0]?.upstream } ?? ""
            let gone = final != nil && !upstream.isEmpty && final?[upstream] == nil
            if final == nil || targetMoved || moved {
                statuses[worktree.id] = BranchLifecycle(
                    mergeState: .unknown, upstreamGone: gone,
                    detail: "Refs changed or became unavailable during inspection. Refresh before comparing."
                )
            } else if let previous = statuses[worktree.id] {
                statuses[worktree.id] = BranchLifecycle(
                    mergeState: previous.mergeState, upstreamGone: gone, detail: previous.detail
                )
            }
        }
        if targetMoved { warning = "The comparison target moved during inspection. Refresh before comparing." }
        return BranchInspection(targetLabel: targetLabel, targetReference: targetRef, targetCommit: targetHash,
                                availableTargets: targets, byWorktreeID: statuses, warning: warning)
    }
}
