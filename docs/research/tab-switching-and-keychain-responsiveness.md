# Tab switching, background jobs, and Keychain responsiveness

Original research against revision `2c80f84` and Apple's SwiftUI, concurrency,
AppKit, and Security documentation. The audit below records the pre-change
behavior and the rationale for the implementation.

## Implementation update

The implementation now uses independent project-operation owners, keeps jobs
alive across tabs, and cancels read-only jobs on project departure. An explicit
Fetch & Prune finishes and verifies its original project's cache. Inventory and
merge-target revisions fence stale inspection/protection results, including
concurrent hidden-tab work and deletion.

Credential APIs are async, with synchronous Security calls on a dedicated serial
DispatchQueue. Failed GitHub credential access stays latched until explicit retry.
Sign-out drains an existing token rotation before removal, so refusal cannot
strand the visible account with a consumed refresh token.

The selected project's two panes are lazily retained, and the committer chooser
uses a native popup. Each pane observes its own operation state, not whichever
tab is selected. See [cached tab UI measurements](cached-tab-ui-measurements.md)
for the synthetic Release results and their limits.

Regression tests cover held jobs across tab/project switches, dependency
invalidation, late results around deletion, real synchronous fake credential
backends with a responsive main actor, credential races/rollback, and native
table retention. The full test suite and Release build pass. Real permission
prompts, end-to-end presentation latency, and retained memory remain manual
profiling work; no user Keychain settings were modified to induce prompts.

## Recommendation

Keep SwiftUI and the existing Observation-backed sessions. Separate three
lifetimes that are currently coupled:

1. **Presentation:** which tab is visible.
2. **Project work:** inventory, status, branch inspection, sizes, and PR requests.
3. **Credential access:** potentially interactive, blocking Security operations.

Tab switches should only change presentation and ensure the requested data has
started loading. They must not cancel already-running work. For project switches,
the recommended default is to cancel unfinished **read-only** project work, retain
completed results, and schedule missing results when returning. This bounds disk,
CPU, and network use without making tabs behave like cancellation buttons.

Move Keychain operations off the main thread regardless of the UI optimization
chosen. This addresses a confirmed blocking path, not a speculative SwiftUI issue.

## What the current code establishes

| Finding | Evidence | Confidence |
| --- | --- | --- |
| Switching tabs cancels active jobs. | `AppStore.projectSection.didSet` calls `loadSelection`, which calls `refresh(useCache: true)`. `refresh` cancels both task handles, cancels the size queue, pauses scans, and changes the generation. | Confirmed from code. |
| Returning to Worktrees retries unfinished work. | The cached refresh path requeues pending sizes and missing statuses; `loadProjectOverview` restarts incomplete branch inspection. | Confirmed from code. No repeated-switch timing captured. |
| Cached branch inventory does not require another Git read. | `loadBranchList` returns on a valid cache hit. Fetching remotes is explicit. | Confirmed from code and existing cache tests. |
| The two tab hierarchies are conditional, not retained panes. | `ProjectView.body` switches between `WorktreesView` and `BranchesView`. | Confirmed structure. Its contribution to the reported delay is not yet measured. |
| The committer dropdown contains all unique committers. | `BranchesView.controls` uses SwiftUI `Picker` and `ForEach(session.committers)`. | Confirmed. Construction cost depends on unique committers, not just branch count. |
| Keychain calls execute synchronously on the main actor. | Both credential protocols are `@MainActor`; their implementations directly call `SecItemCopyMatching`, `SecItemUpdate`, `SecItemAdd`, and `SecItemDelete`. | Confirmed blocking path. |
| There is no evident polling while a Keychain prompt is open, but failed saves can be retried automatically. | GitHub restore and concurrent token refresh are guarded, but PR loading continues to another repository/batch after an authorization error. A pending refreshed token then causes another credential-save attempt. | Repeated-access path confirmed from code; whether it repeats the system prompt needs a trace. |

Relevant source:

- [Navigation and cancellation](../../Sources/DevBox/AppStore.swift#L159),
  [refresh lifecycle](../../Sources/DevBox/AppStore.swift#L612),
  [cached worktree loading](../../Sources/DevBox/AppStore.swift#L655).
- [Conditional tab content](../../Sources/DevBox/ContentView.swift#L245),
  [committer picker](../../Sources/DevBox/BranchViews.swift#L89).
- [Database credential isolation](../../Sources/DevBox/Settings.swift#L23),
  [blocking database lookup](../../Sources/DevBox/Settings.swift#L74),
  [GitHub credential isolation and lookup](../../Sources/DevBox/GitHubCredentials.swift#L5).

The earlier [merge-target picker measurements](memory-profile.md) demonstrate
large eager allocation for hundreds of SwiftUI menu choices. They do **not**
measure the current committer picker or tab-switch latency.

## 1. Make job lifetime independent of tab lifetime

### Proposed behavior

| Event | Behavior |
| --- | --- |
| Worktrees ↔ Branches in the same project | Continue existing work, including PR batches. Start missing work for the entered section once; reuse an in-flight request or completed cache. |
| Switch project or select a database connection | Cancel the old project's unfinished read-only jobs, retain successful results, and prioritize the new destination. Cancellation is cooperative, not an instantaneous stop. |
| Return to a project | Show cached results immediately and schedule only missing/pending work. A canceled directory traversal restarts that measurement; it does not resume at a filesystem cursor. |
| Refresh a section | Supersede that section's affected jobs; leave unrelated work running. Keep last-known content visible. |
| Fetch & Prune | Explicit network operation. Do not start it on navigation. If already running when navigation changes, treat its outcome as potentially changed refs and require inventory verification, not as a rolled-back operation. |
| Delete or otherwise mutate repository data | Use an explicit mutation boundary. Cancel conflicting reads, perform the confirmed mutation, invalidate dependent caches, and reject pre-mutation completions. Do not cancel destructive work merely because a tab disappears. |
| Sign out/change GitHub account | Cancel account-dependent PR work and invalidate its cache through the account generation, regardless of selected project. |

Use a small, project-scoped task owner alongside the existing
`ProjectSessionState`, rather than one global refresh task for every section.
Keep the observable presentation models on `@MainActor`; the owner coordinates
async work but does not perform blocking Git/filesystem operations there.

The owner needs:

- Separate task handles and loading/error state for worktree inventory/status,
  branch inventory, merge inspection, and sizes. One section finishing must not
  clear another section's busy indicator or error.
- A project activation generation plus operation-specific revisions. A tab
  switch changes neither. A project departure invalidates its active reads;
  refreshing branches supersedes branch work without invalidating size results.
- Completions addressed to a **captured session and operation identity**, never
  to whichever project happens to be selected at completion time.
- Idempotent `ensureLoaded` behavior: valid cache → no work; in flight → reuse;
  missing → start. Cancellation leaves missing/pending state, not an error.
- Explicit dependency invalidation. For example, worktree reconciliation can
  invalidate branch protection/inventory information while the Branches tab is
  visible. Mark dependent snapshots unverified and ensure required revalidation
  is scheduled; independent task handles must not turn stale data into a valid
  deletion snapshot.
- Session-owned task handles excluded from Observation. Avoid task/owner retain
  cycles by clearing handles on completion and explicitly canceling on departure.

Merely removing `cancelAll()` is not safe. Current size/status/overview helpers
update `selectedProjectSession`, and global `isRefreshing`, `loadError`, and
`progressText` cannot represent two independent tab operations. See
[status and size callbacks](../../Sources/DevBox/AppStore.swift#L789) and
[overview loading](../../Sources/DevBox/AppStore.swift#L877).

PR loading also needs to move out of the view's lifetime:
[BranchPullRequestControls](../../Sources/DevBox/BranchPullRequestViews.swift#L33)
currently cancels loading in `onDisappear`. Keep the account-level result cache
and its existing deduplication, but let the active project's task owner control
which branch set is requested. A filter change can change demand; hiding the tab
must not. Completed results remain reusable across projects.

Keep the existing shared limits: two size jobs and the bounded four-worker
blocking executor. The two-status-read limit is currently per task group, and
the two-PR-batch limit (up to 25 branches each) is per load, not a strict global
occupancy limit. Replacement loads can overlap canceled predecessors while
already-started operations finish.

Project ownership is not permission to create a fresh unbounded executor for
every project. If strict cross-generation status/PR limits are required, add
shared admission control that retains an occupied slot until the actual operation
exits, and test replacement loads against held old requests. Do not describe
per-load task-group limits as providing that guarantee today.

## 2. Preserve useful UI state and remove expensive reconstruction

Apple's guidance emphasizes stable identity, cheap view bodies, narrow
dependencies, and measuring both long updates and excessive update counts
([SwiftUI performance][swiftui-performance], [WWDC23][wwdc23],
[identity and lifetime][identity]).

Apply that guidance without replacing the entire UI:

1. Preserve each tab's filter, sort order, selection, and scroll position when
   navigating. The existing section setter clears both selections. Stop treating
   navigation as deselection; prune selection when inventory/filter membership
   actually changes, and keep destructive actions scoped to the visible section.
2. Keep the stable row models and cached row presentation already implemented.
   Read individual changing row properties in cells, not the whole table parent.
   Cache derived PR branch sets when membership changes instead of constructing
   them repeatedly in the table's view body.
3. Profile the committer picker separately. Prefer the proven native popup
   approach used for merge targets if large option sets dominate construction.
   A searchable, on-demand chooser is a reasonable later UX change, not a
   prerequisite for this fix.
4. Measure whether cached tab remounting remains expensive after reducing the
   controls' cost. If it does, retain two lazily created pane hosts for the
   **selected project**, rather than reconstructing each hierarchy on every
   switch. Release those hosts on project departure; retain the lightweight
   session data.

### Container choices

- **Current conditional content:** simplest, smallest retained UI, but does not
  preserve the outgoing view hierarchy. Keep it only if warm-switch measurements
  meet the target after the cheaper fixes.
- **SwiftUI `TabView`:** the standard declarative control and worth evaluating,
  but its documentation does not promise a particular native-table lifetime.
  Verify actual retention and scroll behavior on supported macOS versions;
  changing the spelling of the container alone is not a performance proof.
- **Small `NSTabViewController` bridge hosting SwiftUI panes:** preferred fallback
  if measured remount cost requires explicit ownership. Apple documents separate
  child controllers and lazy loading on first selection. This gives a bounded
  place to retain the two panes without rewriting their SwiftUI tables.
- **Keep everything in a `ZStack` with zero opacity:** not recommended as the
  default. Invisible content can still observe updates, take part in layout, and
  need explicit focus, hit-testing, and accessibility handling.

Retained panes trade memory for warm-switch latency and can still receive
updates while hidden. Measure both costs. Test keyboard focus, accessibility,
toolbar targeting, environment/theme changes, and scroll restoration. Do not
retain every visited project's full UI or add arbitrary `.id(UUID())` resets.
Do not replace `Table` with a nonvirtualized stack of rows.

## 3. Keychain: suspend the caller, do not block the UI

Apple explicitly states that [`SecItemCopyMatching`][keychain] blocks its calling
thread and can hang the UI when called on the main thread. The current app does
exactly that for both MariaDB and GitHub credentials.

Putting the call inside `Task {}` is not a fix: tasks created from main-actor
code inherit its isolation. `async` alone also does not mean background work.
Swift 6.2 isolation settings affect nonisolated async execution; choose an
explicit execution boundary instead of relying on a compiler default.

### Recommended boundary

Expose async credential operations, backed by a dedicated **serial background
DispatchQueue** and checked continuations. Build the Security query and consume
its Core Foundation result within that queue; return a typed, Sendable result.
The UI caller suspends while the queue waits on Security.

An actor can own logical credential state and coalesce requests, but ordinary
actor isolation is not a dedicated blocking-I/O executor. Likewise, a detached
task alone would occupy a cooperative worker while waiting on the prompt.
Apple recommends moving blocking operations outside that pool and bridging
with continuations ([Swift concurrency performance][concurrency]).

Important details:

- Apply the boundary to **reads, writes, and deletion**, not only startup reads.
  Use a credential queue separate from the Git/disk executor so waiting for
  permission cannot consume its workers.
- Coalesce concurrent reads of the same credential and retain a password only
  for the operation/session that needs it. Do not add polling, infinite retries,
  plaintext persistence, or secret-bearing diagnostics.
- Preserve current permission/security semantics initially. The code does not
  explicitly request user-presence authentication; the reported prompt may be
  macOS Keychain access/unlock authorization. Do not assume `LAContext` options
  for biometric-protected items will control every kind of macOS prompt.
- Report denial/cancellation once and allow an explicit retry. Do not treat
  denied access as “no saved password” or automatically delete credentials.
- Latch credential-access failure at the account/operation level until an
  explicit retry. PR batches must not treat a credential failure as an ordinary
  repository-specific error and immediately attempt the same save again. Keep
  any pending rotated token in memory; do not retry with the consumed old token.
- Cancellation may not stop an already-running Security operation or dismiss
  its prompt. Reject stale UI results, but account for writes that may already
  have committed.
- Async conversion creates new interleaving points. Preserve connection-save
  rollback ordering; serialize logical operations per credential, not just each
  individual `SecItem` call. An old token save must not persist credentials after
  a newer sign-out. Recheck operation/account identity after each `await`, and
  order persistent writes/removal so stale state cannot return on next launch.
- Protect shared settings too. `saveConnection` currently snapshots the whole
  `AppSettings` before accessing Keychain. Adding `await` there without changing
  the commit could overwrite an unrelated project, connection, or editor-setting
  change made while waiting. Validate the operation and merge its changes into
  current settings at commit time, or serialize all settings mutations through
  a suitable transaction boundary. Per-credential serialization alone does not
  prevent this newly introduced risk.
- Keep first rendering independent of credential completion. Existing startup
  restore-once and token-refresh coalescing guards should remain.

The source audit found no loop polling Keychain while a permission prompt is
open. However, there is a concrete sequential-retry path:

1. A signed-in account needs a token refresh.
2. `currentAccessToken` retains the rotated token in `pendingToken`, then
   `credentials.save` fails. Its in-flight refresh handle is cleared.
3. PR loading records the current repository's error and continues to the next
   repository, or schedules another batch after a failed batch.
4. The next `authorized` call sees the pending token and tries saving it again.

See [token persistence and retry](../../Sources/DevBox/GitHubSession.swift#L183)
and [PR repository/batch error handling](../../Sources/DevBox/GitHubPullRequestCache.swift#L99).
Coalescing concurrent refresh requests does not prevent these sequential retries.
This can produce repeated Keychain access attempts after a failure, although
repeated system prompts depend on macOS authorization behavior. It strengthens
the case for an explicit credential-access failure state as well as an off-main
queue. The normal GitHub device authorization polling flow is a separate feature,
not permission polling. A trace is still needed to establish the exact origin
and duration of the user's reported prompt.

## 4. Verify the experience, not just the architecture

Before claiming smoothness, capture a Release-build baseline and repeat the same
workflow after each change. Use Instruments 26's SwiftUI template, Time Profiler,
Hangs/Hitches, and the cause-and-effect graph ([WWDC25][instruments]).

Use synthetic cached fixtures without saved settings, real credentials, network
calls, or filesystem scans for the UI-only comparison:

- Small and large worktree/branch inventories, varying unique committer count
  independently. Include the existing 38-worktree/672-ref scale and larger cases.
- First tab visit versus repeated switches after both tabs are fully loaded.
- Current container versus cheaper picker; only then compare retained hosts.
- No jobs versus active jobs, with GitHub signed-out and fixture-backed signed-in
  states. Measure hidden-pane updates as well as visible ones.

Record click-to-visible-content latency, main-thread stalls, native-table/control
creation counts, scroll/selection preservation, and live/peak memory over repeated
switches. Timing only the section setter or counting `body` calls does not measure
the complete transition.

Apple's rough thresholds are <100 ms for discrete interactions and a display
interval for continuous updates; it recommends aiming for <5 ms of main-thread
update work ([responsiveness][responsiveness]). Use no >100 ms warm-switch stalls
and no detected hitches as initial acceptance goals, not as measured results or
a claim that 99 ms always feels seamless.

Deterministic regression tests should establish:

- A held size/status/branch/PR request is not canceled or duplicated by tab
  switching; its completion updates the same captured session.
- Project departure cancels read-only work, preserves completed cache, and
  rejects late completions without changing the new project's rows or busy UI.
- Refresh supersedes only affected work; canceled or pre-deletion results
  cannot overwrite newer inventory or resurrect a removed row.
- Worker/batch limits remain bounded during cancellation and rapid navigation.
  Hold old requests across replacement loads to distinguish per-load bounds
  from any new cross-generation occupancy guarantee.
- A blocked **synchronous fake** credential backend runs off-main: a main-actor
  heartbeat progresses before the fake is released. An async mock alone would
  not prove that the production blocking call moved off-main.
- Credential coalescing, denial, cancellation, sign-out versus save races,
  rotated tokens, and connection-settings rollback remain correct.
- Holding a credential save while an unrelated settings mutation completes
  must not overwrite that mutation when the credential operation resumes.
- A failed token save across multiple PR repositories/batches produces one
  automatic attempt, stops dependent authorization work, preserves cached PRs
  and the pending rotated token, and retries only after explicit user action.

A real permission-prompt test is separate and manual/opt-in. Do not lock the
user's Keychain, change ACLs, or manipulate real saved credentials automatically.
Profile app responsiveness without logging passwords, tokens, or query results.

## Implementation order

1. Async Keychain boundary, with responsiveness and persistence-ordering tests.
2. Project-owned jobs and independent operation states; no cancellation on tab
   switches, cancellation of read-only work on project departure.
3. UI-only baseline, committer-picker optimization if warranted, then retained
   pane hosts only if warm remount cost still justifies them.
4. End-to-end Release profiling and regression coverage for the behavior above.

No broader SwiftUI-to-AppKit rewrite, increased scan concurrency, or animation
workaround is justified by the evidence collected so far.

[swiftui-performance]: https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance
[wwdc23]: https://developer.apple.com/videos/play/wwdc2023/10160/
[identity]: https://developer.apple.com/videos/play/wwdc2021/10022/
[instruments]: https://developer.apple.com/videos/play/wwdc2025/306/
[responsiveness]: https://developer.apple.com/documentation/xcode/improving-app-responsiveness
[concurrency]: https://developer.apple.com/videos/play/wwdc2022/110350/
[keychain]: https://developer.apple.com/documentation/security/secitemcopymatching(_:_:)

Additional API references:
[SwiftUI TabView](https://developer.apple.com/documentation/swiftui/tabview),
[NSTabViewController](https://developer.apple.com/documentation/appkit/nstabviewcontroller),
and [Swift 6 concurrency guidance](https://developer.apple.com/videos/play/wwdc2025/268/).
