import Foundation

/// An opt-in core-I/O benchmark, not a UI or cold-disk performance claim.
@main
struct WorktreeRefreshBenchmark {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    struct Sample {
        let total: Double
        let firstRow: Double
    }

    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 5, let count = Int(args[2]), (2...64).contains(count),
              let files = Int(args[3]), files > 0, let runs = Int(args[4]), runs > 0 else {
            throw Failure(description: "Usage: benchmark <empty fixture directory> <2...64 worktrees> <files per worktree> <runs>")
        }
        let root = URL(fileURLWithPath: args[1], isDirectory: true)
        let service = GitService()
        let project = try await service.background {
            let manager = FileManager.default
            guard try manager.contentsOfDirectory(atPath: root.path).isEmpty else {
                throw Failure(description: "Refusing to modify a nonempty fixture directory.")
            }
            let templates = root.appendingPathComponent("templates", isDirectory: true)
            try manager.createDirectory(at: templates, withIntermediateDirectories: false)
            let main = root.appendingPathComponent("main", isDirectory: true)
            _ = try GitService.git(["-c", "init.templateDir=\(templates.path)", "init", "--quiet", "--initial-branch=main", main.path])
            for (key, value) in [
                ("user.name", "DevBox Benchmark"), ("user.email", "benchmark@example.invalid"),
                ("commit.gpgsign", "false"), ("core.hooksPath", templates.path),
                ("core.fsmonitor", "false"), ("core.untrackedCache", "false")
            ] {
                _ = try GitService.git(["-C", main.path, "config", key, value])
            }
            try Data("base\n".utf8).write(to: main.appendingPathComponent("tracked.txt"))
            _ = try GitService.git(["-C", main.path, "add", "tracked.txt"])
            _ = try GitService.git(["-C", main.path, "commit", "--quiet", "-m", "Synthetic fixture"])
            var worktrees = [main]
            for index in 1..<count {
                let path = root.appendingPathComponent("worktree-\(index)", isDirectory: true)
                _ = try GitService.git(["-C", main.path, "worktree", "add", "--quiet", "--detach", path.path, "HEAD"])
                worktrees.append(path)
            }
            for worktree in worktrees {
                try Data("modified\n".utf8).write(to: worktree.appendingPathComponent("tracked.txt"))
                try Data("staged\n".utf8).write(to: worktree.appendingPathComponent("staged.txt"))
                _ = try GitService.git(["-C", worktree.path, "add", "staged.txt"])
                for index in 0..<files {
                    let directory = worktree.appendingPathComponent("group-\(index / 100)", isDirectory: true)
                    if index % 100 == 0 {
                        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
                    }
                    try Data(repeating: UInt8(index % 251), count: 256)
                        .write(to: directory.appendingPathComponent("file-\(index).dat"))
                }
            }
            return ProjectRecord(id: main.appendingPathComponent(".git").path, name: "Fixture", path: main.path)
        }
        let records = try await service.listWorktrees(project: project)
        guard records.count == count else { throw Failure(description: "Fixture worktree count mismatch.") }
        print("Synthetic warm-cache Git status: \(count) worktrees, \(files) untracked files each, \(runs) runs per mode.")
        print("One untimed warm-up per mode; measured order alternates. Every status must report 1 staged, 1 modified, \(files) untracked, 0 conflicts.")
        print("Uses production GitService with optional index writes disabled; no network, UI, or background size scans.")
        for limit in [1, 2] { _ = try await measure(records, files: files, limit: limit) }
        var samples: [Int: [Sample]] = [1: [], 2: []]
        for run in 0..<runs {
            for limit in run % 2 == 0 ? [1, 2] : [2, 1] {
                let sample = try await measure(records, files: files, limit: limit)
                samples[limit, default: []].append(sample)
                print(String(format: "run %d concurrency %d: total %.6f s, first row %.6f s",
                             run + 1, limit, sample.total, sample.firstRow))
            }
        }
        for limit in [1, 2] {
            let values = samples[limit, default: []]
            print(String(format: "concurrency %d: median total %.6f s, median first row %.6f s",
                         limit, median(values.map(\.total)), median(values.map(\.firstRow))))
        }
        print(String(format: "Measured total-time ratio (sequential / parallel): %.2fx",
                     median(samples[1, default: []].map(\.total)) / median(samples[2, default: []].map(\.total))))
        print("Filesystem/cache/hardware and real repository contents vary. This isolates status concurrency, not end-to-end UI performance.")
    }

    static func measure(_ records: [WorktreeRecord], files: Int, limit: Int) async throws -> Sample {
        let service = GitService()
        let start = DispatchTime.now().uptimeNanoseconds
        func elapsed() -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000 }
        return try await withThrowingTaskGroup(of: GitStatus.self) { group in
            var iterator = records.makeIterator()
            var completed = 0
            var firstRow: Double?
            func enqueue(_ record: WorktreeRecord) {
                group.addTask { try await service.status(worktree: record) }
            }
            for _ in 0..<limit {
                if let record = iterator.next() { enqueue(record) }
            }
            for try await status in group {
                if firstRow == nil { firstRow = elapsed() }
                guard status.staged == 1, status.modified == 1, status.untracked == files, status.conflicted == 0 else {
                    throw Failure(description: "Status mismatch; refusing to report timings for incorrect results.")
                }
                completed += 1
                if let record = iterator.next() { enqueue(record) }
            }
            guard completed == records.count, let firstRow else {
                throw Failure(description: "Incomplete status batch.")
            }
            return Sample(total: elapsed(), firstRow: firstRow)
        }
    }

    static func median(_ values: [Double]) -> Double {
        let ordered = values.sorted()
        let middle = ordered.count / 2
        return ordered.count % 2 == 0 ? (ordered[middle - 1] + ordered[middle]) / 2 : ordered[middle]
    }
}
