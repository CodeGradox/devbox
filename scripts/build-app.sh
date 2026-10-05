#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

configuration="${CONFIGURATION:-debug}"
signing_identity="${DEVBOX_SIGNING_IDENTITY:-Devbox Local Development}"
build_directory="${BUILD_DIR:-$PWD/build}"
swift_build_path="${SWIFT_BUILD_PATH:-$PWD/.build}"
# Resolve only the configured Developer ID, before spending time on the build.
# codesign accepts a certificate fingerprint, avoiding its name-matching behavior.
signing_certificate="$signing_identity"
case "$signing_identity" in
    "Developer ID Application:"*)
        signing_certificate="$(python3 scripts/signing_identity.py)"
        printf 'Validated the configured Developer ID signing identity.\n'
        ;;
esac
swift build --scratch-path "$swift_build_path" -c "$configuration"
binary_directory="$(swift build --scratch-path "$swift_build_path" -c "$configuration" --show-bin-path)"
app="$build_directory/DevBox.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_directory/DevBox" "$app/Contents/MacOS/DevBox"
cp Resources/Info.plist "$app/Contents/Info.plist"
# Local development signing. Release distribution needs a Developer ID and notarization.
rm -f "$app/Contents/Resources/DevBox.icns"
if [ -f Resources/DevBox.png ]; then
    sh scripts/build-icon.sh Resources/DevBox.png "$app/Contents/Resources/DevBox.icns"
elif [ -f Resources/DevBox.icns ]; then
    cp Resources/DevBox.icns "$app/Contents/Resources/DevBox.icns"
fi
if [ -f "$app/Contents/Resources/DevBox.icns" ]; then
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string DevBox" "$app/Contents/Info.plist"
fi
# Keep the local identity default; ad hoc CI explicitly supplies "-".
set -- --force --sign "$signing_certificate"
case "$signing_identity" in
    "Developer ID Application:"*)
        set -- "$@" --options runtime --timestamp --entitlements Resources/DevBox.entitlements
        ;;
esac
if [ -n "${DEVBOX_SIGNING_KEYCHAIN:-}" ]; then
    set -- "$@" --keychain "$DEVBOX_SIGNING_KEYCHAIN"
fi
printf 'Signing with %s\n' "$signing_identity"
codesign "$@" "$app"
codesign --verify --strict "$app"
printf '\nBuilt %s\nLaunch with: open "%s"\n' "$app" "$app"
