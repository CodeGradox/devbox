import Darwin
import Foundation

/// Counts regular directory entries and their allocated blocks in one physical walk.
/// Call from a background task: FTS is synchronous, but cancellation is checked
/// between entries. Apple's FTS implementation batches metadata reads on macOS.
enum FTSDiskScanner {
    private struct DirectoryIdentity: Hashable {
        let device: dev_t
        let inode: ino_t

        init(_ info: stat) {
            device = info.st_dev
            inode = info.st_ino
        }
    }

    static func scan(
        rootPath: String,
        excludedDirectoryPath: String? = nil,
        excludedDirectoryPaths: [String] = [],
        excludeGitEntries: Bool = true,
        entryObserver: ((Int) -> Void)? = nil
    ) throws -> DiskUsage {
        let checkCancellation = BlockingIOExecutor.cancellationCheck()
        try checkCancellation()
        guard !rootPath.isEmpty, !rootPath.utf8.contains(0),
              excludedDirectoryPath?.utf8.contains(0) != true,
              !excludedDirectoryPaths.contains(where: { $0.utf8.contains(0) }) else {
            throw POSIXError(.EINVAL)
        }

        // A trailing slash makes lstat resolve a final symlink as a directory.
        // Strip separators once, before validation, without resolving that link.
        var scanPath = rootPath
        while scanPath != "/" && scanPath.hasSuffix("/") { scanPath.removeLast() }
        var rootInfo = stat()
        guard lstat(scanPath, &rootInfo) == 0,
              rootInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              rootInfo.st_flags & UInt32(SF_DATALESS) == 0 else {
            // Do not follow a symlink root or materialize an offline directory.
            return DiskUsage(bytes: 0, fileCount: 0, unreadableCount: 1)
        }

        // Compare directory identity, not a normalized path for every file. This
        // also handles aliases such as /var vs /private/var and custom Git storage.
        var exclusions: Set<DirectoryIdentity> = []
        if let excludedDirectoryPath {
            var info = stat()
            guard stat(excludedDirectoryPath, &info) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            exclusions.insert(DirectoryIdentity(info))
        }
        for path in excludedDirectoryPaths {
            try checkCancellation()
            var info = stat()
            if stat(path, &info) == 0 {
                if info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                    exclusions.insert(DirectoryIdentity(info))
                }
            } else if errno != ENOENT && errno != ENOTDIR {
                // Fail rather than accidentally including a boundary we cannot inspect.
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }

        guard let root = strdup(scanPath) else { throw POSIXError(.ENOMEM) }
        defer { free(root) }
        var paths: [UnsafeMutablePointer<CChar>?] = [root, nil]
        let options = FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV
        guard let tree = paths.withUnsafeMutableBufferPointer({
            fts_open($0.baseAddress!, options, nil)
        }) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { fts_close(tree) }

        var bytes: Int64 = 0
        var files = 0
        var unreadable = 0
        var visited = 0
        while true {
            try checkCancellation()
            // FTS signals both EOF and failure with nil; errno distinguishes them.
            errno = 0
            guard let entry = fts_read(tree) else {
                if errno != 0 { unreadable += 1 }
                break
            }
            let kind = Int32(entry.pointee.fts_info)
            visited += 1
            entryObserver?(visited) // Lets tests act while the walk is in progress.
            // Only the checkout's own metadata is shared storage. A `.git` deeper down belongs
            // to an independent clone or submodule that disappears with the checkout.
            if excludeGitEntries && entry.pointee.fts_level == 1 && isGitEntry(entry) {
                if kind == FTS_D { fts_set(tree, entry, FTS_SKIP) }
                continue
            }

            switch kind {
            case FTS_D:
                guard let info = entry.pointee.fts_statp else {
                    unreadable += 1
                    fts_set(tree, entry, FTS_SKIP)
                    continue
                }
                if exclusions.contains(DirectoryIdentity(info.pointee)) {
                    fts_set(tree, entry, FTS_SKIP)
                } else if info.pointee.st_flags & UInt32(SF_DATALESS) != 0 {
                    // Reading a cloud-placeholder directory may download its tree.
                    // Leave it unexpanded and report an incomplete measurement.
                    unreadable += 1
                    fts_set(tree, entry, FTS_SKIP)
                }
            case FTS_F:
                files += 1
                guard let info = entry.pointee.fts_statp, info.pointee.st_blocks >= 0 else {
                    unreadable += 1
                    continue
                }
                // st_blocks always uses 512-byte accounting units, not st_blksize.
                // Count hard-linked entries separately, preserving v0's semantics.
                let allocation = Int64(info.pointee.st_blocks).multipliedReportingOverflow(by: 512)
                let total = bytes.addingReportingOverflow(allocation.partialValue)
                guard !allocation.overflow, !total.overflow else {
                    throw POSIXError(.EOVERFLOW)
                }
                bytes = total.partialValue
            case FTS_DNR, FTS_ERR, FTS_NS, FTS_DC:
                unreadable += 1
            default:
                // Ignore postorder directory visits, symlinks (including broken
                // ones), and non-regular entries such as sockets and FIFOs.
                break
            }
        }
        try checkCancellation()
        return DiskUsage(bytes: bytes, fileCount: files, unreadableCount: unreadable)
    }

    private static func isGitEntry(_ entry: UnsafeMutablePointer<FTSENT>) -> Bool {
        guard entry.pointee.fts_namelen == 4 else { return false }
        // fts_name is a trailing variable-length C string. Access the original
        // storage rather than copying the imported one-character struct field.
        let offset = MemoryLayout<FTSENT>.offset(of: \.fts_name)!
        let name = UnsafeRawPointer(entry).advanced(by: offset).assumingMemoryBound(to: CChar.self)
        return name[0] == 46 && name[1] == 103 && name[2] == 105 && name[3] == 116
    }
}
