#!/usr/bin/env bash
set -euo pipefail

GHOSTTY_COMMIT=0d1d5e884b88a711f1ccf47387ab41e8fa28a755
GHOSTTY_REPO=https://github.com/ghostty-org/ghostty.git

root="$(cd "$(dirname "$0")/.." && pwd)"
build="${PS_LIBGHOSTTY_BUILD:-$root/.build/libghostty}"
dest="$root/Packages/Core/Frameworks/GhosttyVt.xcframework"
export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$build/zig-cache}"
export TMPDIR="${TMPDIR:-$build/tmp}"
mkdir -p "$build" "$TMPDIR" "$ZIG_GLOBAL_CACHE_DIR"

clone="${PS_GHOSTTY_SRC:-$build/ghostty.git}"
if ! git -C "$clone" cat-file -e "$GHOSTTY_COMMIT^{commit}" 2>/dev/null; then
    [ -d "$clone" ] || git clone --bare --filter=blob:none "$GHOSTTY_REPO" "$clone"
    git -C "$clone" fetch origin "$GHOSTTY_COMMIT"
fi

src="$build/src-$GHOSTTY_COMMIT"
rm -rf "$src"
mkdir -p "$src"
git -C "$clone" archive "$GHOSTTY_COMMIT" | tar -x -C "$src"
for p in "$root"/Scripts/libghostty-*.patch; do patch -d "$src" -p1 < "$p"; done

(cd "$src" && zig build -Demit-lib-vt -Demit-xcframework=true -Doptimize=ReleaseFast --prefix "$build/out")

rm -rf "$dest"
mkdir -p "$(dirname "$dest")"
cp -R "$build/out/lib/ghostty-vt.xcframework" "$dest"
echo "$GHOSTTY_COMMIT" > "$dest/GHOSTTY_COMMIT"
echo "built $dest"
