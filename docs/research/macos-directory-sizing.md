# Fast directory sizing on macOS from Swift

Research and local experiments, 2026-10-02. No application behavior was changed.

**Implementation update:** The app now uses the native FTS backend described below.
The tables remain the original research measurements, comparing the former
Foundation scanner with prototypes. The app now schedules up to four worktree scans
concurrently, independent of Git status, and supports per-worktree refresh.
Git status and measurements are now cached in memory per project until app exit.
Switching projects restores completed results; explicit refresh updates them.
Individual traversals remain serial; within-worktree parallelism and persistent
caching are still separate follow-up work. `make benchmark` now runs a repeatable
serial scanner comparison; it does not measure the app's concurrent queue.

The integrated production service was rechecked on a fresh Fixture-A-shaped tree
with five shuffled warm runs, using optimized builds: **0.120 s median** versus
**1.296 s** for the former Foundation loop. The FTS measurement includes Git
metadata discovery and the service's background-task hop. Both returned 50,000
files, 204,800,000 bytes, and zero unreadable entries.

## Recommendation

Use a small Swift wrapper around Darwin's `fts_open` / `fts_read` for the next
scanner implementation. Start with a serial walk and bounded concurrency across
worktrees. Consider a small shared directory-worker pool only after measuring the
real workloads.

**The important finding is that Apple's FTS implementation already uses
`getattrlistbulk` internally.** A custom bulk-attribute parser is not necessary to
get most of its benefit. In these experiments FTS was 5–13× faster than the current
scanner and only about 8–12% slower than a minimal direct bulk scanner.

This preserves both file count and allocated-byte totals in one pass. It requires
no installed utility, Rust dependency, or subprocess-output parsing.

## Evidence from source and documentation

### Foundation

Apple documents that `FileManager.enumerator(at:includingPropertiesForKeys:...)`
prefetches the requested properties and caches them in the returned `NSURL`
objects. The current code already uses that facility. It is incorrect to assume
that each `resourceValues` call must perform another `stat`.

However, the current hot loop also computes `standardizedFileURL.path` for almost
every entry to compare against the common Git directory. Removing that repeated
normalization in a prototype reduced runtime substantially. The prototype retains
`.git` exclusions but is not a complete replacement for the current exclusion
rules: a production version must still exclude a nonstandard common Git directory
located inside the tree.

Foundation documents that encountered symlinks and descendant mount points are
not traversed. An explicitly selected mounted root is traversed.

Source: [Apple's URL directory-enumerator documentation][foundation].

### Apple FTS, not generic assumptions about BSD FTS

[Apple's `du` source][du-source] uses `fts_open`, `FTS_PHYSICAL`, and `FTS_NOCHDIR`,
then aggregates `st_blocks` unless apparent size was requested.

[Apple's libc FTS source][fts-source], in `open_directory` and
`advance_directory`, allocates a 32 KiB attribute buffer and calls
`getattrlistbulk(..., FSOPT_PACK_INVAL_ATTRS)`. It requests allocation alongside
file metadata, constructs stat records from those attributes, and has a directory
enumeration fallback. Thus a generic statement that “FTS stats every file while
bulk enumeration avoids that” is not a sound description of modern macOS FTS.

The public FTS API can be called directly from Swift via `import Darwin`.
`FTS_NOCHDIR` matters in a GUI app: traversal must not change the process's working
directory. `FTS_PHYSICAL` selects non-following symlink behavior.

### Direct bulk enumeration

[`getattrlistbulk`][bulk-man] reads metadata for multiple children in one syscall.
It can return names, types, per-entry errors, and `ATTR_FILE_ALLOCSIZE` together.
`ATTR_FILE_ALLOCSIZE` describes physical allocation for all file forks, not only
the logical data length.

A correct implementation must parse returned-attribute bitmaps, record lengths,
relative name offsets, optional/inapplicable fields, and errors. Even when using
`FSOPT_PACK_INVAL_ATTRS`, invalid fields cannot be interpreted as valid zeroes.
It needs filesystem fallback behavior, safe child-directory opening, cancellation,
mount/firmlink policies, and partial-result reporting.

The [current dua-cli macOS implementation][dua-source] is an example of this design.
It uses a reusable 64 KiB buffer, optional extra clone metadata, and fallback logic.
That validates the approach, but not a particular speedup on this app's workloads.

### No supported instant recursive subtree total

`ATTR_DIR_ENTRYCOUNT` counts immediate directory entries; `ATTR_DIR_ALLOCSIZE`
describes the directory object itself. Neither is a recursive subtree summary.

Public XNU headers mention extended APFS directory statistics and expose a
recursive generation counter for directories already marked to maintain such
statistics. That is not a supported API for retrieving recursive bytes and file
counts for arbitrary user-selected directories.

Sources: [`getattrlist` attribute definitions][attr-man] and [XNU `attr.h`][attr-header].

## Local benchmark methodology

- Apple M1 Pro, 16 GiB RAM, internal APFS volume, macOS 26.6.2.
- Swift 6.4; benchmark executable compiled with `swiftc -O -swift-version 6`.
- All approaches ran serially unless a worker count is explicitly shown.
- Five runs per approach, shuffled ordering with a fixed random seed.
- Tables show median **whole-process wall time**, including startup.
- These are **warm/repeated scans**, not cold-cache benchmarks. Creating the
  fixtures itself warms metadata. No cache flushing or system changes were used.
- All benchmark files were disposable scratch data. No user repositories outside
  the attached DevBox worktree were scanned.
- Fixtures contain ordinary 1,024-byte files, allocated as 4,096 bytes each.
  Both contain 50,000 regular files and report 204,800,000 allocated bytes.
- Fixture A: `node_modules/package-N/lib-M/file-K`, 100 packages × 10 lib
  directories × 50 files; 1,102 directories including the scan root, excluding Git.
- Fixture B: `group-N/package-M/file-K`, 100 groups × 100 package directories
  × 5 files; 10,101 directories including the scan root, excluding Git.
- Each fixture is a Git repository so the real `GitService.diskUsage` can run.
  All scanners exclude `.git`. No mounts, cloud placeholders, or unreadable paths
  are present in these timing fixtures.

The Foundation variants are experimental baselines, not ready-to-ship replacements.
They use a per-iteration autorelease pool. The no-normalization variant retains the
current five resource keys; the smaller-key variant uses `fileResourceTypeKey` and
`totalFileAllocatedSizeKey`. The exact app scanner is measured separately.

## Results

| Approach | Fixture A median (range), seconds | Fixture B median (range), seconds |
|---|---:|---:|
| Current app scanner | 1.386 (1.373–1.456) | 1.823 (1.820–1.868) |
| Foundation, without per-entry path normalization | 0.459 (0.452–0.466) | 0.819 (0.806–0.859) |
| Swift calling Darwin FTS | 0.105 (0.103–0.105) | 0.347 (0.328–0.350) |
| Swift calling `getattrlistbulk` directly | 0.097 (0.092–0.112) | 0.310 (0.307–0.321) |
| `/usr/bin/du -sk -I .git` | 0.106 (0.106–0.110) | 0.390 (0.374–0.410) |

Foundation with only resource type and total allocated size took 0.424 s on A.
The original Foundation-style loop with a pool, still doing normalization, took
1.344 s. Thus a pool alone did not account for the large improvement.

A separate debug-build check of the current scanner on A took 1.39–1.67 s.
The comparison above used optimized code for every Swift approach: the main
problem is not merely that the app was built in debug mode.

A single additional scan of the actual DevBox repository, including build output,
found 2,963 regular files and 179,294,208 bytes across every Swift approach:
current 0.254 s, simplified Foundation 0.071 s, FTS 0.031 s, direct bulk 0.027 s.
These are single scan-body measurements, not another statistically comparable table.

### Bounded parallelism

A separate five-run experiment partitioned the synthetic trees' 100 top-level
groups between a fixed number of workers. No worker was created per file.
All variants produced identical byte and file totals.

| Approach | Fixture A median, seconds | Fixture B median, seconds |
|---|---:|---:|
| FTS, 1 worker | 0.117 | 0.347 |
| FTS, 2 workers | 0.080 | 0.225 |
| FTS, 4 workers | 0.052 | 0.177 |
| FTS, 8 workers | 0.044 | 0.160 |
| Direct bulk, 4 workers | 0.050 | 0.173 |
| Direct bulk, 8 workers | 0.043 | 0.167 |

There were scheduling outliers, including one 0.507 s FTS/2-worker run on A.
These results support testing a small concurrency cap, not assuming eight workers
is always best. A HDD, network volume, cold cache, or competing background workload
can behave differently. Directory-shape and workload imbalance also matter.

## Accounting checks and caveats

A separate fixture included seven regular file entries:
an ordinary file, a hard link to it, an APFS clone, a sparse file, a resource-fork
file, an extended-attribute file, and a compressed file. A symlink was excluded.

All five Swift variants returned **7 files / 106,496 allocated bytes**.
The 64 MiB sparse file reported zero allocated data blocks; the 1 MiB compressed
file reported 8,192 allocated bytes; the resource-fork file reported 69,632 bytes.
This is useful compatibility evidence, not proof of equivalence on every filesystem.

`du` reported 96 KiB by default versus 104 KiB with `-l`: it normally de-duplicates
hard links, whereas the app currently counts each regular directory entry.

Before implementation, preserve or explicitly redefine:

1. **Hard links:** count per directory entry, as v0 does, or de-duplicate inode/device
   identities. A speed optimization should not silently switch policies.
2. **Directories and symlinks:** v0 sums regular-file allocation, not their own
   storage. `du` has different rules even when figures happen to agree on APFS.
3. **Mounts:** preserve Foundation's non-descent into encountered mount points.
   `FTS_XDEV` is useful but device-boundary semantics need testing against that rule.
4. **Git storage:** exclude both `.git` entries and the actual shared Git metadata
   directory even if it has a nonstandard name.
5. **APFS:** attributed allocation is not exclusive/reclaimable space. Clones,
   hard links, and snapshots make “deleting this frees X” an unsafe promise.
6. **Cloud placeholders:** a measurement must not download a cloud tree. Apple's
   `du` has explicit dataless-materialization protection; public API and supported
   policy must be validated before borrowing a mechanism or claiming parity.
7. **Errors and races:** report partial measurements, check cancellation, tolerate
   concurrent changes, and never turn a read-only scan into a mutation.

Permission errors, mounted subtrees, File Provider content, invalid UTF-8 names,
and directory replacement races were **not** exercised by these timing prototypes.
They remain production acceptance cases.

## Proposed implementation order

1. Extract a UI-independent scanner preserving the existing result contract.
2. Implement an FTS backend in Swift with explicit flags and safe pointer lifetimes;
   aggregate count and `st_blocks * 512` without creating a Swift path per regular file.
3. Add cancellation and partial-error reporting, retaining all Git/storage safeguards.
4. Test accounting and traversal edge cases above against the Foundation reference.
5. Separate scanner scheduling from Git status refresh and deletion eligibility.
6. Measure a small shared concurrency cap on real worktrees. Do not multiply a
   per-worktree worker count by an unbounded number of simultaneous worktrees.
7. Add cached measurements with timestamps. If FSEvents is added later, use it to
   invalidate dirty subtrees, not to assume exact byte deltas from every event.

Direct `getattrlistbulk` is the next step only if profiling still identifies FTS
overhead as significant. The measured incremental gain does not currently justify
owning a packed-attribute parser and its compatibility surface.

[foundation]: https://developer.apple.com/documentation/foundation/filemanager/enumerator(at:includingpropertiesforkeys:options:errorhandler:)
[du-source]: https://github.com/apple-oss-distributions/file_cmds/blob/main/du/du.c
[fts-source]: https://github.com/apple-oss-distributions/Libc/blob/main/gen/fts.c
[bulk-man]: https://manp.gs/mac/2/getattrlistbulk
[attr-man]: https://manp.gs/mac/2/getattrlist
[attr-header]: https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/attr.h
[dua-source]: https://github.com/Byron/dua-cli/blob/main/crates/dua-lib/src/macos/mod.rs
