# Cached tab UI measurements

## Result

The synthetic Release comparison justified both replacing the high-cardinality
committer `Picker` with a native popup and retaining the selected project's pane
hosts. This measures synchronous hosting/layout work, **not** complete
click-to-display latency or an Instruments hitch trace.

On macOS 26.6.2 (25G83), arm64, five warm samples after warmup:

| Configuration | Median | Range |
| --- | ---: | ---: |
| Remount pane with SwiftUI committer picker | 467.7 ms | 417.7–628.8 ms |
| Remount pane with native committer popup | 158.9 ms | 156.8–164.5 ms |
| Switch retained native-popup panes | 37.1 ms | 34.0–44.6 ms |

The fixture has 672 native SwiftUI `Table` rows, two columns, and 672 distinct
committer identities. It deliberately uses no AppStore, persisted settings,
Keychain, network, or repository scans. Both remount variants have the same
table; their difference isolates the chooser implementation within that pane.
Retained samples are full worktrees/branches round trips divided by two.
Both already-created roots receive current content on each switch, as in the
production bridge. The benchmark includes host assignment and synchronous
`layoutSubtreeIfNeeded`, but not compositor presentation or asynchronous work.
There are no timing assertions.

Debug runs showed substantial machine/run variation (native remounts from
185–397 ms across runs); use the repeatable Release command
rather than treating these samples as a performance guarantee.

## Repeat

```sh
DEVBOX_TAB_BENCHMARK=1 SWIFT_BUILD_PATH=.build/tab-ui \
  bash scripts/test.sh -c release --filter CachedTabRenderingTests
```

The benchmark is opt-in. The other tests in that suite run normally and assert:

- Only the first selected pane is initially hosted; at most two hosts exist.
- The same native `NSTableView` and scroll origin survive a round trip.
- Native row virtualization remains enabled (not every row is materialized).
- The hidden table is removed from the view hierarchy and loses keyboard focus.
- Project switching releases the outgoing branch host and drops the old host map.
- Existing hosts receive changed locale, color scheme, enabled state, injected
  observable environment object and project metadata without losing native identity.

`CommitterPopUpButtonTests` cover complete name/email identity, nil/all,
actual menu action routing, disabled actions, fresh bindings, menu/item reuse,
changed options/localized titles, constrained sizing of 672 long labels, and
the native accessible popup role and label.

## Ownership and remaining verification

`RetainedProjectPanes` owns UI lifetime only. It does not create jobs or copy
session data. The segmented control and application toolbar remain outside the
hosting boundary, using the existing AppStore section selection. Full current
SwiftUI environment values are forwarded to both existing hosts on updates.
Hidden panes are detached, not opacity-stacked; they may still observe state.

`BranchListState.visibleGitHubBranches` is the cached observable `Set<GitHubBranch>`
for the current visible rows. It changes with membership/URL changes, not merely
selection or sort order, and is available to the AppStore job owner.

Focused rendering/menu/state suites passed, including the existing full
`ContentView` native-sortable-header test in all its themes. AppKit emitted
NSTableView reentrant-delegate warnings in that existing sortable-header test;
there were no test failures.

Manual Instruments traces, compositor latency, VoiceOver traversal, window
keyboard navigation, active-job hidden-pane cost, and live/peak memory remain
unmeasured. Host count/release is tested, but it is not a measurement of total
retained bytes. Do not infer frame-budget compliance or a hitch-free experience
from this synchronous fixture alone.
