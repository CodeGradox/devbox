# DevBox

A native macOS app for managing Git worktrees and local MariaDB databases.
Requires **macOS 26 or newer**.

## Features

### Git worktrees

- Organize multiple projects and see their worktrees in one place.
- See Git status, merge status, and missing upstream branches.
- Open a branch's worktree in your preferred editor without switching branches.
- View worktree and project sizes without double-counting nested worktrees.
- Refresh an individual worktree's size or refresh the whole project.
- Delete selected worktrees together, removing their folders and registrations while keeping their branches.

### MariaDB

- Connect to local MariaDB servers over TCP or a Unix socket.
- Store passwords securely in macOS Keychain.
- See estimated database sizes, data/index breakdowns, table and view counts, and estimated rows.
- Select databases to see their combined size and delete them in a batch.
- Follow each deletion's progress, elapsed time, and success or failure.

Results are cached while the app is open. Deletion updates the cache without
rescanning everything else; use **Refresh** (`⌘R`) when you want fresh values.
Light, dark, and system appearance are supported.

**Deletion is permanent** and requires Touch ID or your Mac login password.
Main worktrees and system databases are protected. Reported sizes are not a
guarantee of how much disk space deletion will reclaim.

## Download

Get the app from the [latest release](https://github.com/CodeGradox/devbox/releases/latest):

- [Apple Silicon (M1 and newer)](https://github.com/CodeGradox/devbox/releases/latest/download/DevBox-macos26-arm64-adhoc-non-notarized-app.zip)
- [Intel](https://github.com/CodeGradox/devbox/releases/latest/download/DevBox-macos26-x86_64-adhoc-non-notarized-app.zip)

Unzip the download and move **DevBox.app** into **Applications**.
If the repository is private, you need GitHub access to download it.

### Opening it for the first time

The downloads are **ad-hoc signed, not Apple-notarized**. macOS may show:

> Apple could not verify “DevBox.app” is free of malware…

For a build you trust from this repository:

1. Click **Done** in that popup—not **Move to Bin**.
2. Open **System Settings → Privacy & Security**.
3. Scroll down to **Security** and find the message that DevBox was blocked.
4. Click **Open Anyway**, confirm, and authenticate if asked.

**Open Anyway is in System Settings, not in the warning popup.** This approves
the app locally without disabling Gatekeeper. A new build may need approval again.

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
