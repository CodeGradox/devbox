#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-signing-identity.py

# AppKit suites share NSApplication and the main run loop. A suite's .serialized
# trait does not serialize sibling suites, so run test cases serially as well.
# Tests still exercise their own concurrent workers; no coverage or timeouts change.
if [ -n "${SWIFT_BUILD_PATH:-}" ]; then
    set -- --scratch-path "$SWIFT_BUILD_PATH" "$@"
fi
exec swift test --no-parallel "$@"
