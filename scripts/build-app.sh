#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

configuration="${CONFIGURATION:-debug}"
signing_identity="${DEVBOX_SIGNING_IDENTITY:-Devbox Local Development}"
swift build -c "$configuration"
binary_directory="$(swift build -c "$configuration" --show-bin-path)"
app="$PWD/build/DevBox.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_directory/DevBox" "$app/Contents/MacOS/DevBox"
cp Resources/Info.plist "$app/Contents/Info.plist"
# Local development signing. Release distribution needs a Developer ID and notarization.
printf 'Signing with %s\n' "$signing_identity"
codesign --force --sign "$signing_identity" "$app"
codesign --verify --strict "$app"
printf '\nBuilt %s\nLaunch with: open "%s"\n' "$app" "$app"
