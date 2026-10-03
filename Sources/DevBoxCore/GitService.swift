import Foundation

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
        nestedWorktreePaths: [String] = []
    ) {
        self.path = path
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
        case .dirtyWorktree: return "The worktree contains uncommitted changes."
        }
    }
}

/// Git is always invoked directly, never through a shell. Public async operations
/// run on bounded I/O workers so waits don't block UI or Swift's cooperative pool.
public struct GitService: Sendable {
    public init() {}

    public func discoverProject(at path: String) async throws -> ProjectRecord {
        try await background {
            let anchor = Self.canonical(path)
            let common = try Self.line(Self.git(["-C", anchor, "rev-parse", "--path-format=absolute", "--git-common-dir"]))
            let id = Self.canonical(common)
            let bare = try Self.line(Self.git(["-C", anchor, "rev-parse", "--is-bare-repository"])) == "true"
            let root = bare ? anchor : try Self.line(Self.git(["-C", anchor, "rev-parse", "--show-toplevel"]))
            let nameURL = URL(fileURLWithPath: id)
            let name = nameURL.lastPathComponent == ".git"
                ? nameURL.deletingLastPathComponent().lastPathComponent : nameURL.lastPathComponent
            return ProjectRecord(id: id, name: name, path: Self.canonical(root))
        }
    }

    public func listWorktrees(project: ProjectRecord) async throws -> [WorktreeRecord] {
        try await background { try Self.worktrees(project) }
    }

    public func status(worktree: WorktreeRecord) async throws -> GitStatus {
        try await background {
            guard !worktree.isBare, worktree.exists else {
                throw GitServiceError.git("Status is unavailable for a bare or missing worktree.")
            }
            return try Self.readStatus(worktree.path)
        }
    }

    public func diskUsage(worktree: WorktreeRecord) async throws -> DiskUsage {
        try await background {
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
        try await background {
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
            let head = try Self.line(Self.git(["-C", current.path, "rev-parse", "HEAD"]))
            let branchRef = try Self.line(Self.git(["-C", current.path, "rev-parse", "--abbrev-ref", "HEAD"]))
            guard Self.canonical(common) == Self.canonical(project.id),
                  Self.canonical(root) == Self.canonical(current.path),
                  head == current.head, (branchRef == "HEAD" ? nil : branchRef) == current.branch else {
                throw GitServiceError.changedWorktree
            }
            let status = try Self.readStatus(current.path)
            guard allowDirty || status.isClean else { throw GitServiceError.dirtyWorktree }
            var args = ["--git-dir", project.id, "worktree", "remove"]
            if allowDirty { args.append("--force") }
            args += ["--", current.path]
            _ = try Self.git(args)
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
            guard let path = fields["worktree"] else { throw GitServiceError.invalidOutput }
            let ref = fields["branch"]
            let branch = ref.map { $0.hasPrefix("refs/heads/") ? String($0.dropFirst(11)) : $0 }
            var directory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
            result.append(WorktreeRecord(
                path: path, branch: branch, head: fields["HEAD"] ?? "",
                isMain: result.isEmpty, isBare: fields["bare"] != nil,
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
                nestedWorktreePaths: nested
            )
        }
    }

    private static func readStatus(_ path: String) throws -> GitStatus {
        let data = try git(["-C", path, "status", "--porcelain=v1", "-z", "--untracked-files=all"])
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

    func background<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await BlockingIOExecutor.shared.run { cancellation in
            try cancellation.check()
            return try operation()
        }
    }

    static func git(_ arguments: [String]) throws -> Data {
        try BlockingIOExecutor.checkCancellation()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        // Do not let an inherited shell's repository override explicit selections.
        for key in environment.keys where key.hasPrefix("GIT_") { environment.removeValue(forKey: key) }
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["LC_ALL"] = "C"
        process.environment = environment
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
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = (try? String(contentsOf: errors, encoding: .utf8)) ?? "Git failed."
            throw GitServiceError.git(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return data
    }
}
