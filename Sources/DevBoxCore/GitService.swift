import Foundation
import Synchronization

public struct ProjectRecord: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let path: String
    public let mergeTarget: String?

    public init(id: String, name: String, path: String, mergeTarget: String? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.mergeTarget = mergeTarget
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

public struct WorktreeRecord: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    /// Resolved once during discovery, for matching cached nested boundaries without I/O.
    public let canonicalPath: String
    public let branch: String?
    public let head: String
    public let isMain: Bool
    public let isBare: Bool
    public let isLocked: Bool
    public let lockReason: String?
    public let isPrunable: Bool
    public let pruneReason: String?
    public let exists: Bool
    public let nestedWorktreePaths: [String]

    public init(
        path: String, branch: String?, head: String, isMain: Bool,
        isBare: Bool = false, isLocked: Bool = false, lockReason: String? = nil,
        isPrunable: Bool = false, pruneReason: String? = nil, exists: Bool = true,
        nestedWorktreePaths: [String] = [], canonicalPath: String? = nil
    ) {
        self.path = path
        self.canonicalPath = canonicalPath ?? path
        self.branch = branch
        self.head = head
        self.isMain = isMain
        self.isBare = isBare
        self.isLocked = isLocked
        self.lockReason = lockReason
        self.isPrunable = isPrunable
        self.pruneReason = pruneReason
        self.exists = exists
        self.nestedWorktreePaths = nestedWorktreePaths
    }

    public func removingNestedWorktrees(at paths: Set<String>) -> Self {
        let remaining = nestedWorktreePaths.filter { !paths.contains($0) }
        guard remaining != nestedWorktreePaths else { return self }
        return Self(
            path: path, branch: branch, head: head, isMain: isMain,
            isBare: isBare, isLocked: isLocked, lockReason: lockReason,
            isPrunable: isPrunable, pruneReason: pruneReason, exists: exists,
            nestedWorktreePaths: remaining, canonicalPath: canonicalPath
        )
    }
}

public struct GitStatus: Sendable {
    public let staged: Int
    public let modified: Int
    public let untracked: Int
    public let conflicted: Int
    public var isClean: Bool { staged + modified + untracked + conflicted == 0 }
}

public struct DiskUsage: Sendable {
    public let bytes: Int64
    public let fileCount: Int
    public let unreadableCount: Int
}

public enum GitServiceError: Error, LocalizedError, Sendable {
    case git(String)
    case invalidOutput
    case protectedWorktree(String)
    case changedWorktree
    case dirtyWorktree

    public var errorDescription: String? {
        switch self {
        case .git(let message): return message
        case .invalidOutput: return "Git returned an unsupported or invalid response."
        case .protectedWorktree(let reason): return "Cannot remove this worktree: \(reason)."
        case .changedWorktree: return "The worktree registration, branch, or HEAD changed. Refresh before removing it."
        case .dirtyWorktree: return "The worktree contains uncommitted changes. Refresh and review it before deleting."
        }
    }
}

/// Git is always invoked directly, never through a shell. Public async operations
/// run on bounded I/O workers so waits don't block UI or Swift's cooperative pool.
public struct GitService: Sendable {
    public init() {}

    public func discoverProject(at path: String) async throws -> ProjectRecord {
        try await background(priority: .interactive) {
            let anchor = Self.canonical(path)
            let common = try Self.line(Self.git(["-C", anchor, "rev-parse", "--path-format=absolute", "--git-common-dir"]))
            let id = Self.canonical(common)
            let bare = try Self.line(Self.git(["-C", anchor, "rev-parse", "--is-bare-repository"])) == "true"
            let root = bare ? anchor : try Self.line(Self.git(["-C", anchor, "rev-parse", "--show-toplevel"]))
            let nameURL = URL(fileURLWithPath: id)
            // `.bare` is the conventional Git directory of a bare clone with a `.git` pointer file.
            let name = Self.anonymousGitDirectoryNames.contains(nameURL.lastPathComponent)
                ? nameURL.deletingLastPathComponent().lastPathComponent : nameURL.lastPathComponent
            return ProjectRecord(id: id, name: name, path: Self.canonical(root))
        }
    }

    public func listWorktrees(project: ProjectRecord) async throws -> [WorktreeRecord] {
        try await background(priority: .interactive) { try Self.worktrees(project) }
    }

    public func status(worktree: WorktreeRecord) async throws -> GitStatus {
        try await background(priority: .interactive) {
            guard !worktree.isBare, worktree.exists else {
                throw GitServiceError.git("Status is unavailable for a bare or missing worktree.")
            }
            return try Self.readStatus(worktree.path)
        }
    }

    public func diskUsage(worktree: WorktreeRecord) async throws -> DiskUsage {
        try await background(priority: .background) {
            try BlockingIOExecutor.checkCancellation()
            // A bare repository consists entirely of shared Git metadata.
            if worktree.isBare { return DiskUsage(bytes: 0, fileCount: 0, unreadableCount: 0) }
            let root = URL(fileURLWithPath: worktree.path)
            let rootValues = try root.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard rootValues.isSymbolicLink != true, rootValues.isDirectory == true else {
                return DiskUsage(bytes: 0, fileCount: 0, unreadableCount: 1)
            }
            let metadata = try Self.canonical(Self.line(Self.git([
                "-C", worktree.path, "rev-parse", "--path-format=absolute", "--git-common-dir"
            ])))
            return try FTSDiskScanner.scan(
                rootPath: Self.canonical(worktree.path),
                excludedDirectoryPath: metadata,
                excludedDirectoryPaths: worktree.nestedWorktreePaths
            )
        }
    }

    /// Repository storage is measured once, separately from exclusive checkout
    /// contents. Bare repositories can contain checkouts inside their Git directory.
    public func gitStorageUsage(project: ProjectRecord) async throws -> DiskUsage {
        try await background(priority: .background) {
            let records = try Self.worktrees(project)
            return try FTSDiskScanner.scan(
                rootPath: Self.canonical(project.id),
                excludedDirectoryPaths: records.filter { !$0.isBare }.map(\.path),
                excludeGitEntries: false
            )
        }
    }

    public func remove(worktree: WorktreeRecord, project: ProjectRecord, allowDirty: Bool) async throws {
        try await background {
            try Self.checkRemovable(worktree)
            guard let current = try Self.worktrees(project).first(where: { $0.path == worktree.path }),
                  current.head == worktree.head, current.branch == worktree.branch else {
                throw GitServiceError.changedWorktree
            }
            try Self.checkRemovable(current)
            // Ensure a replaced directory is still the registered checkout of this repository.
            let common = try Self.line(Self.git(["-C", current.path, "rev-parse", "--path-format=absolute", "--git-common-dir"]))
            let root = try Self.line(Self.git(["-C", current.path, "rev-parse", "--show-toplevel"]))
            let head = try Self.currentHead(at: current.path, listed: current.head)
            let branch = try Self.currentBranch(at: current.path)
            guard Self.canonical(common) == Self.canonical(project.id),
                  Self.canonical(root) == Self.canonical(current.path),
                  head == current.head, branch == current.branch else {
                throw GitServiceError.changedWorktree
            }
            // Only a caller that hasn't accepted uncommitted changes needs the live status.
            // Reading it is otherwise a needless way for removal to fail.
            if !allowDirty {
                guard try Self.readStatus(current.path).isClean else { throw GitServiceError.dirtyWorktree }
            }
            var args = ["--git-dir", project.id, "worktree", "remove"]
            // Git refuses even a clean worktree that contains submodules without --force.
            // Dirtiness was already ruled out above or accepted by the caller.
            let hasSubmodules = FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: current.path).appendingPathComponent(".gitmodules").path
            )
            if allowDirty || hasSubmodules { args.append("--force") }
            args += ["--", current.path]
            // Never interrupt a removal midway: a half-deleted worktree is worse than a slow one.
            _ = try Self.git(args, interruptible: false)
        }
    }

    private static func checkRemovable(_ worktree: WorktreeRecord) throws {
        if worktree.isMain { throw GitServiceError.protectedWorktree("it is the main checkout") }
        if worktree.isBare { throw GitServiceError.protectedWorktree("it is bare") }
        if worktree.isLocked { throw GitServiceError.protectedWorktree("it is locked") }
        if !worktree.exists { throw GitServiceError.protectedWorktree("its directory is missing") }
        if !worktree.nestedWorktreePaths.isEmpty {
            throw GitServiceError.protectedWorktree("it contains registered worktrees; remove the children first and refresh")
        }
    }

    private static func worktrees(_ project: ProjectRecord) throws -> [WorktreeRecord] {
        // The common directory survives a missing discovery anchor/linked checkout.
        let data = try git(["--git-dir", project.id, "worktree", "list", "--porcelain", "-z"])
        var result: [WorktreeRecord] = []
        var fields: [String: String] = [:]
        func append() throws {
            guard let listed = fields["worktree"] else { throw GitServiceError.invalidOutput }
            let isMain = result.isEmpty
            let isBare = fields["bare"] != nil
            let path = isMain && !isBare ? mainCheckout(listed: listed, project: project) : listed
            let ref = fields["branch"]
            let branch = ref.map { $0.hasPrefix("refs/heads/") ? String($0.dropFirst(11)) : $0 }
            var directory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
            result.append(WorktreeRecord(
                path: path, branch: branch, head: fields["HEAD"] ?? "",
                isMain: isMain, isBare: isBare,
                isLocked: fields["locked"] != nil, lockReason: fields["locked"].flatMap { $0.isEmpty ? nil : $0 },
                isPrunable: fields["prunable"] != nil, pruneReason: fields["prunable"].flatMap { $0.isEmpty ? nil : $0 },
                exists: exists
            ))
            fields = [:]
        }
        for field in data.split(separator: 0, omittingEmptySubsequences: false) {
            if field.isEmpty {
                if !fields.isEmpty { try append() }
                continue
            }
            guard let text = String(data: Data(field), encoding: .utf8) else { throw GitServiceError.invalidOutput }
            let pair = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            fields[String(pair[0])] = pair.count == 2 ? String(pair[1]) : ""
        }
        if !fields.isEmpty { try append() }
        // Canonicalize once per registered root, never once per scanned file.
        // Include missing registrations in the boundary map: deleting their parent
        // must not silently orphan registrations or a temporarily unmounted checkout.
        let roots = result.map { Self.canonical($0.path) }
        return result.enumerated().map { index, record in
            let prefix = roots[index] == "/" ? "/" : roots[index] + "/"
            let nested = roots.enumerated().compactMap { childIndex, path in
                childIndex != index && path != roots[index] && path.hasPrefix(prefix) ? path : nil
            }.sorted()
            return WorktreeRecord(
                path: record.path, branch: record.branch, head: record.head, isMain: record.isMain,
                isBare: record.isBare, isLocked: record.isLocked, lockReason: record.lockReason,
                isPrunable: record.isPrunable, pruneReason: record.pruneReason, exists: record.exists,
                nestedWorktreePaths: nested, canonicalPath: roots[index]
            )
        }
    }

    /// Git lists the main worktree as the Git directory itself unless that directory is
    /// `<checkout>/.git`, as with submodules, `--separate-git-dir` and a symlinked `.git`.
    /// Recover the checkout from `core.worktree`, or from the discovery path when it is
    /// the main checkout. Otherwise keep Git's answer.
    private static func mainCheckout(listed: String, project: ProjectRecord) -> String {
        guard canonical(listed) == canonical(project.id) else { return listed }
        if let configured = try? line(git(["--git-dir", project.id, "config", "--get", "core.worktree"])),
           !configured.isEmpty {
            let base = URL(fileURLWithPath: project.id, isDirectory: true)
            let checkout = URL(fileURLWithPath: configured, relativeTo: base).standardizedFileURL.path
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: checkout, isDirectory: &isDirectory), isDirectory.boolValue {
                return checkout
            }
        }
        // The Git directory of a linked worktree is a subdirectory of the common one.
        if let gitDirectory = try? line(git(["-C", project.path, "rev-parse", "--absolute-git-dir"])),
           canonical(gitDirectory) == canonical(project.id) {
            return project.path
        }
        return listed
    }

    private static func currentBranch(at path: String) throws -> String? {
        let result = try run(["-C", path, "symbolic-ref", "--quiet", "HEAD"])
        switch result.status {
        case 0:
            // Not `rev-parse --abbrev-ref`: it prints `heads/x` when a tag is also named `x`.
            let ref = try line(result.output)
            return ref.hasPrefix("refs/heads/") ? String(ref.dropFirst(11)) : ref
        case 1: return nil // Detached HEAD.
        default: throw GitServiceError.git(result.message)
        }
    }

    private static func currentHead(at path: String, listed: String) throws -> String {
        let result = try run(["-C", path, "rev-parse", "--verify", "--quiet", "HEAD"])
        switch result.status {
        case 0: return try line(result.output)
        // An unborn branch, such as a `git worktree add --orphan` checkout, has no commit.
        // Git lists it with the all-zero object ID.
        case 1: return String(repeating: "0", count: listed.count)
        default: throw GitServiceError.git(result.message)
        }
    }

    private static func readStatus(_ path: String) throws -> GitStatus {
        // Status is observational: don't refresh the index as a side effect, or
        // contend with an editor's Git operation while inspecting worktrees.
        let data = try git(["--no-optional-locks", "-C", path, "status", "--porcelain=v1", "-z", "--untracked-files=all"])
        let entries = data.split(separator: 0)
        var index = 0
        var staged = 0, modified = 0, untracked = 0, conflicted = 0
        let conflicts: Set<String> = ["DD", "AU", "UD", "UA", "DU", "AA", "UU"]
        while index < entries.count {
            let bytes = Array(entries[index])
            guard bytes.count >= 3, bytes[2] == 32 else { throw GitServiceError.invalidOutput }
            let x = bytes[0], y = bytes[1]
            let code = String(bytes: bytes.prefix(2), encoding: .ascii) ?? ""
            if code == "??" { untracked += 1 }
            else if conflicts.contains(code) { conflicted += 1 }
            else {
                if x != 32 && x != 63 && x != 33 { staged += 1 }
                if y != 32 && y != 63 && y != 33 { modified += 1 }
            }
            if x == 82 || x == 67 || y == 82 || y == 67 {
                index += 1 // NUL-form rename/copy source path is not a status entry.
                guard index < entries.count else { throw GitServiceError.invalidOutput }
            }
            index += 1
        }
        return GitStatus(staged: staged, modified: modified, untracked: untracked, conflicted: conflicted)
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func line(_ data: Data) throws -> String {
        guard var string = String(data: data, encoding: .utf8) else { throw GitServiceError.invalidOutput }
        // Remove exactly Git's delimiter, not whitespace that belongs to a path.
        if string.hasSuffix("\n") { string.removeLast() }
        return string
    }

    func background<T: Sendable>(
        priority: BlockingIOExecutor.Priority = .normal,
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await BlockingIOExecutor.shared.run(priority: priority) { cancellation in
            try cancellation.check()
            return try operation()
        }
    }

    /// Directories GUI apps don't have on PATH but where Git's filter and hook helpers
    /// (git-lfs, git-crypt, ...) usually live. Appended so system tools keep precedence.
    private static let supplementalPath = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// Git directory names that say nothing about the project they belong to.
    private static let anonymousGitDirectoryNames: Set<String> = [".git", ".bare"]

    static func environment(from base: [String: String]) -> [String: String] {
        var environment = base
        // Do not let an inherited shell's repository override explicit selections.
        for key in environment.keys where key.hasPrefix("GIT_") { environment.removeValue(forKey: key) }
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["LC_ALL"] = "C"
        // A Finder or Dock launch inherits launchd's minimal PATH, so a repository's
        // `filter.lfs.*` commands would otherwise fail to start.
        var path = (base["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        for directory in supplementalPath where !path.contains(directory) { path.append(directory) }
        environment["PATH"] = path.joined(separator: ":")
        return environment
    }

    struct GitOutput {
        let status: Int32
        let output: Data
        let message: String
    }

    static func git(_ arguments: [String], interruptible: Bool = true) throws -> Data {
        let result = try run(arguments, interruptible: interruptible)
        guard result.status == 0 else { throw GitServiceError.git(result.message) }
        return result.output
    }

    /// Reports Git's exit status instead of throwing for commands whose failure is an answer.
    /// An interruptible command is terminated when its job is canceled, so a hung child
    /// can't pin a worker. Destructive commands pass `false` and always run to completion.
    static func run(_ arguments: [String], interruptible: Bool = true) throws -> GitOutput {
        try BlockingIOExecutor.checkCancellation()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.environment = environment(from: ProcessInfo.processInfo.environment)
        let output = Pipe()
        let errors = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: errors.path, contents: nil) else {
            throw GitServiceError.git("Could not create Git error capture.")
        }
        defer { try? FileManager.default.removeItem(at: errors) }
        let errorHandle = try FileHandle(forWritingTo: errors)
        defer { try? errorHandle.close() }
        process.standardOutput = output
        process.standardError = errorHandle
        process.standardInput = FileHandle.nullDevice
        try BlockingIOExecutor.checkCancellation()
        try process.run()
        let child = ChildProcess(process)
        let stopWatching = interruptible
            ? BlockingIOExecutor.currentCancellation?.onCancel { child.terminate() } : nil
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        stopWatching?()
        if child.wasTerminated, process.terminationStatus != 0 { throw CancellationError() }
        let message = process.terminationStatus == 0
            ? "" : ((try? String(contentsOf: errors, encoding: .utf8)) ?? "Git failed.")
        return GitOutput(
            status: process.terminationStatus, output: data,
            message: message.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Cancellation arrives on an arbitrary thread while the worker blocks reading the child's output.
    private final class ChildProcess: @unchecked Sendable {
        private let process: Process
        private let terminated = Mutex(false)

        init(_ process: Process) { self.process = process }

        var wasTerminated: Bool { terminated.withLock { $0 } }

        func terminate() {
            guard process.isRunning else { return }
            terminated.withLock { $0 = true }
            process.terminate()
        }
    }
}
