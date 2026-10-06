# Worktree refresh performance

Introduced in v0.5.0, following the v0.4.0 GitHub integration.

## Changes

- `AppStore` submits at most **two Git-status operations per refresh**, refilling
  only when a result completes. Rows update independently; one failed status
  does not cancel another. Missing/bare worktrees are skipped.
- The shared blocking-I/O executor still has **four workers**, with interactive,
  normal, and background queue priorities. Project discovery, worktree/branch
  inventory, and status reads take priority over queued directory scans.
- The default size queue allows **two scans**, including shared Git storage.
  This leaves capacity for interactive Git reads rather than letting background
  scans occupy every worker. Canceled scans retain their slots until they exit.
- Status uses `git --no-optional-locks`: observing status no longer refreshes the
  index as a side effect or competes for an optional index lock with an editor.

Priority only reorders **queued** work; it does not preempt a running subprocess
or traversal. Two status tasks is a per-refresh limit, while the executor caps
physical workers across refreshes, including old operations winding down after
cancellation. Generation checks prevent stale results from publishing or
submitting remaining rows after a new refresh/project selection.

This deliberately favors usable status information over maximum background
sizing throughput. Reducing scan concurrency may lengthen full sizing on some
storage systems; do not claim it makes every phase faster. No auth, deletion,
GitHub batching, or database concurrency behavior changed.

## Repeatable benchmark

```sh
make benchmark-refresh
# Customize without touching real projects:
BENCH_WORKTREES=12 BENCH_STATUS_FILES=2000 BENCH_RUNS=5 make benchmark-refresh
```

The optimized standalone benchmark creates detached Git worktrees under a fresh
`.build` fixture, with an isolated HOME and disabled hooks/signing/fsmonitor.
Each worktree has one staged file, one modified file, and the requested number
of untracked files. Every measured result must match these counts. The fixture,
executable, and compiler cache are removed when the script exits.

Both modes use the same production `GitService.status` and optional-lock policy.
One untimed warm-up precedes each mode, and measured order alternates. Setup is
excluded. This compares sequential status calls with a two-task sliding window;
it does **not** benchmark AppKit layout, cold disks, or competing directory scans.

### Initial sample

12 worktrees × 2,000 untracked files, five runs per mode, optimized local macOS
build:

| Mode | Median all statuses | Range | Median first row |
|---|---:|---:|---:|
| Sequential | 0.362864 s | 0.346379–0.498050 s | 0.023976 s |
| Two concurrent | 0.236564 s | 0.213252–0.322227 s | 0.025180 s |

The median total was about **35% shorter** (1.53× sequential/parallel ratio).
First-row latency was roughly unchanged. These are warm-cache synthetic results,
not a universal speedup or an end-to-end responsiveness claim.

## Correctness evidence

```sh
sh scripts/test.sh --filter 'BlockingIOExecutorTests|WorktreeSizeQueueTests|WorktreeStatusLoading'
```

Continuation gates prove overlap, bounded submission, incremental publication,
per-row errors, stale-result suppression, cancellation, and deleted-row safety
without timing assertions. Dedicated-worker gates prove that two held scans
leave workers available for status and that queued interactive jobs precede
older background jobs. Destructive-operation success still remains success if
cancellation arrives after submission.

The visible worktree-header test still emits an AppKit `NSTableView` reentrancy
warning. It also occurred in the v0.4.0 baseline before these scheduling changes;
the assertions pass, but that existing UI warning merits a separate follow-up.

Further work should measure real large projects and full-refresh latency with
Instruments before increasing concurrency. Cross-repository GitHub scheduling
remains a separate optional optimization; the released two-batch cap is unchanged.
