#!/usr/bin/env bash
# Builds ClaudeBar in release mode and assembles the app bundle.
#
#   Scripts/package_app.sh                  native build, assembles build/ClaudeBar.app
#   Scripts/package_app.sh install          the above, then quit a running copy and install it to
#                                           /Applications/ClaudeBar.app (the path the login item
#                                           registers and the Homebrew cask installs to)
#   Scripts/package_app.sh release X.Y.Z    universal (arm64 + x86_64) build of version X.Y.Z,
#                                           assembled in build/release/ClaudeBar.app and zipped to
#                                           dist/ClaudeBar-X.Y.Z.zip with a .sha256 sidecar, then
#                                           checked with Scripts/verify_release.sh
#
# Versions: local builds are 0.1.0 with CFBundleVersion from BUILD_NUMBER (default: UTC timestamp,
# YYYYMMDDHHMMSS). A release sets both CFBundleShortVersionString and CFBundleVersion to X.Y.Z, so
# the build number grows with every release; BUILD_NUMBER is ignored there.
#
# Modelled on CodexBar's Scripts/package_app.sh without its dependency and notarization steps.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="ClaudeBar"
BUNDLE_ID="ru.sdfpro.ClaudeBar"
APP_ICON="$ROOT/Assets/AppIcon/$APP_NAME.icns"
INSTALL_DIR="/Applications"
INSTALLED_APP="$INSTALL_DIR/$APP_NAME.app"
RELEASE_ARCHS=(arm64 x86_64)
VERSION_RE='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'

usage() { echo "usage: $0 [install | release X.Y.Z]" >&2; exit 64; }

mode="${1:-package}"
case "$mode" in
  package|install)
    [[ $# -le 1 ]] || usage
    MARKETING_VERSION="0.1.0"
    BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M%S)}"
    APP="$ROOT/build/$APP_NAME.app"
    ;;
  release)
    [[ $# -eq 2 ]] || usage
    if [[ ! "$2" =~ $VERSION_RE ]]; then
      echo "error: release version must be X.Y.Z without leading zeros, got '$2'" >&2
      exit 64
    fi
    MARKETING_VERSION="$2"
    BUILD_NUMBER="$2"
    APP="$ROOT/build/release/$APP_NAME.app"
    DIST="$ROOT/dist"
    ZIP_NAME="$APP_NAME-$MARKETING_VERSION.zip"
    ;;
  *) usage ;;
esac

cd "$ROOT"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [[ "$mode" == "release" ]]; then
  # One single-arch build per slice, each in its own scratch path, joined with lipo. Several --arch
  # flags in one build need the Xcode build system; this path also works under Command Line Tools.
  # --show-bin-path gets the very same flags, or it would report the native build's directory.
  slices=()
  for arch in "${RELEASE_ARCHS[@]}"; do
    flags=(-c release --arch "$arch" --product "$APP_NAME" --scratch-path "$ROOT/.build/release-$arch")
    swift build "${flags[@]}"
    slice="$(swift build "${flags[@]}" --show-bin-path)/$APP_NAME"
    if [[ "$(lipo -archs "$slice")" != "$arch" ]]; then
      echo "error: $slice is not a single $arch slice" >&2
      exit 1
    fi
    slices+=("$slice")
  done
  lipo -create "${slices[@]}" -output "$APP/Contents/MacOS/$APP_NAME"
else
  swift build -c release --product "$APP_NAME"
  BIN_DIR="$(swift build -c release --show-bin-path)"
  cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
fi
# Adapted CodexBar code ships with its MIT notice.
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp "$APP_ICON" "$APP/Contents/Resources/$APP_NAME.icns"

# NSAllowsArbitraryLoads permits a plain-HTTP proxy (the UI warns about it). NSAllowsLocalNetworking
# is deliberately absent: when present, it makes the system ignore NSAllowsArbitraryLoads.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundleIconFile</key><string>${APP_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleShortVersionString</key><string>${MARKETING_VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key><true/>
    </dict>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Ad-hoc signature with a stable identifier (= bundle ID), applied once after the slices are joined.
codesign --force --sign - --identifier "$BUNDLE_ID" --timestamp=none "$APP"
codesign --verify --strict "$APP"
if ! cmp -s "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"; then
  echo "error: THIRD_PARTY_NOTICES.md is missing from $APP" >&2
  exit 1
fi
if ! cmp -s "$APP_ICON" "$APP/Contents/Resources/$APP_NAME.icns"; then
  echo "error: $APP_NAME.icns is missing from $APP" >&2
  exit 1
fi
echo "Built $APP (version $MARKETING_VERSION, build $BUILD_NUMBER)"

if [[ "$mode" == "release" ]]; then
  mkdir -p "$DIST"
  rm -f "$DIST/$ZIP_NAME" "$DIST/$ZIP_NAME.sha256"
  ditto -c -k --keepParent "$APP" "$DIST/$ZIP_NAME"
  (cd "$DIST" && shasum -a 256 "$ZIP_NAME" > "$ZIP_NAME.sha256")
  "$ROOT/Scripts/verify_release.sh" "$DIST/$ZIP_NAME" "$MARKETING_VERSION"
fi

if [[ "$mode" == "install" ]]; then
  if pgrep -x "$APP_NAME" >/dev/null; then
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    for _ in {1..50}; do
      pgrep -x "$APP_NAME" >/dev/null || break
      sleep 0.1
    done
    if pgrep -x "$APP_NAME" >/dev/null; then
      echo "error: $APP_NAME is still running; quit it and retry" >&2
      exit 1
    fi
  fi
  mkdir -p "$INSTALL_DIR"
  rm -rf "$INSTALLED_APP"
  ditto "$APP" "$INSTALLED_APP"
  echo "Installed $INSTALLED_APP"
fi
