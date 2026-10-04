# Memory profile: merge-target picker

Measured on 2026-10-04, Apple Silicon, macOS 26.6.2 (25G83).
The installed app reported version 0.1.0 (1). The controlled probe was compiled
from the current source with Swift 6.4 and `-O`.

## AppKit replacement: measured improvement

The production merge-target control now uses `BranchTargetPopUpButton`, an
`NSViewRepresentable` wrapping `NSPopUpButton` and `NSMenu`. All options remain
available. The default target, full-reference identity, missing saved targets,
disabled state, accessible label, and binding updates are preserved. Unchanged
menus are reused rather than rebuilt on unrelated updates.

The A/B benchmark compiles two optimized executables with identical surrounding
production views, models, and fixtures. Only the picker implementation differs:
the native production component versus the old SwiftUI implementation retained
in `Benchmarks/SwiftUIBranchTargetPicker.swift`. Both use the same external
visible label. Cases alternate implementations, each in a fresh process.

Results with **672 branch choices and 38 worktree rows**:

| State | SwiftUI footprint | AppKit footprint | Reduction |
| --- | ---: | ---: | ---: |
| Menu closed, first pair | 101.8 MiB | 38.6 MiB | 63.2 MiB |
| Menu closed, repeat | 100.3 MiB | 36.9 MiB | 63.4 MiB |
| Menu open | 101.0 MiB | 41.3 MiB | 59.7 MiB |

With the menu closed, live heap fell from **66.5–66.8 MiB to 12.2 MiB**, and
live allocation count from **688,000–690,000 to about 80,000**. With the menu
open, live heap was 70.2 MiB versus 15.2 MiB. The improvement is therefore not
merely deferring allocation until the menu opens.

At zero additional branch choices the implementations were close (35–38 MiB
footprint). At 168 choices, SwiftUI used 60.9 MiB versus AppKit's 37.2 MiB.
The large difference appears as the number of choices grows.

The open-menu case invokes the real popup and requires menu-tracking
notifications confirming that it stayed open throughout collection. No
selection is made in this benchmark. Separate regression tests cover selection,
duplicate labels with distinct references, missing-target fallback, option
updates, binding freshness, disabled actions, menu reuse, accessibility labeling,
and hosted layout with 672 long titles.

`swift test` and `swift build -c release` passed. The opt-in MariaDB integration
test was skipped. The installed app was not replaced or restarted.

These measurements isolate the project detail. They do **not** establish a new
whole-app footprint or long-term refresh behavior. The closed-menu saving is
about 63 MiB (62–63%) in this fixture, not a promise that every app session will
save exactly that amount.

## Initial finding: SwiftUI picker cost

The merge-target picker is a substantial, reproducible memory cost. Hundreds of
branch choices create hundreds of thousands of SwiftUI allocations **before the
menu is opened**, independently of filesystem scanning.

With the same 38 synthetic worktree rows, increasing the picker from zero
additional branch choices to 672 increased the project detail's footprint by
approximately **61–79 MiB** across four paired measurements (three were
61–63 MiB). This is not evidence that 150–160 MiB is an unavoidable baseline
for a small SwiftUI app.

No production behavior was changed during the initial investigation described
below; the native replacement and its A/B results are documented above.

## Installed app: post-scan snapshot

Collected from the already-running app using `vmmap -summary`, `footprint`,
`heap -s --noContent`, and `leaks --noContent --outputGraph=...`.
The app was idle at capture; it was not restarted or made to rescan.

| Measurement | Result |
| --- | ---: |
| Physical footprint | 159.9 MiB |
| Peak footprint since launch | 207.6 MiB |
| Live malloc allocations | 108.8 MiB / 978,723 allocations |
| Malloc dirty + swapped space not occupied by live allocations | 26.6 MiB |
| Suspected leaks reported by `leaks` | 14,784 bytes |

The allocator's unused space is distinct from live objects. These measurements
also include compressed/swapped memory accounting, not just resident RAM.
The leak result does not rule out unnecessarily retained but reachable objects.

Examples **within** the 108.8 MiB live heap (not additional footprint):

| Allocation type | Bytes, rounded |
| --- | ---: |
| SwiftUI platform-item arrays | 13.2 MiB |
| SwiftUI tracked-value dictionaries | 5.6 MiB |
| SwiftUI accessibility-property dictionaries | 2.9 MiB |
| Swift runtime metadata | 4.1 MiB |
| Recognized closure contexts, owners not fully classified | 8.5 MiB |

A type-name classification identified approximately 62.6 MiB as explicitly
SwiftUI-related. That is a lower-bound classification of recognizable types,
not a complete ownership or allocation-stack attribution: many closures and
non-object allocations could also belong to the UI.

The snapshot contained:

- 711 `SwiftUIMenuItem` objects.
- 40 `WorktreeState` objects occupying 20 KiB of direct object storage.
- 34 `DatabaseRowState` objects occupying about 11 KiB of direct object storage.
- Three project sessions and one database session.

Those model sizes exclude their referenced strings and containers. However,
they are not a large per-file cache. The scanner returns three aggregate
numbers and closes its FTS traversal; finished scan jobs leave the queue.

One configured project had 38 worktrees and 672 local/remote refs. Symbolic refs
are excluded from the actual picker, so the raw ref count need not equal its
exact option count.

### Retention evidence

The memory graph traces one of the two largest platform-item arrays (768 KiB
each) through:

```text
SwiftUI popup button
  -> popup button cell
     -> SwiftUIMenu
        -> cachedItems: [SwiftUI.PlatformItemList.Item]
```

The array itself is only part of the cost. Its items have associated view,
style, accessibility, observation, and closure state.

The original `MergeTargetPicker` in `Sources/DevBox/ContentView.swift` constructed
every branch option using `Picker` + `ForEach`. That implementation is now
retained only as the benchmark control.

## Reproducing the measurements

Run:

```sh
sh scripts/profile-memory.sh
```

The script compiles `Benchmarks/MemoryProfile.swift` with the production project
detail views and models, excluding the normal app entry point. It now compares
both implementations; `PROFILE_PICKERS=native` or `PROFILE_PICKERS=swiftui`
restricts the run to one. Each case:

- Runs in a fresh optimized process, hosted in an explicit 1140×720 AppKit
  window containing SwiftUI's production `WorktreesView`.
- Uses synthetic branch targets and the same 38 synthetic worktrees.
- Does not read saved settings, access credentials, or run repository scans.
- Samples approximately eight seconds after process launch and verifies that
  the view appeared before collecting `vmmap` and `heap` reports. This is not
  a guarantee of eight seconds of idle time after rendering.
- Leaves the menu closed except for the final, explicitly named `detail-open`
  case, which measures the real menu while open.

Do not interact with or obscure the profiling windows during the run. This is
an opt-in GUI profiling tool requiring a logged-in macOS desktop, Swift tools,
Python 3, `vmmap`, and `heap`.

### Initial SwiftUI option-count experiment

Ranges below cover two runs before the native replacement, with menus never
opened. The zero-branch model control was added for the second run. All cases
retain the same 38 worktree rows.

| Case | Samples | Footprint | Live heap | Live allocation count |
| --- | ---: | ---: | ---: | ---: |
| Models + count label, 0 targets | 1 | 16.2 MiB | 5.07 MiB | 32,838 |
| Models + count label, 672 targets | 2 | 16.5–17.4 MiB | 5.19–5.23 MiB | 33,469–33,616 |
| Production detail, 0 additional branch choices | 4 | 37.5–38.3 MiB | 10.49–10.54 MiB | 57,352–58,563 |
| Production detail, 168 branch choices | 2 | 53.7–60.6 MiB | 25.65–29.84 MiB | 230,541–248,549 |
| Production detail, 672 branch choices | 4 | 98.8–117.3 MiB | 66.78–81.68 MiB | 690,128–745,373 |

The default "Main checkout" option remains in every detail case. The 672-choice
cases had 673 `SwiftUIMenuItem` objects, versus one in the zero-choice cases.
Direct worktree object storage remained 19,456 bytes in all cases.

Paired footprint increases were 61.3, 62.5, 79.3, and 63.3 MiB. Three of the
four pairs added approximately 56 MiB of live heap and 632,000 allocations;
one retained more UI state at the sampling time. The experiment does not
establish the reason for that variation or long-term steady-state usage.

By comparison, adding the branch targets in the model-plus-label control
increased live heap by only about 0.12 MiB in the second run. This control still
contains a window and a text view, so its absolute footprint is not model-only
storage. It nevertheless supports the finding that branch-data storage is not
the main cost.

### Limits

This isolates the project detail, **not** the complete app shell, sidebar,
commands, previous navigation history, or completed scan allocations. Synthetic
rows also lack completed size/status results. The original option-count
experiment did not test an optimization; the later A/B experiment does, but
still does not predict an exact new whole-app footprint. The installed
executable and probe are not asserted to be byte-identical builds.

There was no pre-scan capture of the installed process, no repeated-refresh
growth test, and no allocation-stack trace from its launch. The evidence shows
a large eager UI cost, not a diagnosis of every byte or a proven SwiftUI leak.

## Recommendation

Keep the measured, targeted native-popup replacement rather than making a
broader UI or scanner rewrite.

A searchable, on-demand branch chooser is another option and could be easier
to use with hundreds of refs, but changes the interaction more substantially.
There is no evidence here that the scanner needs rewriting or that the whole
application should move away from SwiftUI.

## Artifacts

Generated reports and the local installed-app memory graph are under ignored
`build/memory-profile/`. The script does not capture an installed process
automatically. New A/B runs get timestamped directories under `runs/`, containing
per-case logs, `vmmap`/`heap` reports, `summary.json`, and OS/compiler/revision
information in `environment.txt`. The measured A/B run was
`runs/20261004-131556-570932/`.

The script also records source hashes in `sources.sha256` for future runs, since
the revision alone does not identify uncommitted changes.

Older, pre-replacement reports remain at the top level and under `first-run/`.
They are not overwritten by the updated script.

The installed-app artifacts are local diagnostics, not committed fixtures.
Memory graphs can contain application state and paths even with content
descriptions suppressed; inspect them locally rather than publishing them.
