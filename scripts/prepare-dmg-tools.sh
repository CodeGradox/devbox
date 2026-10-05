#!/bin/sh
# Run before importing signing credentials. Packaging itself never uses the network.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TOOLS=${DMG_TOOLS_DIR:-${BUILD_DIR:-"$ROOT/.build"}/dmg-tools}
if [ "$(uname -s)" != Darwin ]; then
    echo "DMG tools require macOS." >&2
    exit 1
fi
python3 -m venv "$TOOLS"
"$TOOLS/bin/python3" -m pip --isolated install --disable-pip-version-check \
    --require-hashes --only-binary=:all: -r "$ROOT/scripts/dmg-requirements.txt"
