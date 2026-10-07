import Foundation

public enum BranchManagementError: Error, LocalizedError, Sendable {
    case deletionOutcomeUnknown(String)

    public var errorDescription: String? {
        switch self {
        case .deletionOutcomeUnknown(let detail):
            return "Remote deletion outcome is unknown. Use Fetch & Prune before retrying. \(detail)"
        }
    }
}

public struct ManagedBranch: Identifiable, Equatable, Sendable {
    public let reference: String
    public var id: String { reference }
    public let name: String
    public let commit: String
    public let committerName: String
    public let committerEmail: String
    /// The tip commit's committer date, not evidence of recent branch usage.
    public let committedAt: Date?
    public let remoteName: String?
    public let remoteBranchName: String?
    public let remoteURL: String?
    public let githubURL: URL?
    public let protectedReason: String?
    public var isRemote: Bool { reference.hasPrefix("refs/remotes/") }
    // Not persisted: deletion requires a fresh, service-produced snapshot.
    fileprivate var configurationSnapshot: String?

    public init(reference: String, name: String, commit: String, committerName: String,
                committerEmail: String, committedAt: Date? = nil, remoteName: String? = nil,
                remoteBranchName: String? = nil, remoteURL: String? = nil,
                githubURL: URL? = nil, protectedReason: String? = nil) {
        self.reference = reference
        self.name = name
        self.commit = commit
        self.committerName = committerName
        self.committerEmail = committerEmail
        self.committedAt = committedAt
        self.remoteName = remoteName
        self.remoteBranchName = remoteBranchName
        self.remoteURL = remoteURL
        self.githubURL = githubURL
        self.protectedReason = protectedReason
    }
}

/// Inspection is local-only. All subprocess work uses the shared bounded executor.
public struct BranchManagementService: Sendable {
    public init() {}

    public func list(project: ProjectRecord) async throws -> [ManagedBranch] {
        try await GitService().background(priority: .interactive) { try Self.snapshot(project) }
    }

    public func fetch(project: ProjectRecord) async throws {
        try await GitService().background {
            let directory = try Self.repositoryDirectory(project)
            _ = try Self.git(project, ["fetch", "--all", "--prune"], directory: directory)
            // Fetch does not reliably update an existing remote HEAD when the
            // server changes its default branch. Refresh it explicitly as part
            // of this user-requested network operation.
            let remotes = try Self.git(project, ["remote"]).split(separator: "\n").map(String.init)
            var failures: [String] = []
            for remote in remotes {
                do {
                    _ = try Self.git(project, ["remote", "set-head", "--auto", "--", remote], directory: directory)
                } catch {
                    try BlockingIOExecutor.checkCancellation()
                    // Do not let a subsequent local Refresh revive stale default
                    // protection after the server's HEAD could not be verified.
                    _ = try Self.git(project, ["remote", "set-head", "--delete", "--", remote], directory: directory)
                    failures.append("\(remote): \(error.localizedDescription)")
                }
            }
            if !failures.isEmpty {
                throw GitServiceError.git("Branches were fetched, but remote defaults could not be verified. Remote deletion is disabled for these remotes.\n" + failures.joined(separator: "\n"))
            }
        }
    }

    public func delete(branch: ManagedBranch, project: ProjectRecord, force: Bool) async throws {
        try await GitService().background {
            let current = try Self.snapshot(project).first { $0.reference == branch.reference }
            guard let current, branch.configurationSnapshot != nil,
                  current.configurationSnapshot == branch.configurationSnapshot,
                  current.commit == branch.commit, current.remoteName == branch.remoteName,
                  current.remoteBranchName == branch.remoteBranchName, current.remoteURL == branch.remoteURL else {
                throw GitServiceError.git("The branch or repository configuration changed. Refresh before deleting.")
            }
            if let reason = current.protectedReason { throw GitServiceError.git(reason) }
            if current.isRemote {
                guard let endpoint = current.remoteURL, let name = current.remoteBranchName else {
                    throw GitServiceError.git("Cannot safely identify the remote branch.")
                }
                let directory = try Self.repositoryDirectory(project)
                let ref = "refs/heads/" + name
                // Push to the captured, validated endpoint, not a mutable remote alias.
                // An explicit lease protects against unseen server changes, even with force.
                do {
                    _ = try Self.git(project, ["-c", "push.followTags=false", "push",
                        "--porcelain", "--no-verify", "--recurse-submodules=no",
                        "--force-with-lease=\(ref):\(current.commit)", "--", endpoint, ":" + ref],
                        directory: directory, interruptible: false)
                } catch {
                    // The subprocess helper does not expose a structured push result.
                    // Even cancellation can arrive after the server accepted deletion.
                    throw BranchManagementError.deletionOutcomeUnknown(error.localizedDescription)
                }
                // Pushing a pinned absolute endpoint may not update Git's tracking
                // ref automatically. Remove only the captured value; a concurrent
                // fetch/ref change must survive. The server operation is already
                // confirmed, so a local cleanup failure is not an uncertain push.
                _ = try? Self.git(project, ["update-ref", "--no-deref", "-d", current.reference, current.commit], interruptible: false)
            } else {
                _ = try Self.git(project, ["branch", force ? "-D" : "-d", "--", current.name], interruptible: false)
            }
        }
    }

    private static func git(
        _ project: ProjectRecord, _ args: [String], directory: String? = nil, interruptible: Bool = true
    ) throws -> String {
        let location = directory.map { ["-C", $0] } ?? []
        let data = try GitService.git(location + ["--git-dir", project.id] + args, interruptible: interruptible)
        guard let text = String(data: data, encoding: .utf8) else { throw GitServiceError.invalidOutput }
        return text
    }

    private static func repositoryDirectory(_ project: ProjectRecord) throws -> String {
        try repositoryDirectory(worktrees: git(project, ["worktree", "list", "--porcelain", "-z"]))
    }

    private static func repositoryDirectory(worktrees: String) throws -> String {
        guard let first = worktrees.split(separator: "\0").first, first.hasPrefix("worktree ") else {
            throw GitServiceError.invalidOutput
        }
        return String(first.dropFirst("worktree ".count))
    }

    /// Git interprets relative filesystem remotes against the process directory.
    /// Pin them to the primary checkout (or bare repository), never DevBox's CWD
    /// or a linked discovery checkout that may subsequently be removed.
    private static func resolvedEndpoint(_ endpoint: String, directory: String) -> String {
        if let colon = endpoint.firstIndex(of: ":"),
           endpoint.firstIndex(of: "/").map({ colon < $0 }) ?? true {
            return endpoint
        }
        let path = endpoint.hasPrefix("/") ? endpoint : directory + "/" + endpoint
        return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private struct Ref {
        let reference: String
        let commit: String
        let name: String
        let email: String
        let date: Date?
        let symbolic: String
        let upstream: String
    }

    private struct Mapping {
        let remote: String
        let branch: String
        let endpoint: String?
        let hazard: String?
    }

    private static func snapshot(_ project: ProjectRecord) throws -> [ManagedBranch] {
        let configuration = try git(project, ["config", "--null", "--list"])
        var config: [String: [String]] = [:]
        for entry in configuration.split(separator: "\0") {
            let parts = entry.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            config[String(parts[0]), default: []].append(parts.count == 2 ? String(parts[1]) : "")
        }
        let output = try git(project, ["for-each-ref",
            "--format=%(refname)%00%(objectname)%00%(committername)%00%(committeremail:trim)%00%(committerdate:unix)%00%(symref)%00%(upstream)%00",
            "refs/heads/", "refs/remotes/"])
        // NUL-delimited fields, including names/emails. Only the record terminator
        // supplied by for-each-ref is a newline; never split identity fields on it.
        let fields = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var refs: [Ref] = []
        var index = 0
        while index + 7 < fields.count {
            let ref = fields[index].hasPrefix("\n") ? String(fields[index].dropFirst()) : fields[index]
            refs.append(Ref(reference: ref, commit: fields[index + 1], name: fields[index + 2],
                            email: fields[index + 3], date: TimeInterval(fields[index + 4]).map(Date.init(timeIntervalSince1970:)),
                            symbolic: fields[index + 5], upstream: fields[index + 6]))
            index += 7
        }
        let worktrees = try git(project, ["worktree", "list", "--porcelain", "-z"])
        let directory = try repositoryDirectory(worktrees: worktrees)
        let checkedOut = Set(worktrees.split(separator: "\0").compactMap { field -> String? in
            field.hasPrefix("branch ") ? String(field.dropFirst(7)) : nil
        })
        let remotes = Set(config.keys.compactMap { key -> String? in
            guard key.hasPrefix("remote."), key.hasSuffix(".url") else { return nil }
            return String(key.dropFirst(7).dropLast(4))
        })
        let rewrites = config.keys.contains { $0.hasPrefix("url.") }

        func mapping(_ reference: String) -> Mapping? {
            var matches: [(String, String)] = []
            for remote in remotes {
                let specs = config["remote.\(remote).fetch"] ?? []
                // Negative and non-head refspecs need richer exclusion/alias semantics.
                // Fail closed across remotes: an unsupported destination could
                // overlap a supported remote's tracking namespace.
                guard !specs.isEmpty, specs.allSatisfy({
                    let spec = $0.hasPrefix("+") ? String($0.dropFirst()) : $0
                    let pair = spec.components(separatedBy: ":")
                    guard pair.count == 2, pair[0].hasPrefix("refs/heads/"),
                          pair[1].hasPrefix("refs/remotes/") else { return false }
                    let sourceStars = pair[0].filter { $0 == "*" }.count
                    let destinationStars = pair[1].filter { $0 == "*" }.count
                    return sourceStars <= 1 && sourceStars == destinationStars
                }) else { return nil }
                for raw in specs {
                    let spec = raw.hasPrefix("+") ? String(raw.dropFirst()) : raw
                    let pair = spec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
                    guard pair.count == 2, let source = invert(reference, source: pair[0], destination: pair[1]) else { continue }
                    matches.append((remote, String(source.dropFirst("refs/heads/".count))))
                }
            }
            guard matches.count == 1, let (remote, branch) = matches.first else { return nil }
            let urls = config["remote.\(remote).url"] ?? []
            let pushes = config["remote.\(remote).pushurl"] ?? urls
            let endpoint = urls.count == 1 ? urls[0] : nil
            let hazard: String?
            if rewrites || endpoint == nil || pushes != urls || pushes.count != 1
                || endpoint.map({ remotes.contains($0) || $0.isEmpty || $0.contains("::") }) == true {
                hazard = "Remote endpoints are ambiguous, rewritten, or differ for fetch and push."
            } else if config["remote.\(remote).mirror"]?.contains("true") == true {
                hazard = "Mirror remotes cannot be safely managed here."
            } else {
                hazard = nil
            }
            return Mapping(remote: remote, branch: branch,
                           endpoint: endpoint.map { resolvedEndpoint($0, directory: directory) }, hazard: hazard)
        }
        let refsByName = Dictionary(uniqueKeysWithValues: refs.map { ($0.reference, $0) })
        var defaults: [String: Mapping] = [:]
        for remote in remotes {
            if let symbolic = refsByName["refs/remotes/\(remote)/HEAD"]?.symbolic,
               let mapped = mapping(symbolic), mapped.remote == remote {
                defaults[remote] = mapped
            }
        }
        var result: [ManagedBranch] = []
        for ref in refs where ref.symbolic.isEmpty {
            let remote = ref.reference.hasPrefix("refs/remotes/")
            let mapped = remote ? mapping(ref.reference) : nil
            let name = remote ? (mapped?.branch ?? String(ref.reference.dropFirst("refs/remotes/".count)))
                : String(ref.reference.dropFirst("refs/heads/".count))
            let upstream = refsByName[ref.upstream].flatMap { $0.symbolic.isEmpty ? $0 : nil }
            let upstreamMapping = upstream.flatMap { mapping($0.reference) }
            var reason: String?
            if checkedOut.contains(ref.reference) { reason = "Checked out in a worktree." }
            else if name == "main" || name == "master" { reason = "Main and master branches are protected." }
            else if project.mergeTarget == ref.reference { reason = "Selected merge target." }
            else if !remote, let upstreamMapping,
                    defaults[upstreamMapping.remote]?.branch == upstreamMapping.branch {
                reason = "Tracks the remote default branch."
            }
            else if remote {
                if let mapped {
                    if let hazard = mapped.hazard { reason = hazard }
                    else if defaults[mapped.remote] == nil {
                        reason = "Remote default branch is unknown. Use Fetch & Prune before deleting."
                    } else if defaults[mapped.remote]?.branch == mapped.branch { reason = "Remote default branch." }
                } else { reason = "Remote fetch mapping is unsupported or ambiguous." }
            }
            let linkMapping = remote ? mapped : upstreamMapping
            let link = linkMapping.flatMap { item in item.endpoint.flatMap { githubURL(endpoint: $0, branch: item.branch) } }
            var branch = ManagedBranch(reference: ref.reference, name: name, commit: ref.commit,
                committerName: ref.name, committerEmail: ref.email, committedAt: ref.date,
                remoteName: mapped?.remote, remoteBranchName: mapped?.branch, remoteURL: mapped?.endpoint,
                githubURL: link, protectedReason: reason)
            // Deleting a local branch removes its branch.* configuration. That
            // must not invalidate the other branches in the same confirmed batch.
            // Retain all repository/remote settings and this local branch's settings.
            branch.configurationSnapshot = configuration.split(separator: "\0").filter { entry in
                !entry.hasPrefix("branch.") || (!remote && entry.hasPrefix("branch.\(name)."))
            }.joined(separator: "\0")
            result.append(branch)
        }
        return result.sorted { $0.reference < $1.reference }
    }

    /// Invert only an exact refspec or a single wildcard on each side.
    private static func invert(_ ref: String, source: String, destination: String) -> String? {
        let src = source.components(separatedBy: "*")
        let dst = destination.components(separatedBy: "*")
        if src.count == 1 && dst.count == 1 { return ref == destination ? source : nil }
        guard src.count == 2, dst.count == 2, ref.hasPrefix(dst[0]), ref.hasSuffix(dst[1]),
              ref.count >= dst[0].count + dst[1].count else { return nil }
        return src[0] + ref.dropFirst(dst[0].count).dropLast(dst[1].count) + src[1]
    }

    private static func githubURL(endpoint: String, branch: String) -> URL? {
        let path: String
        if endpoint.hasPrefix("git@github.com:") {
            path = String(endpoint.dropFirst("git@github.com:".count))
        } else if let url = URLComponents(string: endpoint),
                  url.host?.lowercased() == "github.com",
                  ["https", "ssh"].contains(url.scheme ?? ""), url.port == nil {
            path = String(url.path.drop(while: { $0 == "/" }))
        } else { return nil }
        let repository = path.hasSuffix(".git") ? String(path.dropLast(4)) : path
        let pieces = repository.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 2, pieces.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let encoded = branch.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://github.com/\(repository)/tree/\(encoded)")
    }
}
