# SwiftUI responsiveness: findings and recommended changes

Research against Apple's current documentation, WWDC23/25 performance guidance,
and DevBox's implementation.

## Implementation update

The app now uses Observation-backed project sessions and stable row models. The
table observes membership separately from cell values. Active/cache array duplication
has been removed; refresh reconciles the existing rows instead of emptying the table.
Row display text, totals, and branch-picker options are cached, with bulk summary
updates coalesced during reconciliation. Cells continue receiving explicit models,
not implicit environment dependencies.

Tests use Swift 6.2 `Observations` and `withObservationTracking`; a 200-row regression
asserts that one measurement changes only its row's dependency, not the table
collection or unrelated rows. These assertions prove dependency scope, not a
specific frame-rate improvement. The blocking-I/O boundary now uses a bounded
OperationQueue executor with cancellation and checked continuations. Use a refresh-time Instruments trace for
end-to-end responsiveness verification.

The worktree-refresh follow-up bounds status loading to two concurrent tasks,
prioritizes queued interactive Git reads, and limits background scans to two of
the executor's four workers. See [worktree refresh measurements](worktree-refresh-performance.md)
for the synthetic benchmark, safety tests, and sizing-throughput trade-off.

The analysis below describes the pre-refactor design and its rationale.

## Bottom line

DevBox's Git subprocess waits and FTS traversal already run off the main actor.
The strongest next step is to **reduce the scope and cost of UI updates**, not
increase scan concurrency or replace SwiftUI.

There are two separate concerns:

1. Broad observable dependencies, repeated derived calculations, and redundant
   snapshot copies create avoidable main-actor work.
2. Synchronous Git/FTS I/O currently occupies Swift's cooperative worker pool.
   A bounded blocking-I/O executor bridged through checked continuations is a more
   appropriate long-term boundary for those APIs.

Neither finding proves the cause of the reported lag. The previous five-second
sample showed SwiftUI/AppKit layout and view-update activity on the main thread,
but did not capture active Git/FTS operations during a slow refresh. No speedup or
responsiveness improvement has yet been measured from the recommendations here.

## 1. View invalidation is not synonymous with redrawing every pixel

SwiftUI tracks dependencies, marks affected nodes out of date, evaluates view
bodies as needed, reconciles the resulting values, and performs layout/render work.
Those are related but different stages.

An `ObservableObject` change can cause an observing view to reevaluate even when
the changed published property was not used by that view. SwiftUI may still avoid
downstream work for unchanged children, and multiple synchronous mutations can be
coalesced into a transaction. Therefore, do not equate:

- one `@Published` assignment with one complete redraw; or
- many short view-body evaluations with good overall responsiveness.

Apple's performance guidance covers both long individual updates and excessive
numbers of otherwise short updates. The SwiftUI instrument's Cause & Effect Graph
is designed to determine which dependency triggered the work.

Sources: [Understanding and improving SwiftUI performance][performance],
[Demystify SwiftUI performance][demystify], [Optimize SwiftUI performance with
Instruments][instruments].

## 2. Use property-level Observation, but scope the model too

`@Observable` lets SwiftUI track the properties read by a particular view's `body`,
including reads performed through computed properties. Apple explicitly contrasts
this with the broader invalidation behavior of `ObservableObject`.

However, replacing the annotation on one giant store is not enough:

- A view that reads an entire `rows` array still depends on that array.
- A computed `total` that traverses all row measurements depends on those reads.
- If a parent reads all row fields to build child values, those dependencies are
  attached to that parent.

Apple's WWDC25 performance example demonstrates unnecessary updates even with
`@Observable`, because every row checks membership in the same changing collection.

Recommended model shape:

```text
App UI state
  selection, navigation, sheet state

Project session state (one per project)
  stable worktree collection and IDs
  observable state for each worktree
  cached summary presentation
  branch target options and inspection result

Worktree state (stable object for the row)
  working-copy status
  branch lifecycle
  measurement, timestamp, scan state, error
```

The session cache should own these project states. Selecting a project changes a
reference to its state, rather than copying the complete project into a second
active array and repeatedly copying it back.

Keep UI state on `@MainActor`; adopting Observation does not make mutable models
thread-safe or move their methods off-main. Pass row models/presentation values
explicitly into table cells, retaining the environment-independent design that
fixed the earlier cell crash.

Sources: [Migration to Observation][migration], [Discover Observation in SwiftUI][observation],
[WWDC25 performance, collection dependencies][instruments].

## 3. Keep view bodies cheap

Prepare results once when their underlying data changes, instead of repeatedly
calculating them inside `body` or computed properties used by `body`.

In DevBox, inspect:

- Per-project total reconstruction in every sidebar row.
- Repeated filters for selected worktrees, busy counts, and deletion eligibility.
- Byte-count formatting, date/help strings, and URL-derived names inside cells.
- Construction of every merge-target picker option on unrelated status/size changes.
- Stored view-building closures in `DetailHeader` and `StatusFooter`.

These are not equally expensive, and no local profile has ranked them yet. Start
with measured costs, not a blanket ban on computed properties or formatting.

For reusable containers, Apple recommends evaluating a parameterless
`@ViewBuilder` closure in the initializer and storing the resulting view value,
instead of storing an escaping builder. Action closures such as button handlers
are not categorically wrong, but should capture narrow dependencies.

Formatting can be cached or moved to a presentation layer; invalidate appropriately
when locale or relevant settings change. Use typed format styles where suitable.
Do not move cheap operations to detached tasks one at a time: task overhead and
extra updates can cost more than the original work.

Sources: [Apple's efficient design patterns][performance],
[WWDC25 example caching formatted strings][instruments].

## 4. Keep list identity and content stable during refresh

DevBox already uses stable worktree path IDs. Retain them:

- Update existing row models by ID.
- Replace collection membership/order only when Git's inventory changes.
- Preserve cached content while fresh data is loading.
- Avoid clearing a table to `[]` and repopulating it just to express loading.
- Show loading state on the affected row or small status view.
- Do not regenerate UUIDs or use `.id(UUID())` to force updates.

Keep the merge-target picker in its own view with stable, precomputed options.
If profiling shows very large branch lists are expensive, consider a searchable
selector populated on demand. Do not impose that UI change without evidence.

`EquatableView` can help narrowly defined value-only views, but is not the first
fix. Incorrect equality can suppress required changes or preserve stale actions;
it does not eliminate dependencies created by dynamic properties.

Source: [Demystify SwiftUI performance, identity in List and Table][demystify].

## 5. Background tasks: what is correct and what needs improvement

### Current behavior

- `AppStore` and `WorktreeSizeQueue` are explicitly `@MainActor`.
- Their `Task {}` closures inherit main-actor isolation.
- The production Git/FTS services call `Task.detached(priority: .utility)` around
  synchronous work. That is what prevents their blocking operations from executing
  on the main actor.
- The size queue caps work at four scans, including shared Git storage, and retains
  canceled slots until traversal actually exits.
- Git status requests are sequential across worktrees.
- MariaDB already uses a utility dispatch queue and checked continuations.

### Async does not mean off-main or nonblocking

`await` marks a possible suspension, not an unconditional thread switch.
`Task {}` and view `.task` are not “background thread” declarations.
`Task.detached` avoids inheriting actor isolation but still uses Swift's cooperative
worker pool; it is not a private operating-system thread.

Apple warns that blocking file I/O, network I/O, or process waits can occupy that
limited pool. Where asynchronous APIs are unavailable, use a bounded dispatch or
operation-queue boundary and bridge completion through checked continuations.
Do not replace one capped queue with unbounded `DispatchQueue.global().async` work.

For DevBox, retain a small global scan budget and run blocking FTS operations on
that executor. Prefer asynchronous process completion and output draining for Git;
otherwise isolate those waits on a separately bounded blocking-I/O queue. Propagate
cancellation, retain stale-result generation checks, and resume each continuation
exactly once. Do not introduce semaphore waits on the main actor.

This is engineering hardening, not evidence of current cooperative-pool exhaustion.
Four scans do not by themselves prove starvation.

### Swift 6.2 isolation caveat

Older guidance says a nonisolated async function switches to the generic executor.
Swift 6.2's `NonisolatedNonsendingByDefault` upcoming feature changes that default
to inherit the caller's actor; `@concurrent` explicitly opts out.

DevBox's package currently declares neither default main-actor isolation nor that
upcoming feature. Keep execution boundaries explicit, rather than relying on what
`async` happens to mean under future build settings. `@concurrent` is useful for
offloading computation; it does not make blocking I/O suspend its worker thread.

Sources: [Improving app responsiveness][responsiveness],
[Visualize and optimize Swift concurrency][concurrency],
[Embracing Swift concurrency][embracing], [SE-0461][se0461].

## 6. Concrete DevBox mechanisms found by code inspection

| Current location | Mechanism | Recommended change |
|---|---|---|
| `AppStore`: shared `ObservableObject`, many published properties | Subscribers can update for unrelated property changes | Scope observable state per project/row; isolate sidebar, picker, footer, dialogs |
| `updateRow` and `cacheSelectedProject` | Every mutation stores another full array snapshot; the next indexed write can trigger array copy-on-write | One session-owned project model; avoid active/cache duplication |
| `refresh(useCache:)` | Clears rows before restoring or fetching and maps all rows again | Reconcile by stable ID; preserve old content |
| `sizeSummary(for:)`, `ProjectSizeSummary` | Repeated aggregation during view evaluation | Store/update a summary when measurements change |
| `mergeTargetPicker` | Iterates all refs in a broadly invalidated view | Separate view with narrow option/selection dependencies |
| Cells and headers | Formatting and help construction during evaluation | Cache expensive display values when measurements change |
| `GitService.background` | Synchronous I/O/process waits on detached cooperative workers | Bounded blocking-I/O executor or true async process APIs |

Copy-on-write is a concrete possible cost here, not an assertion that every
assignment immediately copies the array or that this is the dominant bottleneck.
Swift arrays initially share storage; the expensive part can be the next mutation
while both the cached snapshot and active array retain it.

## 7. Update rate: avoid inventing a per-file progress problem

The current FTS scanner does not publish progress for every file. It publishes
queued, started, and finished state per scan. Do not add throttling and claim to
have fixed a nonexistent per-file update stream.

If many results arrive together, coalesce project-summary updates into a short
batch. A starting experiment could use a 50–100 ms maximum interval for aggregate
progress, with immediate final flush. That interval is an engineering hypothesis,
not an Apple-mandated value.

Do not debounce until “quiet” in a way that starves progress during continuous work.
Do not delay selection, errors, authentication state, or deletion results just to
lower update counts.

## 8. Verification plan

1. Profile an optimized, certificate-signed build while refreshing a realistically
   sized project and scrolling, selecting rows, switching projects, and opening the
   branch selector.
2. Use Instruments' **SwiftUI** template, including **Time Profiler**, **Hangs**,
   **Hitches**, and the **Cause & Effect Graph**. Attach to the existing app; a new
   Xcode project is not required for profiling.
3. Correlate intervals for Git process work, FTS work, applying results, and summary
   recomputation using signposts. Record row/ref counts and cache state.
4. Separate first-load timing, cached switching, and explicit refresh. File-scanner
   throughput benchmarks alone do not measure UI responsiveness.
5. Change one layer at a time and repeat the same interactions and workload.
6. Add a deterministic stress harness with many rows and staggered fake results so
   we can test the real table without touching user repositories or databases.
7. Keep functional checks for selection retention, cache refresh, cancellation,
   stale-generation isolation, one-at-a-time deletion, and missing environments.

Apple's rough targets are less than 100 ms for a discrete interaction and less than
one frame interval (about 8.3 or 16.7 ms) for continuous interaction; main-thread UI
work under about 5 ms is a useful starting budget, not a universal guarantee.

Instruments flags long body updates at 500 microseconds (orange) and 1,000
microseconds (red). These are investigation thresholds, not proof that a given
update caused a visible hitch.

Use `_printChanges()` only temporarily for debug investigations. It is an
underscored facility and logging can itself perturb performance.

## Implementation priority

1. Capture a refresh-time responsiveness baseline.
2. Introduce stable session/project/row state and narrow Observation dependencies.
3. Remove active/cache snapshot duplication and preserve rows during refresh.
4. Cache summaries/options/display values; isolate view builders and update causes.
5. Put blocking I/O behind a bounded executor while preserving cancellation.
6. Re-profile before changing worker counts or introducing more parallel Git work.

Keep SwiftUI and native `Table`. Consider an AppKit table wrapper only if measured
framework costs remain after the model/update problems are corrected.

[performance]: https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance
[demystify]: https://developer.apple.com/videos/play/wwdc2023/10160/
[instruments]: https://developer.apple.com/videos/play/wwdc2025/306/
[migration]: https://developer.apple.com/documentation/swiftui/migrating-from-the-observable-object-protocol-to-the-observable-macro
[observation]: https://developer.apple.com/videos/play/wwdc2023/10149/
[responsiveness]: https://developer.apple.com/documentation/xcode/improving-app-responsiveness
[concurrency]: https://developer.apple.com/videos/play/wwdc2022/110350/
[embracing]: https://developer.apple.com/videos/play/wwdc2025/268/
[se0461]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0461-async-function-isolation.md
