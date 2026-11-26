#!/usr/bin/env bash
# Fetch Ghostty at a pinned commit and build the libghostty-vt xcframework.
# Requires zig (brew install zig) and Xcode.
set -euo pipefail
GHOSTTY_COMMIT="4ebafeb70b3dde9de578040f90fa9d8c13dfa2d0"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$ROOT/vendor/ghostty"
if [ ! -d "$DIR/.git" ]; then
  git clone https://github.com/ghostty-org/ghostty.git "$DIR"
fi
git -C "$DIR" fetch --depth 1 origin "$GHOSTTY_COMMIT" 2>/dev/null || true
git -C "$DIR" checkout -q "$GHOSTTY_COMMIT"
cd "$DIR"
zig build -Demit-lib-vt=true -Demit-xcframework=true -Doptimize=ReleaseFast
echo "Built $DIR/zig-out/lib/ghostty-vt.xcframework"
