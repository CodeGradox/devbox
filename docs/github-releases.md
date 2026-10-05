# macOS builds and optional notarized downloads

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

`build.yml` runs for pull requests, pushes to `main`, and manual
dispatch. It runs `sh scripts/test.sh`, builds an optimized arm64 release app,
checks its architecture, deployment target, and ad hoc signature, and uploads
app and standalone-executable ZIPs plus SHA-256 checksums. Download them from
the Actions run's **Artifacts** section. Unpack the outer artifact archive,
then the inner `ditto` ZIP, which preserves executable permissions and app
metadata. The standalone executable is mainly useful for inspection; prefer
the app bundle for normal use.

Artifacts are explicitly labeled **adhoc-non-notarized**, expire after 14 days,
and are not GitHub Releases. They are not Apple-trusted distribution builds.
Normal tests inject in-memory credentials and do not need a user's Keychain,
MariaDB server, or database password. Database integration is deliberately
disabled by unsetting `DEVBOX_TEST_MARIADB_SOCKET`; the existing
`scripts/test-mariadb.sh` is a separate opt-in isolated integration script,
not part of these jobs.

Build jobs grant only `contents: read`, pin official checkout and upload
actions to full commit SHAs, and disable checkout credential persistence.
Only the opt-in signed-release publishing job gets `contents: write` and `actions: read`,
using GitHub's automatic short-lived token rather than a personal access token.
The pins were checked against GitHub's public tag API:

- [checkout v7.0.1](https://api.github.com/repos/actions/checkout/git/ref/tags/v7.0.1):
  `3d3c42e5aac5ba805825da76410c181273ba90b1`
- [upload-artifact v7.0.1](https://api.github.com/repos/actions/upload-artifact/git/ref/tags/v7.0.1):
  `043fb46d1a93c77aae656e7c1c64a875d1fc6a0a`

There is no `pull_request_target` or CI signing secret. Pull requests and ordinary
branch pushes cannot publish releases. Review action updates and verify replacement
SHAs before changing pins.

## Build or publish a signed release

Use **Actions → Release DevBox → Run workflow**, selecting **main**.
The workflow uses the protected `release` environment. It builds and verifies a
Developer ID-signed, notarized disk image, **DevBox-macos-arm64.dmg**.

- Leave **publish** unchecked (the default) to test a signed build without
  publishing. Download the **DevBox-macos-arm64** artifact from that run. GitHub
  wraps Actions artifacts in a ZIP containing the DMG and `SHA256SUMS.txt`;
  that wrapper is only for CI downloads.
- Check **publish** to create a GitHub Release after all signing, notarization,
  and packaging checks pass. Users download the DMG directly, without an outer
  ZIP or nested folders. The optional checksum file is a separate release asset.

Before publishing, update `CFBundleShortVersionString` and `CFBundleVersion` in
`Resources/Info.plist`, then commit/push to `main`. Use a fresh stable semantic
version (`MAJOR.MINOR.PATCH`). The publishing job creates `vVERSION` at the exact
build commit and refuses an existing tag. It never moves tags or replaces assets.
There is no need to create/push a tag manually; tag pushes no longer publish
ad-hoc downloads.

The publishing job uses ordinary `gh release` commands: download the signed
artifact from this exact run, verify its checksum, create a new tag and draft,
upload the DMG and checksum, then publish. No signing credentials are exposed
to this job. If uploading fails, the draft stays unpublished; recover that
unpublished draft manually or use a new version. There is no automatic overwrite
or draft-resume logic.

Selecting another branch or tag skips both signing and publishing. There is no
arbitrary checkout-ref input. Release assets have no Actions retention expiry.
Download from [the latest release](https://github.com/CodeGradox/devbox/releases/latest).
Existing releases through v0.3.1 remain ad-hoc signed; they are not replaced.

## Apple signing credentials

Before enabling it:

1. Protect `main` against deletion and force-pushes, and limit write access to
   trusted maintainers. Review workflow, script, entitlement, dependency, and
   application changes before signing them.
2. Create a GitHub environment named **release** and restrict deployment branches
   to **main only**. Add trusted required reviewers if appropriate for your team.
   Do not enable signing until the environment restrictions are configured.
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

6. Dispatch **Release DevBox** on `main`; reviewers should
   verify the exact run commit before approving environment access. Tests run
   before credentials are imported. The release step imports the supplied
   certificate into a temporary keychain and signs the app with hardened runtime
   and a secure timestamp. It packages the app with `dmgbuild`, signs the DMG,
   and submits that final distribution to Apple once. Apple checks the app inside
   too. Only an `Accepted` result allows stapling the DMG's ticket, validating it,
   and checking Gatekeeper. No Developer ID Installer certificate is needed.

Use the exact certificate name for `DEVBOX_SIGNING_IDENTITY`. A secret-only
correction can use **Re-run failed jobs** for signing. Script changes require a
new **Run workflow** after reaching `main`; rerunning an old run uses old code.

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
