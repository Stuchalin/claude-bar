#!/usr/bin/env bash
# Verifies a release zip produced by `Scripts/package_app.sh release X.Y.Z` from its unpacked copy.
#
#   Scripts/verify_release.sh dist/ClaudeBar-X.Y.Z.zip [X.Y.Z]
#
# The expected version comes from the strict file name ClaudeBar-X.Y.Z.zip and, when given, the
# second argument (the release input, e.g. the tag without "v"); both must agree. It is never read
# from the bundle being checked. The sidecar <zip>.sha256 must sit next to the zip.
set -euo pipefail

APP_NAME="ClaudeBar"
BUNDLE_ID="ru.sdfpro.ClaudeBar"
REQUIRED_ARCHS="arm64 x86_64"
MAX_MINOS="14.0"
VERSION_RE='(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'

fail() { echo "error: $*" >&2; exit 1; }

[[ $# -ge 1 && $# -le 2 ]] || { echo "usage: $0 <ClaudeBar-X.Y.Z.zip> [X.Y.Z]" >&2; exit 64; }
zip="$1"
zip_name="$(basename "$zip")"
[[ -f "$zip" ]] || fail "$zip not found"

name_re="^${APP_NAME}-(${VERSION_RE})\\.zip\$"
[[ "$zip_name" =~ $name_re ]] || fail "$zip_name does not match $APP_NAME-X.Y.Z.zip"
version="${BASH_REMATCH[1]}"
if [[ $# -eq 2 ]]; then
  [[ "$2" =~ ^${VERSION_RE}$ ]] || fail "expected version '$2' is not X.Y.Z"
  [[ "$2" == "$version" ]] || fail "file name version $version differs from expected $2"
fi

# Sidecar: "<sha256>  <zip file name>", one line.
sidecar="$zip.sha256"
[[ -f "$sidecar" ]] || fail "$sidecar not found"
read -r want_hash want_name extra < "$sidecar" || true
[[ -z "${extra:-}" && "$(wc -l < "$sidecar" | tr -d ' ')" == "1" ]] || fail "$sidecar is not a single '<hash>  <name>' line"
[[ "$want_name" == "$zip_name" ]] || fail "$sidecar names '$want_name', not $zip_name"
have_hash="$(shasum -a 256 "$zip" | awk '{print $1}')"
[[ "$want_hash" == "$have_hash" ]] || fail "sha256 mismatch: sidecar $want_hash, zip $have_hash"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
ditto -x -k "$zip" "$tmp"

entries="$(find "$tmp" -mindepth 1 -maxdepth 1 -exec basename {} \; | sort)"
[[ "$entries" == "$APP_NAME.app" ]] || fail "zip must hold exactly one top-level $APP_NAME.app, found: $(echo "$entries" | tr '\n' ' ')"
app="$tmp/$APP_NAME.app"
plist="$app/Contents/Info.plist"
binary="$app/Contents/MacOS/$APP_NAME"

plist_value() { /usr/libexec/PlistBuddy -c "Print :$1" "$plist" 2>/dev/null || true; }
[[ "$(plist_value CFBundleIdentifier)" == "$BUNDLE_ID" ]] || fail "CFBundleIdentifier is not $BUNDLE_ID"
short="$(plist_value CFBundleShortVersionString)"
build="$(plist_value CFBundleVersion)"
[[ "$short" == "$version" ]] || fail "CFBundleShortVersionString is '$short', expected $version"
[[ "$build" == "$version" ]] || fail "CFBundleVersion is '$build', expected $version"

[[ -f "$binary" && -x "$binary" ]] || fail "$APP_NAME executable missing or not executable"
codesign --verify --strict "$app" || fail "codesign --verify --strict failed"

archs="$(lipo -archs "$binary" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')"
[[ "$archs" == "$REQUIRED_ARCHS" ]] || fail "architectures are '$archs', expected '$REQUIRED_ARCHS'"

# major.minor.patch as one integer for comparison; missing components count as zero.
version_key() { awk -F. '{ printf "%d\n", $1 * 1000000 + $2 * 1000 + $3 }' <<< "$1"; }
for arch in $REQUIRED_ARCHS; do
  minos="$(vtool -arch "$arch" -show-build "$binary" | awk '$1 == "minos" { print $2; exit }')"
  [[ -n "$minos" ]] || fail "$arch slice has no LC_BUILD_VERSION minos"
  (( $(version_key "$minos") <= $(version_key "$MAX_MINOS") )) || fail "$arch slice minos $minos is above $MAX_MINOS"
done

echo "Verified $zip_name: $APP_NAME.app $version ($build), $archs, minos <= $MAX_MINOS, signature and sha256 OK"
