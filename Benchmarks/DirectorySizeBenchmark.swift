import Foundation

/// Standalone, optimized benchmark, deliberately outside the SwiftPM test targets.
@main
struct DirectorySizeBenchmark {
    struct BenchmarkError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 4, let files = Int(args[2]), files > 0,
              let runs = Int(args[3]), runs > 0 else {
            throw BenchmarkError("Usage: benchmark <fresh Git fixture> <positive file count> <positive runs>")
        }
        let root = URL(fileURLWithPath: args[1], isDirectory: true)
        let manager = FileManager.default
        // 100 small files per directory, with varying lengths; setup is not timed.
        for index in 0..<files {
            let directory = root.appendingPathComponent("group-\(index / 100)", isDirectory: true)
            if index % 100 == 0 {
                try manager.createDirectory(at: directory, withIntermediateDirectories: false)
            }
            try Data(repeating: UInt8(index % 251), count: 128 + index % 2048)
                .write(to: directory.appendingPathComponent("file-\(index).dat"))
        }
        let worktree = WorktreeRecord(path: root.path, branch: nil, head: "", isMain: true)
        let service = GitService()
        let expected = try foundationReference(root)
        try verify(expected, files: files, expected: expected)
        try verify(try await service.diskUsage(worktree: worktree), files: files, expected: expected)
        print("Synthetic warm-cache benchmark: \(files) small files, \(runs) measured runs per mode.")
        print("One untimed warm-up per mode; sequential, alternating order; no concurrency benchmark.")
        print("nativeFTS includes the production GitService call and Git metadata lookup.")
        print("Equal results required: \(expected.fileCount) files, \(expected.bytes) allocated bytes, no unreadable entries.")

        var foundationTimes: [Double] = []
        var nativeTimes: [Double] = []
        for run in 0..<runs {
            for native in (run % 2 == 0 ? [false, true] : [true, false]) {
                let start = DispatchTime.now().uptimeNanoseconds
                let usage: DiskUsage
                if native {
                    usage = try await service.diskUsage(worktree: worktree)
                } else {
                    usage = try foundationReference(root)
                }
                let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
                try verify(usage, files: files, expected: expected)
                if native { nativeTimes.append(seconds) } else { foundationTimes.append(seconds) }
                print(String(format: "run %d %@: %.6f s", run + 1, native ? "nativeFTS" : "Foundation", seconds))
            }
        }
        report("Foundation", foundationTimes)
        report("nativeFTS", nativeTimes)
        print("Synthetic warm-cache wall times only; filesystem, cache, and real repository contents vary. No universal speedup is implied.")
    }

    static func verify(_ usage: DiskUsage, files: Int, expected: DiskUsage) throws {
        guard usage.fileCount == files, usage.fileCount == expected.fileCount,
              usage.bytes == expected.bytes, usage.unreadableCount == 0 else {
            throw BenchmarkError("Count/bytes mismatch or incomplete scan: \(usage)")
        }
    }

    static func report(_ label: String, _ values: [Double]) {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        let median = sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        print(String(format: "%@: median %.6f s, range %.6f...%.6f s", label, median, sorted[0], sorted[sorted.count - 1]))
    }

    /// Prior Foundation loop: prefetch allocation/type keys and normalize each entry
    /// to test against the root .git path. Keep this baseline separate from production.
    static func foundationReference(_ root: URL) throws -> DiskUsage {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey, .fileAllocatedSizeKey
        ]
        var unreadable = 0
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: Array(keys), options: [],
            errorHandler: { _, _ in unreadable += 1; return true }
        ) else {
            return DiskUsage(bytes: 0, fileCount: 0, unreadableCount: 1)
        }
        let gitPath = root.appendingPathComponent(".git").standardizedFileURL.path
        var bytes: Int64 = 0
        var files = 0
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            do {
                let values = try url.resourceValues(forKeys: keys)
                if values.isSymbolicLink == true { continue }
                if url.lastPathComponent == ".git" || url.standardizedFileURL.path == gitPath {
                    if values.isDirectory == true { enumerator.skipDescendants() }
                    continue
                }
                guard values.isRegularFile == true else { continue }
                files += 1
                if let allocation = values.totalFileAllocatedSize ?? values.fileAllocatedSize {
                    bytes += Int64(allocation)
                } else {
                    unreadable += 1
                }
            } catch {
                unreadable += 1
            }
        }
        return DiskUsage(bytes: bytes, fileCount: files, unreadableCount: unreadable)
    }
}
