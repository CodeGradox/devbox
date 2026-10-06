# macOS tests and signed releases

DevBox is a SwiftPM application: no Xcode project is needed. Building requires
Swift 6.2 or newer and a macOS 26 SDK; running requires **macOS 26 or newer**.
Supported releases require **Apple Silicon (arm64)**. The workflows use the native
`macos-26` runner, as listed in the
[GitHub runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).
They check the selected toolchain rather than silently accepting an older SDK.
Downloads are native arm64 apps, not universal binaries. Intel builds ended with
[v0.3.0](https://github.com/CodeGradox/devbox/releases/tag/v0.3.0); existing downloads remain available.

## Local tests

Run `make test`, or `sh scripts/test.sh --filter SomeTest` for a focused run.
Both CI workflows use the same script. It explicitly disables parallel test-case
scheduling: AppKit tests share `NSApplication` and the main run loop, and
`.serialized` on separate suites does not serialize those suites against each other.
Concurrency tests still start their own concurrent workers. No tests are skipped
and their time limits are unchanged.

App-store fixtures inject an inert editor launcher rather than querying the
machine's installed applications through `NSWorkspace`. This keeps cold-runner
editor discovery from blocking unrelated MainActor tests.

## Local visible-window check

On a logged-in macOS desktop, run:

```sh
DEVBOX_UI_TESTS=1 sh scripts/test.sh --filter 'BranchRenderingTests|WorktreeListRenderingTests'
```

This additionally captures only the test's own windows and verifies visible
sidebar, controls, and table-row text at minimum and default window widths.
It needs no Screen Recording permission and captures no other applications.
Ordinary bitmap/layout tests alone cannot detect a blank SwiftUI window.
Optionally set `DEVBOX_BRANCH_SCREENSHOT=/path/to/branches.png` to save the
captures as `branches.900.png` and `branches.1140.png`.

## Ordinary CI: no credentials

`tests.yml` (**macOS tests**) runs for pushes to every branch, including nested
names such as `feature/example`, for pull requests, and for manual dispatch.
Its explicit branch filter excludes tag pushes. It runs `sh scripts/test.sh`;
compiling the tests is the only build work. It does not package an app, sign,
notarize, upload artifacts, or publish a release.

This replaces the old ad-hoc build workflow. Historical runs and their artifacts
may remain visible until they expire, but no new ad-hoc downloads are produced.
Normal tests inject in-memory credentials and do not need a user's Keychain,
MariaDB server, or database password. Database integration is deliberately
disabled by unsetting `DEVBOX_TEST_MARIADB_SOCKET`; the existing
`scripts/test-mariadb.sh` is a separate opt-in isolated integration script,
not part of these jobs.

Test and release-build jobs grant only `contents: read` and disable checkout
credential persistence. Checkout and release-artifact upload actions are pinned
to full commit SHAs.
Only the tag-triggered publishing job gets `contents: write` and `actions: read`,
using GitHub's automatic short-lived token rather than a personal access token.
The pins were checked against GitHub's public tag API:

- [checkout v7.0.1](https://api.github.com/repos/actions/checkout/git/ref/tags/v7.0.1):
  `3d3c42e5aac5ba805825da76410c181273ba90b1`
- [upload-artifact v7.0.1](https://api.github.com/repos/actions/upload-artifact/git/ref/tags/v7.0.1):
  `043fb46d1a93c77aae656e7c1c64a875d1fc6a0a`

There is no `pull_request_target` or CI signing secret. Pull requests and ordinary
branch pushes cannot publish releases. Review action updates and verify replacement
SHAs before changing pins.

## Publish a tagged release

Only pushing a new version tag triggers the build and publishing jobs in
**Release DevBox**. Updating or deleting an existing tag does not rebuild it.
Normal branch pushes and pull requests run tests only; they do not create a DMG
or contact Apple's notary service. There is no manual release button or publish
checkbox. The release workflow reruns tests before importing signing credentials.

Update `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`,
commit/push to `main`, then tag that commit with a fresh stable version:

```sh
git switch main
GIT_EDITOR=true git tag -a v0.5.2 -m "DevBox v0.5.2"
git push origin refs/tags/v0.5.2
```

Use a new version for each release; do not move an existing tag. The workflow
requires `vMAJOR.MINOR.PATCH` to match the app's version and the tagged commit to
be in `main`'s history before building or using signing credentials.

The protected `release` job tests, builds, signs, and notarizes
**DevBox-macos-arm64.dmg**. On success, the publishing job automatically creates
the GitHub Release using the existing tag. Users download the DMG directly;
`SHA256SUMS.txt` is a separate optional asset. The same files are retained in the
run's **DevBox-macos-arm64** Actions artifact, which has GitHub's ZIP wrapper.

The publishing job uses ordinary `gh release` commands: download the signed
artifact from this exact run, verify its checksum, create a draft for the tag,
upload the DMG and checksum, then publish. No signing credentials are exposed
to this job. If uploading fails, the draft stays unpublished; recover that
unpublished draft manually or use a new version. There is no automatic overwrite
or draft-resume logic.

Before publishing, the job rechecks that the existing tag still points to the
exact signed commit. It never creates or moves tags, and it refuses to overwrite
an existing release. Release assets have no Actions retention expiry.
Download from [the latest release](https://github.com/CodeGradox/devbox/releases/latest).
Existing releases through v0.3.1 remain ad-hoc signed; they are not replaced.

## Apple signing credentials

Before enabling it:

1. Protect `main` against deletion and force-pushes, and limit write access to
   trusted maintainers. Review workflow, script, entitlement, dependency, and
   application changes before signing them.
2. In the GitHub environment named **release**, choose **Selected branches and
   tags**, add a **Tag** rule for `v*`, and remove the old **main branch** rule.
   Protect `v*` release tags against updates/deletion and allow only trusted
   maintainers to create them. Add trusted required reviewers if appropriate.
   Do not enable signing until these environment and tag protections are configured.
   A workflow's `if` guard alone is not a boundary against someone who can
   change a workflow on another branch.
3. Join the paid **Apple Developer Program**, or use your existing team's membership.
   In Apple's **Certificates, Identifiers & Profiles → Certificates → +**, choose
   **Developer ID Application** (not Developer ID Installer or Apple Development).
   Follow Apple's certificate-request steps: create a Certificate Signing Request
   with Keychain Access, upload the CSR, then download and install Apple's `.cer`.
   Your team Account Holder may need to create or authorize this certificate.
   In Keychain Access **My Certificates**, verify the certificate expands to show
   its private key. Export that identity **with its private key** as a
   password-protected `.p12`, using your secure credential-management process.
   The CSR alone, the downloaded public `.cer` alone, and your existing local
   self-signed certificate cannot sign a notarized public release.
4. Create an App Store Connect **team API key** authorized for notarization,
   and retain its `.p8` key, key ID, and issuer UUID. Use a key with only the
   required role/access. Do not commit any of these files or print them in logs.
5. Add the following **environment secrets**, not repository secrets:

| Secret | Value |
| --- | --- |
| `DEVBOX_CERTIFICATE_BASE64` | Single-line base64 of the `.p12` containing certificate and private key |
| `DEVBOX_CERTIFICATE_PASSWORD` | Password protecting that `.p12` |
| `DEVBOX_SIGNING_IDENTITY` | Exact identity, e.g. `Developer ID Application: Your Company (TEAMID)` |
| `DEVBOX_NOTARY_KEY_BASE64` | Single-line base64 of the App Store Connect `.p8` private key |
| `DEVBOX_NOTARY_KEY_ID` | App Store Connect key ID |
| `DEVBOX_NOTARY_ISSUER_ID` | App Store Connect issuer UUID |

Base64 is encoding, not encryption. Supply these directly through GitHub's
secret UI or your approved secret-management tooling; never paste them into
source files, issues, or this conversation.

6. Push a version tag from `main`; reviewers should
   verify the exact tagged commit before approving environment access. Tests run
   before credentials are imported. The release step imports the supplied
   certificate into a temporary keychain and signs the app with hardened runtime
   and a secure timestamp. It packages the app with `dmgbuild`, signs the DMG,
   and submits that final distribution to Apple once. Apple checks the app inside
   too. Only an `Accepted` result allows stapling the DMG's ticket, validating it,
   and checking Gatekeeper. No Developer ID Installer certificate is needed.

Use the exact certificate name for `DEVBOX_SIGNING_IDENTITY`. A secret-only
correction can use **Re-run failed jobs** for signing. Script changes require a
new version/tag after reaching `main`; rerunning an old tag uses old code.

The script traps exit/signals to remove its temporary keychain and credential
files, with an additional `always()` workflow cleanup step. Only ephemeral
GitHub-hosted runners are supported; forced machine termination ultimately
relies on runner disposal. Before creating its keychain, the script saves the
runner's user keychain search list. It prepends the temporary keychain for signing
and restores the saved list in its cleanup trap; existing keychains remain
searchable and the default keychain is not changed. This follows
[GitHub's runner signing setup](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications):
`codesign --keychain` alone is not sufficient runner setup, even when
`security find-identity` can find the identity in that keychain.
No raw credentials or notary response file is uploaded.
The checksum is computed from the final stapled DMG. If a signing/notary check
fails, the job does not upload a release artifact. Review the Apple submission
ID in the log and retrieve diagnostics through your approved developer tools.

## Local disk image packaging

The image opens with `DevBox.app` on the left and a shortcut to `/Applications`
on the right, with an arrow between them. Drag the app across, eject the image,
and launch DevBox from Applications. This is a file copy, not an installer package;
it does not install MariaDB or run privileged installation scripts.

Packaging uses the maintained [dmgbuild](https://dmgbuild.readthedocs.io/) tool,
without Finder or AppleScript. The only Python source is a small layout settings
file. Preparation needs Python 3.10+ and installs hash-locked tool dependencies
into a private virtual environment:

```sh
sh scripts/prepare-dmg-tools.sh
sh scripts/build-dmg.sh /path/to/DevBox.app /existing/output/directory/DevBox-macos-arm64.dmg
```

The default tools directory is `.build/dmg-tools`; when `BUILD_DIR` is set it is
`$BUILD_DIR/dmg-tools`. `DMG_TOOLS_DIR` can override it. Use the same settings for
preparation and packaging. In CI, preparation and a real fixture-image test run
**before** signing secrets are imported; packaging itself performs no downloads.
The packager never signs or changes the source app, refuses existing output
files, and mounts the finished image to verify the app signature and Applications
shortcut. Its local output is an **unsigned DMG**, not a verified public release.

To build and inspect a real image containing an ad-hoc-signed fixture, without
private signing keys or contacting the notarization service:

```sh
sh scripts/prepare-dmg-tools.sh
sh scripts/test-dmg.sh
```

## Gatekeeper, Keychain, and MariaDB

- **Ad hoc signing** detects modifications but does not establish a trusted
  developer identity. Download quarantine may cause Gatekeeper to block CI
  artifacts. Do not disable Gatekeeper globally; use a notarized build for
  distribution. `codesign --verify` succeeding is not notarization.
- **Developer ID + notarization** establish Apple's distribution trust, not
  permission to read existing passwords. Keychain access follows the app's
  signing identity/designated requirement and item access rules. Switching
  between local, ad hoc, and Developer ID builds may prompt again or require
  re-entering a password. Notarization does not bypass authentication prompts.
- The app dynamically loads an **external Homebrew MariaDB client library**.
  Neither CI archives nor the disk image install the library or a database
  server. Install a compatible native MariaDB connector (for example
  `brew install mariadb-connector-c`) or supported MariaDB server package and
  configure the local database separately. Native Apple Silicon Homebrew normally
  uses `/opt/homebrew`. The client library must be arm64 to
  match the app. The app's database diagnostics explain missing-library cases.
- Developer ID builds use only
  `com.apple.security.cs.disable-library-validation` as a hardened-runtime
  exception, because Homebrew's dylib is not signed by the DevBox team. This
  permits loading differently signed code; it is not limited to one pathname.
  Keep the Homebrew installation trusted and writable only by trusted users.
  No JIT, unsigned executable memory, sandbox, or debugging entitlement is added.
  Bundling and signing a fixed client library could remove this exception in
  a future packaging change, but is not implemented here.

## Local builds and icons

The local signing default remains `Devbox Local Development`. For an isolated
ad hoc build, use paths outside any running app bundle:

```sh
CONFIGURATION=release DEVBOX_SIGNING_IDENTITY=- \
  BUILD_DIR="$PWD/build/ci-check" SWIFT_BUILD_PATH="$PWD/.build/ci-check" \
  sh scripts/build-app.sh
```

`BUILD_DIR` controls the directory containing `DevBox.app`; `SWIFT_BUILD_PATH`
controls SwiftPM intermediates. Use absolute paths to avoid ambiguity.
If `Resources/DevBox.png` exists, the app builder runs `scripts/build-icon.sh`
and fails on an invalid source. Otherwise it copies `Resources/DevBox.icns`
when present. It updates only the bundled copy of `Info.plist` with
`CFBundleIconFile=DevBox`; without either asset it builds without a custom icon.
The repository includes the supplied logo prepared with libvips. To replace it,
run `sh scripts/optimize-icon.sh /path/to/original.png Resources/DevBox.png`.
This one-time optimization preserves full-color transparency and strips metadata;
CI does not need libvips. No replacement artwork is generated when the asset is absent.

## Verification boundaries

Local validation can check shell syntax, workflow structure, tests, ad hoc
signatures, deployment target, and ZIP round-trip permissions. Both native
GitHub runner jobs still need to be exercised in the repository. Developer ID
import, timestamping, Apple notarization, stapling, and downloaded-app
Gatekeeper/Keychain behavior require configured credentials and deliberate
release approval; they cannot be established by an ad hoc local build.
