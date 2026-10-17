#!/bin/bash
# Regenerates ClaudeBar.icns from render.swift (macOS, Xcode command line tools).
#
#   Assets/AppIcon/build.sh [output.icns]   default output: Assets/AppIcon/ClaudeBar.icns
#
# Intermediates (master PNGs, the .iconset, the Swift module cache) go to Assets/AppIcon/.build/,
# which is git-ignored; override with ICON_WORK_DIR.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$DIR/ClaudeBar.icns}"
WORK="${ICON_WORK_DIR:-$DIR/.build}"
rm -rf "$WORK/ClaudeBar.iconset"
mkdir -p "$WORK/ClaudeBar.iconset" "$WORK/swift-cache"
swift -module-cache-path "$WORK/swift-cache" "$DIR/render.swift" "$WORK/master_2048.png"
sips -z 1024 1024 "$WORK/master_2048.png" --out "$WORK/icon_1024.png" >/dev/null
for points in 16 32 128 256 512; do
  sips -z "$points" "$points" "$WORK/master_2048.png" --out "$WORK/ClaudeBar.iconset/icon_${points}x${points}.png" >/dev/null
  pixels=$((points * 2))
  sips -z "$pixels" "$pixels" "$WORK/master_2048.png" --out "$WORK/ClaudeBar.iconset/icon_${points}x${points}@2x.png" >/dev/null
done
swift -module-cache-path "$WORK/swift-cache" "$DIR/render.swift" "$WORK/small_master_2048.png" --small
sips -z 16 16 "$WORK/small_master_2048.png" --out "$WORK/ClaudeBar.iconset/icon_16x16.png" >/dev/null
iconutil -c icns "$WORK/ClaudeBar.iconset" -o "$OUT"
shasum -a 256 "$OUT"
