#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

build=${PS_BUILD_DIR:-$PWD/.build/ci-gate}
cache=${PS_LIBGHOSTTY_CACHE:-$build/libghostty}
max_load=${PS_GATE_MAX_LOAD:-20}
min_free=${PS_GATE_MIN_FREE:-10}
max_wait=${PS_GATE_MAX_WAIT:-1800}
keychain='KeyKitTests\.(loadOrCreatePersistsSameKeyAcrossCalls|softwareKeyKindWhenEnclaveNotPreferred|deleteRemovesKey|signProducesValidSignature|setGetRoundtrip|setOverwritesExistingPassword)\('
skip=${PS_GATE_TEST_SKIP-$keychain}
started=$(date +%s)

fail() {
    echo "error: $*" >&2
    exit 1
}

unavailable() {
    echo "error: $*" >&2
    exit 75
}

step() {
    echo "== $* (+$(($(date +%s) - started))s)"
}

calm() {
    while :; do
        load=$(sysctl -n vm.loadavg | awk '{print int($2)}')
        free=$(memory_pressure | awk -F': ' '/free percentage/ {sub("%", "", $2); print int($2)}')
        [ -n "$load" ] && [ -n "$free" ] || unavailable "host load gate cannot read load or memory"
        [ "$load" -le "$max_load" ] && [ "$free" -ge "$min_free" ] && return 0
        [ $(($(date +%s) - started)) -lt "$max_wait" ] || unavailable "host busy (load $load, free $free %)"
        echo "wait: host busy (load $load, free $free %)"
        sleep 30
    done
}

for tool in swift zig xcodegen xcodebuild; do
    command -v "$tool" >/dev/null || unavailable "$tool not found"
done
mkdir -p "$build"

step "swift format lint"
find . \( -name .build -o -name DerivedData -o -name .swiftpm -o -name node_modules -o -name '*.xcodeproj' \) -prune \
    -o -name '*.swift' -print0 | xargs -0 swift format lint --strict --parallel || fail "swift format lint --strict"

calm
step "libghostty"
key=$(cat Scripts/build-libghostty.sh Scripts/libghostty-*.patch | shasum -a 256 | cut -c1-16)-$(zig version)
framework=Packages/Core/Frameworks/GhosttyVt.xcframework
if [ ! -d "$cache/$key/GhosttyVt.xcframework" ]; then
    PS_LIBGHOSTTY_BUILD="$cache/work" ZIG_GLOBAL_CACHE_DIR="$cache/zig" Scripts/build-libghostty.sh || fail "libghostty build"
    rm -rf "$cache/$key.tmp"
    mkdir -p "$cache/$key.tmp"
    cp -Rp "$framework" "$cache/$key.tmp/"
    mv "$cache/$key.tmp" "$cache/$key"
fi
if [ "$(cat "$framework/GATE_KEY" 2>/dev/null)" != "$key" ]; then
    rm -rf "$framework"
    mkdir -p "$(dirname "$framework")"
    cp -Rp "$cache/$key/GhosttyVt.xcframework" "$framework"
    echo "$key" > "$framework/GATE_KEY"
fi

calm
step "swift test"
swift test --package-path Packages/Core --scratch-path "$build/core" ${skip:+--skip "$skip"} \
    || fail "swift test --package-path Packages/Core"

calm
step "xcodegen"
xcodegen generate --quiet || fail "xcodegen generate"
for destination in "generic/platform=iOS Simulator" "generic/platform=macOS,variant=Mac Catalyst"; do
    calm
    step "xcodebuild build $destination"
    xcodebuild build -project pocketshell.xcodeproj -scheme pocketshell -destination "$destination" \
        -derivedDataPath "$build/dd" -quiet CODE_SIGNING_ALLOWED=NO || fail "xcodebuild build $destination"
done

step "ci gate passed"
