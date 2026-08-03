#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

: "${ASC_KEY_ID:?set ASC_KEY_ID (App Store Connect API key id)}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID (App Store Connect issuer id)}"
key="$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8"
[ -f "$key" ] || { echo "missing $key" >&2; exit 1; }

# Minutes since 2020, so build numbers only ever climb. Commit counts do not:
# rewriting history lowers them and App Store Connect rejects the reused number.
[ -z "$(git status --porcelain)" ] || { echo "working tree is dirty, commit first" >&2; exit 1; }
build=$(( ($(date +%s) - 1577836800) / 60 ))

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

# Answer the per-build export-compliance question (standard algorithms, exempt)
# so builds reach TestFlight without clicking through App Store Connect.
uv run --with cryptography python3 Scripts/asc-compliance.py "$build"
