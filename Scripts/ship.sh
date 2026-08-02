#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

: "${ASC_KEY_ID:?set ASC_KEY_ID (App Store Connect API key id)}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID (App Store Connect issuer id)}"
key="$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8"
[ -f "$key" ] || { echo "missing $key" >&2; exit 1; }

# Build numbers come from commit count, so a shipped build is always reproducible.
[ -z "$(git status --porcelain)" ] || { echo "working tree is dirty, commit first" >&2; exit 1; }
build=$(git rev-list --count HEAD)

xcodegen generate

ship() {
    out=$(mktemp -d)
    xcodebuild archive -scheme pocketshell -destination "$1" \
        -archivePath "$out/pocketshell.xcarchive" \
        -allowProvisioningUpdates -quiet \
        CURRENT_PROJECT_VERSION="$build"
    xcodebuild -exportArchive -archivePath "$out/pocketshell.xcarchive" \
        -exportOptionsPlist Scripts/ExportOptions.plist -exportPath "$out/export" \
        -allowProvisioningUpdates \
        -authenticationKeyPath "$key" \
        -authenticationKeyID "$ASC_KEY_ID" \
        -authenticationKeyIssuerID "$ASC_ISSUER_ID"
    rm -rf "$out"
}

ship "generic/platform=iOS"
ship "generic/platform=macOS,variant=Mac Catalyst"
echo "uploaded build $build (iOS + Mac Catalyst) to TestFlight"
