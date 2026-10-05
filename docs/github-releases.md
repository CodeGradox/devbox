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

`build.yml` runs for pull requests, pushes to `main`, `v*` tags, and manual
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

## Version tags publish downloads

After the native arm64 build and tests succeed, a push of a stable version tag
(`vMAJOR.MINOR.PATCH`) publishes the app ZIP and its `SHA256SUMS.txt`
to a GitHub Release. The job downloads only artifacts from that same workflow run
and checks their hashes before uploading. It publishes from a draft only after
all assets have uploaded successfully; failed uploads leave an unpublished draft.
A retry may finish a draft for the same commit but never overwrite a published release.

Before tagging, update `CFBundleShortVersionString` in `Resources/Info.plist`
and commit/push it. The workflow verifies that the tag matches the app's version:

```sh
git tag -a v0.1.0 -m "DevBox v0.1.0"
git push origin refs/tags/v0.1.0
```

For later releases use a new version; do not move an existing release tag.
Download from [the latest release](https://github.com/CodeGradox/devbox/releases/latest)
or the README's Apple Silicon link. Release assets have no Actions
retention expiry or extra artifact-wrapper ZIP. Private repositories still require
GitHub authentication/access; this workflow never changes repository visibility.
These downloads remain **ad-hoc signed and non-notarized**.

## Optional Apple-trusted manual build

`release.yml` is a real, opt-in signing and notarization workflow. It only runs
via **Run workflow** on `main`, uses the protected `release` environment, and
uploads stapled app archives; it does **not** create or publish GitHub Releases.
There is no arbitrary checkout-ref input. Selecting any other branch or tag
skips the signing job. It signs the native arm64 app.

Before enabling it:

1. Protect `main` with review requirements, especially changes to workflows,
   scripts, entitlements, package manifests, and application source.
2. Create a GitHub environment named **release**. Require trusted reviewers,
   prevent self-review where available, and restrict deployment branches to
   **main only**. Do not enable signing until these protections are configured.
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

6. Dispatch **Manual Developer ID notarized apps** on `main`; reviewers should
   verify the exact run commit before approving environment access. Tests run
   before credentials are imported. The release step imports the supplied
   certificate into a temporary runner keychain. Before building, it checks for
   exactly one valid code-signing certificate matching `DEVBOX_SIGNING_IDENTITY`
   in that keychain, accepting canonically equivalent Unicode names. It signs by
   the matching certificate's SHA-1 fingerprint to avoid name-lookup ambiguity,
   retaining hardened runtime and a secure timestamp. It then submits to Apple,
   requires an `Accepted` result, staples the ticket, and checks Gatekeeper
   assessment.

An import reporting `1 identity imported` does not prove the `.p12` contains the
expected, valid Developer ID identity. The preflight distinguishes an unusable
identity, a local/non-Developer-ID certificate, a name/team mismatch, and multiple
matching certificates without logging the imported names or private credentials.
Follow the reported category: fix mismatched `release` environment secrets, or
investigate certificate validity, trust, and keychain access if no valid identity
can be found. Do not switch to an arbitrary available certificate. A secret-only
correction can use **Re-run failed jobs**. Changes to the scripts require a new
**Run workflow** after those changes reach `main`; rerunning an old run uses its
original commit.

The script traps exit/signals to remove its temporary keychain and credential
files, with an additional `always()` workflow cleanup step. Only ephemeral
GitHub-hosted runners are supported; forced machine termination ultimately
relies on runner disposal. The runner's normal/default keychain is not replaced.
No raw credentials, submission ZIP, or notary response file is uploaded.
The downloaded app is re-zipped **after** stapling. If a signing/notary check
fails, the job does not upload a release artifact. Review the Apple submission
ID in the log and retrieve diagnostics through your approved developer tools.

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
  Neither archive bundles or downloads this library, nor installs/starts a
  database server. Install a compatible native MariaDB connector (for example
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
