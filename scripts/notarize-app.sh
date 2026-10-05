#!/bin/sh
# Explicit release operation: imports supplied credentials and contacts Apple.
set -eu
cd "$(dirname "$0")/.."
: "${RUNNER_TEMP:?Run on an ephemeral release runner}"
: "${BUILD_DIR:?}"
: "${DEVBOX_CERTIFICATE_BASE64:?}"
: "${DEVBOX_CERTIFICATE_PASSWORD:?}"
: "${DEVBOX_SIGNING_IDENTITY:?}"
: "${DEVBOX_NOTARY_KEY_BASE64:?}"
: "${DEVBOX_NOTARY_KEY_ID:?}"
: "${DEVBOX_NOTARY_ISSUER_ID:?}"
case "$DEVBOX_SIGNING_IDENTITY" in
    "Developer ID Application:"*) ;;
    *) echo "An Apple-issued Developer ID Application identity is required." >&2; exit 1 ;;
esac

umask 077
credentials="$(mktemp -d "$RUNNER_TEMP/devbox-signing.XXXXXX")"
DEVBOX_SIGNING_KEYCHAIN="$credentials/release.keychain-db"
export DEVBOX_SIGNING_KEYCHAIN
set_keychain_search_list() {
    # Keep paths as separate arguments, including spaces, quotes and Unicode.
    # Extra arguments are prepended; no arguments restores the saved list.
    python3 - "$credentials/keychain-search-list.json" "$@" <<'PY'
import json, subprocess, sys
from pathlib import Path
original = json.loads(Path(sys.argv[1]).read_text())
subprocess.run(
    ["security", "list-keychains", "-d", "user", "-s", *sys.argv[2:], *original],
    check=True,
)
PY
}
cleanup() {
    if [ -f "$credentials/keychain-search-list.json" ]; then
        set_keychain_search_list >/dev/null 2>&1 ||
            printf 'Warning: could not restore the runner keychain search list.\n' >&2
    fi
    security delete-keychain "$DEVBOX_SIGNING_KEYCHAIN" >/dev/null 2>&1 || true
    rm -rf "$credentials"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
export DEVBOX_CREDENTIALS_DIRECTORY="$credentials"
python3 - <<'PY'
import base64, json, os, shlex, subprocess
from pathlib import Path
directory = Path(os.environ["DEVBOX_CREDENTIALS_DIRECTORY"])
for variable, filename in [
    ("DEVBOX_CERTIFICATE_BASE64", "certificate.p12"),
    ("DEVBOX_NOTARY_KEY_BASE64", "notary.p8"),
]:
    (directory / filename).write_bytes(base64.b64decode(os.environ[variable], validate=True))
# Snapshot before create-keychain, which may itself change the search list.
# Do not create the snapshot file if inspecting the original list fails.
original = shlex.split(subprocess.check_output(
    ["security", "list-keychains", "-d", "user"], text=True,
))
(directory / "keychain-search-list.json").write_text(json.dumps(original))
PY
keychain_password="$(openssl rand -hex 32)"
security create-keychain -p "$keychain_password" "$DEVBOX_SIGNING_KEYCHAIN"
security set-keychain-settings -lut 21600 "$DEVBOX_SIGNING_KEYCHAIN"
security unlock-keychain -p "$keychain_password" "$DEVBOX_SIGNING_KEYCHAIN"
security import "$credentials/certificate.p12" -k "$DEVBOX_SIGNING_KEYCHAIN" \
    -P "$DEVBOX_CERTIFICATE_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
    -k "$keychain_password" "$DEVBOX_SIGNING_KEYCHAIN" >/dev/null
# codesign needs the identity's keychain on the user search list even when an
# explicit --keychain limits certificate selection. Keep existing chain sources.
set_keychain_search_list "$DEVBOX_SIGNING_KEYCHAIN"
CONFIGURATION=release sh scripts/build-app.sh
app="$BUILD_DIR/DevBox.app"
codesign --verify --deep --strict --verbose=2 "$app"
codesign -dv --verbose=4 "$app" 2>&1 | grep -F 'Authority=Developer ID Application:'
codesign -dv --verbose=4 "$app" 2>&1 | grep -F 'runtime'
codesign -dv --verbose=4 "$app" 2>&1 | grep -F 'Timestamp='
ditto -c -k --sequesterRsrc --keepParent "$app" "$credentials/submission.zip"
xcrun notarytool submit "$credentials/submission.zip" \
    --key "$credentials/notary.p8" --key-id "$DEVBOX_NOTARY_KEY_ID" \
    --issuer "$DEVBOX_NOTARY_ISSUER_ID" --wait --output-format json > "$credentials/result.json"
python3 - "$credentials/result.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
print("Notarization:", result.get("id"), result.get("status"))
if result.get("status") != "Accepted":
    raise SystemExit("Apple did not accept this submission; no release artifact will be uploaded.")
PY
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"
