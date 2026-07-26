#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

xcodebuild build -scheme pocketshell -destination "platform=macOS,variant=Mac Catalyst" -quiet
built=$(xcodebuild -scheme pocketshell -destination "platform=macOS,variant=Mac Catalyst" -showBuildSettings 2>/dev/null |
    awk '$1 == "BUILT_PRODUCTS_DIR" { print $3 }')/pocketshell.app

# An unsigned build loses the app-group entitlement and cannot read the Keychain credentials.
# Mixing Xcode and xcodebuild runs can leave the app's CodeSign step marked up to date
# while the binary on disk is unsigned; a clean build is the only way back.
signed() { codesign -dv "$built" 2>&1 | grep -q "^TeamIdentifier=[A-Z0-9]"; }
if ! signed; then
    echo "built app is unsigned, rebuilding clean" >&2
    xcodebuild clean build -scheme pocketshell -destination "platform=macOS,variant=Mac Catalyst" -quiet
fi
signed || {
    echo "refusing to install: $built is not development-signed" >&2
    exit 1
}

osascript -e 'quit app "pocketshell"' 2>/dev/null || true
rm -rf /Applications/pocketshell.app
cp -R "$built" /Applications/pocketshell.app
open /Applications/pocketshell.app
echo "installed $(date -r /Applications/pocketshell.app/Contents/MacOS/pocketshell '+%b %d %H:%M')"
