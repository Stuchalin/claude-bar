#!/usr/bin/env bash
# Builds ClaudeBar in release mode and assembles build/ClaudeBar.app.
#
#   Scripts/package_app.sh            build and assemble build/ClaudeBar.app
#   Scripts/package_app.sh install    the above, then quit a running copy and install it to
#                                     ~/Applications/ClaudeBar.app (the path the login item registers)
#
# Environment:
#   BUILD_NUMBER   CFBundleVersion (default: UTC timestamp, YYYYMMDDHHMMSS)
#
# Modelled on CodexBar's Scripts/package_app.sh without its dependency and notarization steps.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="ClaudeBar"
BUNDLE_ID="ru.sdfpro.ClaudeBar"
MARKETING_VERSION="0.1.0"
BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M%S)}"
APP="$ROOT/build/$APP_NAME.app"
INSTALL_DIR="$HOME/Applications"
INSTALLED_APP="$INSTALL_DIR/$APP_NAME.app"

mode="${1:-package}"
case "$mode" in
  package|install) ;;
  *) echo "usage: $0 [install]" >&2; exit 64 ;;
esac

cd "$ROOT"
swift build -c release --product "$APP_NAME"
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
# Adapted CodexBar code ships with its MIT notice.
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"

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

# Ad-hoc signature with a stable identifier (= bundle ID).
codesign --force --sign - --identifier "$BUNDLE_ID" --timestamp=none "$APP"
codesign --verify --strict "$APP"
if ! cmp -s "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"; then
  echo "error: THIRD_PARTY_NOTICES.md is missing from $APP" >&2
  exit 1
fi
echo "Built $APP (version $MARKETING_VERSION, build $BUILD_NUMBER)"

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
