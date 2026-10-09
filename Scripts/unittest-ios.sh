#!/bin/sh
set -eu

REPO=$(cd "$(dirname "$0")/.." && pwd)
SIM=${PS_TEST_SIM:-iPhone 17 Pro}
BUILD=${PS_BUILD_DIR:-$REPO/DerivedData}
DEST="platform=iOS Simulator,name=$SIM"
cd "$REPO"

xcodegen generate
status=0
xcodebuild test \
    -project pocketshell.xcodeproj \
    -scheme pocketshell \
    -destination "$DEST" \
    -derivedDataPath "$BUILD/dd-app" \
    -only-testing:pocketshellTests || status=1
cd Packages/Core
xcodebuild test \
    -scheme Core-Package \
    -destination "$DEST" \
    -derivedDataPath "$BUILD/dd-core" || status=1
exit $status
