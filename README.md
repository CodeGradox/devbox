# DevBox

A native macOS app for managing Git worktrees, branches, and local MariaDB databases.
Requires **Apple Silicon (M1 or newer) and macOS 26 or newer**.

## Features

### Git worktrees

- Organize multiple projects and see their worktrees in one place.
- See Git status, merge status, and missing upstream branches.
- Open a branch's worktree in your preferred editor without switching branches.
- View worktree and project sizes without double-counting nested worktrees.
- Refresh an individual worktree's size or refresh the whole project.
- Filter worktrees to uncommitted or merged work, and click any column header to sort.
- Review cleanup suggestions for merged worktrees. Clean worktrees and worktrees with
  uncommitted changes are shown separately; deletion still requires confirmation.
- Compact rows keep names, changes, merge status, and disk usage visible together.
  Hover for full paths, Git status details, and file counts; click the project total for its breakdown.
- Delete selected worktrees together, removing their folders and registrations while keeping their branches.

### Git branches

- Select a project, then choose **Branches** to manage its local and remote-tracking branches.
- Filter local or remote branches and choose a committer from the loaded inventory. These
  filters combine with search by branch name, committer name, or email without fetching.
- Click **Branch**, **Latest commit date**, or **Committer** to sort; click again to reverse.
  Unknown dates stay last in either direction.
- See each branch's latest commit date and committer name/email. Git does not record a shared
  history of who last viewed or checked out a branch; these are commit details, not a usage audit.
- In the branch information popover, enable **Load committer icons from Gravatar** to request avatars using hashed commit emails.
  Icons are off by default; unavailable avatars use a local placeholder.
- Open branches on GitHub when a GitHub remote can be identified. Local branches need an
  existing configured upstream; unpublished branches do not get speculative links.
- Sign in to GitHub to see each branch's **Latest PR**, with a link and open, merged, or
  closed status. Latest means newest created, not most recently updated.
- **Refresh** rereads local refs. **Fetch & Prune** explicitly contacts the configured remotes
  to update remote-tracking refs and remove stale ones.
- Delete selected local branches, or delete branches from their remote server after explicit
  confirmation. Remote deletion affects all collaborators; it does not just hide a local row.

Checked-out branches, default branches, and unsafe or ambiguous remote configurations are
protected. Local deletion refuses unmerged branches unless **Force delete** is explicitly
enabled. Remote deletion checks the captured commit so it cannot remove a branch that has
advanced since the last fetch. Server permissions and branch protections still apply.

### GitHub sign-in and pull requests

Choose **Sign in to GitHub…** in the sidebar (or **GitHub Account…** in the File menu).
DevBox opens GitHub in your browser; enter the displayed code and authorize the app.
The GitHub App must be installed on the repositories you want to access, with
**Pull requests: Read-only**. Organization access may require administrator approval.

The branch list loads PRs for visible GitHub branches after sign-in. Local branches use
their existing upstream; local and remote rows for the same branch share a lookup.
For forks, DevBox checks the branch's repository and its parent repository. It matches
the exact source repository and branch name, rather than guessing from the branch name.
PRs targeting other repositories in a fork network are not included.

PRs load in GraphQL batches of up to 25 branches, with two batches at a time. Results
appear as batches finish; an individual lookup failure does not discard the other
branches' successful results. If GitHub throttles requests, DevBox waits until its
retry deadline before allowing another refresh.

Results are cached in memory. Use **Refresh PRs** (the pull-request icon beside
**Fetch & Prune**) to contact GitHub again; local **Refresh** and **Fetch & Prune** keep
their existing Git behavior. **No PR** means a successful lookup found none.
Click **Unavailable**, or the failure count in the footer, for repository-specific
errors, recovery steps, and retry. Signing in and installing the App are separate:
GitHub may return HTTP 404 for a private repository the App cannot access even when
you can open it in your browser. GitHub Enterprise hosts are not supported yet.

Access and refresh tokens stay in macOS Keychain and refresh automatically. Signing out
removes this Mac's saved credentials and cached PRs, but does not revoke authorization on
GitHub; use [GitHub application settings](https://github.com/settings/apps/authorizations)
to revoke it. No GitHub CLI, client secret, or private key is required.
Local Git and database features remain available without GitHub sign-in.

### MariaDB

- Connect to local MariaDB servers over TCP or a Unix socket.
- Store passwords securely in macOS Keychain.
- See estimated database sizes, data/index breakdowns, table and view counts, and estimated rows.
- Select databases to see their combined size and delete them in a batch.
- Follow each deletion's progress, elapsed time, and success or failure.

Results are cached while the app is open. Deletion updates the cache without
rescanning everything else; use **Refresh** (`⌘R`) when you want fresh values.
For fresh remote branch information, use **Fetch & Prune**.
Switching between **Worktrees** and **Branches** keeps jobs running and preserves
each tab's selection and scroll position. Switching projects cancels unfinished
read-only work but retains completed results; returning schedules the missing
work again. An explicit **Fetch & Prune** finishes in its original project.
Light, dark, and system appearance are supported.

**Deletion is permanent** and requires Touch ID or your Mac login password.
Main worktrees and system databases are protected. Reported sizes are not a
guarantee of how much disk space deletion will reclaim.

## Download

Get the app from the [latest release](https://github.com/CodeGradox/devbox/releases/latest):

- [DevBox-macos-arm64.dmg — Apple Silicon (M1 and newer)](https://github.com/CodeGradox/devbox/releases/latest/download/DevBox-macos-arm64.dmg)

Releases from v0.3.1 onward are Apple Silicon-only. The last Intel build remains
available in [v0.3.0](https://github.com/CodeGradox/devbox/releases/tag/v0.3.0).

### Install

1. Open **DevBox-macos-arm64.dmg**.
2. Drag **DevBox.app** onto the **Applications** shortcut.
3. Eject the DevBox disk image and open DevBox from **Applications**.

Releases starting with **v0.3.2** use **Developer ID signing and Apple notarization**
for both the app and disk image. The normal downloaded-app confirmation may
appear; **Open Anyway** should not be needed for these releases.

The optional `SHA256SUMS.txt` release asset is for verifying the download, not
installation. A GitHub Release downloads the DMG directly. Downloads from
**Actions → Artifacts** have an extra GitHub ZIP wrapper; unpack it to find the DMG.

Older releases through **v0.3.1** and historical ad-hoc CI artifacts are not
notarized. Current branch and pull-request CI runs tests only; signed downloads
are built and published only for new version tags.
Prefer a new signed release rather than disabling Gatekeeper.
Switching from an older build may prompt again for Keychain access.

## Getting started

Choose **Add Project…** to select a Git repository or one of its worktrees.
Choose **Add Connection…** to enter your local MariaDB connection details.

To edit a branch, select its worktree and use **Open With** in the toolbar,
right-click menu, or **Actions** menu. DevBox lists installed apps that advertise
folder support; choose **Other…** to select an app that isn't listed. After a
successful open, DevBox remembers that app as your preferred editor without
changing macOS's default folder handler.

The **Open in [editor]** action (`⇧⌘O`) and a row double-click use your preferred
editor. Zed is the initial default if installed; otherwise DevBox asks you to
choose an app. No editor command-line tool is required. This opens the existing
checkout, including the main checkout or a detached HEAD, without creating a
worktree or changing branches. Select only one worktree; bare repositories and
missing folders cannot be opened.

MariaDB features require an existing local server and its client library. If
DevBox reports that the client library is missing, install it and restart DevBox:

```sh
brew install mariadb-connector-c
```

Git features work without MariaDB.

For building from source or publishing releases, see the [developer guide](docs/github-releases.md).
For GitHub App registration and authentication details, see [GitHub integration](docs/github-integration.md).
