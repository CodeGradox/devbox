# DevBox

A native macOS utility for Git worktrees and local MariaDB databases, built with
Swift and SwiftUI. Requires macOS 26 or newer.

## Build and run

Install Xcode 26 or newer (or Swift 6.2 or newer with the macOS 26 SDK), then from this repository:

```sh
make build
make run
```

`make build` creates an optimized release build by default (`CONFIGURATION=release`).
`make run` builds, then opens `build/DevBox.app`; it does not quit an already-running
instance. Quit DevBox yourself before running again to ensure the rebuilt app is used.

The build script signs the app with **`Devbox Local Development`** by default.
Create this code-signing identity in your login Keychain before building, or supply
another identity as described below. There are no downloaded Swift
package dependencies. You can also open `Package.swift` in Xcode to work on the app.
Use the bundled `.app` for normal use, including Keychain and macOS authentication.

For a debug build:

```sh
make run CONFIGURATION=debug
```

Calling `sh scripts/build-app.sh` directly still defaults to debug; set
`CONFIGURATION=release` explicitly when using the script for an optimized build.

Reuse the same certificate across builds so Keychain can recognize DevBox's stable
signing identity. Moving from an ad-hoc build to certificate signing can cause one
more access prompt; choose **Always Allow** for the newly signed app.

Override the signing identity when needed:

```sh
DEVBOX_SIGNING_IDENTITY="Your Code Signing Certificate" make build
```

Signing fails if the selected identity is unavailable; it never silently falls back
to ad-hoc signing. An explicit `DEVBOX_SIGNING_IDENTITY=- make build` is available
for machines without a certificate, but those rebuilds may prompt for Keychain access
again. `make test` does not require the app's signing certificate.

The local self-signed certificate is not a distribution identity. Sharing a trusted,
notarized app still requires an Apple-issued Developer ID certificate and notarization.

### GitHub Actions builds

The [macOS build workflow](.github/workflows/build.yml) tests and packages native
Apple Silicon and Intel apps on macOS 26. Download the architecture-specific ZIP
from a successful run's **Artifacts** section. These CI builds are explicitly
ad-hoc signed, not notarized, and need no signing secrets.

For trusted public downloads, use the optional signed-release workflow and follow
[the GitHub signing setup](docs/github-releases.md). You need an **Apple-issued
Developer ID Application** certificate from the paid Apple Developer Program,
not another locally generated certificate. Private signing and notarization keys
belong in a protected GitHub Actions environment, never in this repository.
The local `Devbox Local Development` identity remains the default for local builds.

### App icon

The supplied logo is stored at `Resources/DevBox.png`, optimized with libvips to
1024 × 1024, full-color RGBA, with unnecessary metadata removed. To replace it:

```sh
brew install vips
sh scripts/optimize-icon.sh /path/to/original-logo.png Resources/DevBox.png
```

Use a square original at least 1024 × 1024 pixels. The optimizer downsizes to 1024,
converts to sRGB, and uses lossless PNG compression without palette quantization.
The normal build runs `scripts/build-icon.sh` to generate all macOS icon sizes
and a `DevBox.icns` inside the app bundle. It preserves the artwork and transparency,
without cropping or stretching. Normal builds/CI use Apple's bundled tools and
do not require libvips to be installed.

### MariaDB client library

DevBox loads MariaDB Connector/C at runtime. It supports the standard Apple Silicon
and Intel Homebrew locations for both `mariadb-connector-c` and the connector bundled
with `mariadb`. If neither is installed:

```sh
brew install mariadb-connector-c
```

Restart DevBox after installing the library. Git features work without it.
An existing MariaDB server is required; DevBox does not start or configure your server.

## Using v0

### Appearance

Use the **System / Light / Dark** picker at the bottom of the sidebar, or
**View → Appearance** when the sidebar is hidden. The selection is remembered in
the app's preferences and applies to windows and dialogs. **System** is the default
and follows changes to macOS appearance automatically.

### Projects

- **Add Project…** (`⌘O`) accepts one or more repository folders or linked worktrees.
  Repositories are deduplicated by their shared Git directory.
- Select a project in the sidebar to discover all its registered worktrees.
- The table shows branches, staged/modified/untracked/conflicted file counts,
  allocated disk usage, and file counts.
- Git status, branch comparisons, and sizes are cached **in memory for the current app session**.
  Switching back to a project restores its results immediately without rescanning
  completed work. Interrupted scans resume only what has not finished.
  Measurements are not persisted: reopening DevBox scans each project again when first selected.
- Disk usage uses native macOS FTS traversal, calculating allocated bytes and file
  count in one pass without normalizing every file's path.
- Use **Refresh** (`⌘R`) to update Git status and all worktree measurements.
  Size scans run off the main thread, independently of Git status, with at most
  four scans at once, including the shared Git-storage scan. Each scan uses one FTS traversal.
- Click the **refresh arrow next to a worktree's disk usage**, or right-click it
  and choose **Refresh Disk Usage**, to update only that row's size and file count.
  The previous result stays visible while it updates. Queued/scanning states and
  failed updates are explicit; hover over the size to see its measurement time.
- Size scans do not block deletion once Git status has loaded. Preparing a deletion
  cancels scans of the selected folders; changing project cancels obsolete scans.
- Right-click a worktree to open it in Finder or copy its path.
- **Remove from Sidebar** only forgets a project. It does not delete files.

#### Merge status

The **Merge Status** column distinguishes ancestry-proven **Merged**, **Not merged**,
the **Comparison base**, and **Unknown**. The default comparison is the main checkout's
captured HEAD, even when the project was added from another worktree.

The **Merge target** picker can choose a local or remote-tracking branch instead.
That preference is saved per project; changing it updates branch comparisons without
repeating completed size scans. The chosen target is displayed above the table.

**Upstream gone** is an independent badge, matching `gprune`'s additional cleanup
signal. A missing configured upstream is not proof of a merge or squash merge.
No-upstream branches are not marked gone. These checks use local history/refs only:
the app does not fetch or prune. Shallow, missing, or changing history can produce
**Unknown** rather than an unsupported “not merged” claim.

Merge status and cleanliness are independent. Neither automatically authorizes a deletion.

#### Project size

Each row reports **exclusive** worktree contents: registered worktrees nested under it
are measured in their own rows, not again in the parent. This uses Git's inventory,
not a special rule for folders named `.worktrees`; ordinary files and unregistered
folders inside `.worktrees` still count.

The project header and sidebar show **exclusive worktree sizes + shared Git storage
once**. The header breaks out both components and labels in-progress or incomplete
totals instead of treating missing measurements as zero. Bare repositories contribute
their Git storage but have no checkout contents.

Full Refresh rediscovers the worktree boundaries and remeasures Git storage.
Per-row refresh uses that inventory snapshot. If a boundary changes, old measurements
for the affected parent are discarded rather than mixed into the new total.

Select multiple rows with Command-click or Shift-click. Selection never carries
between projects. **Delete Selected…** shows the exact batch and data-loss warnings,
requires acknowledgement that all folder contents will be lost, then asks macOS
for Touch ID or your login password.

Deletion uses `git worktree remove`, including `--force` only after the explicit
data-loss confirmation. It removes the folder and registration, but **keeps the
branch**. Main, bare, locked, and missing worktrees are protected. A worktree containing
another registered worktree is also protected: remove the children first and refresh.
Git identity, branch, HEAD, lock state, and nested registrations are rechecked before removal. There is
no recursive-delete fallback. Git may refuse checkouts containing submodules;
DevBox reports that error rather than bypassing Git's protection.

Missing registrations can be cleaned up with Git outside the app; v0 does not
automatically prune them or unlock worktrees.

### MariaDB

- **Add Connection…** creates a named local connection.
- The default endpoint is `127.0.0.1:3306`. `localhost` explicitly uses loopback TCP;
  choose **Unix Socket** to supply an absolute socket path.
- Enter your MariaDB username/password, optionally test the connection, then save.
  Empty passwords are supported for accounts that permit them.
- Passwords are stored in **macOS Keychain**. Connection settings contain no passwords.
- The table lists databases visible to that account, then loads metadata in the
  background: **estimated size**, its **data/index breakdown**, **table and view
  counts**, and **estimated rows**. The inventory remains usable while statistics load.
- The header shows the estimated total; selecting databases shows a selected total
  in the footer and deletion confirmation. Hover over a size for its timestamp,
  breakdown, and any error. Missing values display `—`, not zero. Failed updates
  preserve the last successful estimate with an explicit warning and partial total.
- Database lists and statistics are cached **only for the app session**. Switching
  connections reuses completed results without another Keychain lookup. **Refresh**
  (`⌘R`) reloads both; reopening the app or editing a connection invalidates the
  relevant snapshot. Interrupted metadata loads resume on return.
  Confirmed deletions remove only their cached rows and recompute totals from the
  retained measurements. No post-deletion refresh is started, for databases or
  worktrees; other sizes, Git statuses, and shared Git storage stay cached until
  manual refresh. Failed or uncertain deletions remain listed.
- Statistics use one batched `INFORMATION_SCHEMA` read, not a full-table `COUNT(*)`,
  `ANALYZE`, or a scan of the server's files. They describe **visible base and
  system-versioned tables**; views count separately. Sequence storage contributes
  bytes, but not user-table or user-row counts.
  An empty visible schema reports zero; a restricted account may see only part of
  a database. InnoDB rows/sizes can be approximate, MEMORY tables describe memory,
  and shared/unattributed free space and logs are not added to these totals.
  **Estimated size is not guaranteed space reclaimed by deletion.**
- Select databases and choose **Delete Selected…**. Review the names/server, then
  authenticate with Touch ID or your Mac login password.
- Deletion runs **one item at a time**. Each row shows **Queued**, **Deleting**
  (with a spinner), **Completed**, or **Failed**, and errors stay beside that item.
  Attempted deletions show elapsed time, including time waiting for the server;
  the batch shows completed/failed counts, not a speculative per-database percentage.
  The same indicators and timing are used for worktree deletion and in the final results.

`mysql`, `information_schema`, `performance_schema`, and `sys` are protected.
Authentication authorizes only the reviewed batch; it does not provide MariaDB
privileges. The database account must already have the necessary permissions.
Removing a connection from the sidebar forgets its settings and saved password;
it does not change the server.

### Safety and limits

- Deletes are permanent. There is no Trash integration, automatic backup, or undo.
- Authentication cancellation/failure starts no deletion.
- Bulk operations are not atomic. Results are reported per item, including partial
  failures. A lost connection during a database delete is marked **Uncertain**:
  MariaDB may still be processing it or may have completed it. The batch stops and
  remaining items are marked **Not attempted**. Nothing is automatically retried;
  check the server and refresh before submitting another deletion.
- Do not mutate selected worktrees or replace database servers while a deletion
  is in progress. External changes cannot be made atomic with the app's checks.
- Disk usage includes ignored/build files, excludes `.git` metadata, and never
  follows symlink targets. Unreadable entries are marked as partial measurements.
  Scans stay on the root filesystem; dataless cloud directories are skipped and
  marked partial rather than expanded. Hard-linked file entries are counted separately.
  APFS sharing/compression means reported usage is not guaranteed reclaimed space.
- External Git/filesystem changes appear after an explicit refresh (`⌘R`), not by
  switching away and back. Session caches are cleared on quit. The app does not
  watch the filesystem or fetch Git remotes.
- v0 discovers and deletes existing worktrees/databases. Creation, database cloning,
  backups, SQL browsing, and automatic worktree/database associations are not included.
- Connections are local only. Remote servers and TLS settings are not exposed.
- The app is intentionally not App-Sandboxed: it manages user-selected folders and
  invokes the installed Git. No telemetry or cloud service is used.

## Storage

Non-secret settings:

```text
~/Library/Application Support/DevBox/settings.json
```

Keychain generic-password service: `app.devbox.mariadb`, keyed by connection UUID.
The app uses Apple's Security and LocalAuthentication frameworks; it never receives
your Mac login password.

`.gitignore` also excludes local environment files, exported keys/signing identities,
database dumps, local database files, and logs. Sanitized `.env.example` files can
be tracked. Ignore rules are a safeguard against accidental additions, not a secret
scanner and not a way to remove secrets already committed.

## Tests

```sh
make test
make test-mariadb
```

These delegate to `swift test` and `sh scripts/test-mariadb.sh`, respectively.

The normal suite covers temporary Git repositories, unusual path characters,
status parsing, symlink/ignored-file disk scans, removal safeguards, MariaDB
validation/identifier quoting, authentication cancellation, settings rollback,
selection isolation, and modal result handoff. It also tests Observation dependencies
across 200 rows, stable identities during refresh, and environment-free native table
rendering. These are correctness/scope tests, not a frame-rate benchmark.
It does not access personal Keychain
entries or contact an existing MariaDB instance.

The second command requires Homebrew MariaDB server tools. It initializes an isolated
server under `.build`, disables networking and default configuration, verifies real
connection/list/drop behavior, then stops its own server and removes test data.
The integration test is skipped in the normal suite unless explicitly configured.

### Opt-in directory-size benchmark

```sh
make benchmark
make benchmark BENCH_FILES=2000 BENCH_RUNS=3
```

Defaults are `BENCH_FILES=50000` and `BENCH_RUNS=5` (positive integers). The standalone
Swift executable is compiled with `swiftc -O -swift-version 6`, not run as a timing
test in `swift test`. It generates a fresh Git repository with many small files and
compares the prior Foundation enumeration loop with production
`GitService.diskUsage` (native FTS, including its Git metadata lookup).
Both modes must agree on file counts and allocated bytes with no unreadable entries.

Setup and one warm-up per mode are untimed. Measured scans run sequentially in
alternating order, reporting each wall time plus median and range. This is a
synthetic warm-cache comparison, not a concurrency benchmark or a promise about
all repositories or filesystems. No private repositories or databases are accessed.
The fixture, executable, and compiler cache live in a fresh directory beneath
`.build`; the script's exit/signal trap removes only that directory.

Manual acceptance checks for a signed build:

1. Add two projects; select rows and switch projects to verify selection isolation.
2. Refresh a project with dirty, clean, locked, and missing worktrees.
3. Cancel a deletion at confirmation and at the macOS authentication prompt.
4. Authenticate deletion of disposable linked worktrees; verify branches remain.
5. Save/reopen a disposable local database connection to exercise Keychain.
6. Delete disposable databases and verify per-item results.
7. Check keyboard navigation, VoiceOver, and light/dark appearances.
8. Refresh a large project while scrolling/selecting; verify cached rows remain
   visible and the branch picker does not react to unrelated size updates.

### UI responsiveness and profiling

The interface uses Swift Observation (`@Observable`) with session-owned project
models and stable row objects. A row result does not replace the table's collection
or copy it into a second cache. Display text, project totals, and branch-picker
options are prepared when their inputs change, not during unrelated view updates.
Bulk inventory/loading transitions coalesce summary calculation into one update.
Cached content remains visible during refresh.

Git process waits and FTS traversal use a bounded blocking-I/O executor bridged
through checked continuations. They do not run on the main actor or hold up Swift's
cooperative task pool while waiting for disk/process I/O. Cancellation retains
occupied slots until the blocking operation actually exits. UI state remains
main-actor isolated; no unbounded worker/task fan-out is used.

To investigate real interaction lag, build with `make build`, attach Instruments'
**SwiftUI** template to DevBox, and record a refresh while scrolling and switching
projects. Inspect **Update Groups**, **Cause & Effect**, **Time Profiler**, and
**Hangs/Hitches**. Project-state signposts (`app.devbox.DevBox`, `Project state`)
mark inventory reconciliation and size-summary updates. The filesystem benchmark
does not measure UI frame time.

## Structure

- `Sources/DevBox`: SwiftUI interface, app state, Keychain, settings, authentication.
- `Sources/DevBoxCore`: UI-independent Git/filesystem and MariaDB services.
- `Tests`: Git, database, and app-state tests.
- `Resources/Info.plist`: application bundle metadata.
- `scripts`: repeatable local packaging and isolated database verification.
