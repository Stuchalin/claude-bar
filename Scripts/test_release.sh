#!/usr/bin/env bash
# Checks the release scripts against a good release zip and tampered copies of it.
#
#   Scripts/test_release.sh dist/ClaudeBar-X.Y.Z.zip
#
# The zip comes from `make release VERSION=X.Y.Z`. Every case works on copies in a temp directory;
# the input zip and its sidecar are left untouched.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY="$ROOT/Scripts/verify_release.sh"
APP_NAME="ClaudeBar"

[[ $# -eq 1 ]] || { echo "usage: $0 <ClaudeBar-X.Y.Z.zip>" >&2; exit 64; }
good="$1"
good_name="$(basename "$good")"
version="${good_name#"$APP_NAME"-}"
version="${version%.zip}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
failures=0

pass() { echo "ok   $1"; }
bad() { echo "FAIL $1" >&2; failures=$((failures + 1)); }
expect_ok() { if "$VERIFY" "${@:2}" >/dev/null 2>&1; then pass "$1"; else bad "$1"; fi; }
# expect_reject <label> <stderr substring> <verify args...>: must fail, and for the named reason.
expect_reject() {
  local err
  if err="$("$VERIFY" "${@:3}" 2>&1 >/dev/null)"; then bad "$1 (accepted)"
  elif [[ "$err" != *"$2"* ]]; then bad "$1 (wrong reason: $err)"
  else pass "$1"; fi
}

# Zips <dir>/ClaudeBar.app (plus any other entries) as <out> with a matching sidecar.
pack() {
  local src="$1" out="$2"
  (cd "$src" && ditto -c -k --keepParent "$APP_NAME.app" "$out")
  (cd "$(dirname "$out")" && shasum -a 256 "$(basename "$out")" > "$(basename "$out").sha256")
}
unpacked() { local d="$tmp/$1"; mkdir -p "$d"; ditto -x -k "$good" "$d"; echo "$d"; }

expect_ok "good zip passes" "$good"
expect_ok "good zip passes with matching expected version" "$good" "$version"
expect_reject "expected version differing from file name" "differs from expected" "$good" "9.9.9"

# Bundle of $version packaged under another version's name.
mkdir -p "$tmp/renamed"
cp "$good" "$tmp/renamed/$APP_NAME-9.9.9.zip"
(cd "$tmp/renamed" && shasum -a 256 "$APP_NAME-9.9.9.zip" > "$APP_NAME-9.9.9.zip.sha256")
expect_reject "bundle $version zipped as 9.9.9" "CFBundleShortVersionString is" "$tmp/renamed/$APP_NAME-9.9.9.zip"

# Non-strict file names.
for name in "$APP_NAME-01.2.3.zip" "$APP_NAME-1.2.zip" "$APP_NAME-v1.2.3.zip" "Other-1.2.3.zip"; do
  mkdir -p "$tmp/names"
  cp "$good" "$tmp/names/$name"
  (cd "$tmp/names" && shasum -a 256 "$name" > "$name.sha256")
  expect_reject "file name $name" "does not match" "$tmp/names/$name"
done

# Sidecar problems.
mkdir -p "$tmp/sidecar"
cp "$good" "$tmp/sidecar/$good_name"
expect_reject "missing sidecar" ".sha256 not found" "$tmp/sidecar/$good_name"
echo "0000000000000000000000000000000000000000000000000000000000000000  $good_name" > "$tmp/sidecar/$good_name.sha256"
expect_reject "sidecar digest mismatch" "sha256 mismatch" "$tmp/sidecar/$good_name"
echo "$(shasum -a 256 "$good" | awk '{print $1}')  other.zip" > "$tmp/sidecar/$good_name.sha256"
expect_reject "sidecar naming another file" "names 'other.zip'" "$tmp/sidecar/$good_name"

# arm64-only binary, re-signed so that only the slice check can catch it.
d="$(unpacked thin)"
lipo -thin arm64 "$d/$APP_NAME.app/Contents/MacOS/$APP_NAME" -output "$d/thin"
mv "$d/thin" "$d/$APP_NAME.app/Contents/MacOS/$APP_NAME"
codesign --force --sign - --identifier ru.sdfpro.ClaudeBar --timestamp=none "$d/$APP_NAME.app" 2>/dev/null
mkdir -p "$tmp/thin-out"
pack "$d" "$tmp/thin-out/$good_name"
expect_reject "arm64-only binary" "architectures are 'arm64'" "$tmp/thin-out/$good_name"

# x86_64 slice requiring a newer macOS than 14.0, re-signed.
for minos in 15.0 14.0.1; do
  d="$(unpacked "minos-$minos")"
  bin="$d/$APP_NAME.app/Contents/MacOS/$APP_NAME"
  vtool -arch x86_64 -set-build-version macos "$minos" 15.0 -replace -output "$d/minos" "$bin" 2>/dev/null
  mv "$d/minos" "$bin"
  codesign --force --sign - --identifier ru.sdfpro.ClaudeBar --timestamp=none "$d/$APP_NAME.app" 2>/dev/null
  mkdir -p "$tmp/minos-$minos-out"
  pack "$d" "$tmp/minos-$minos-out/$good_name"
  expect_reject "x86_64 slice with minos $minos" "x86_64 slice minos $minos is above" "$tmp/minos-$minos-out/$good_name"
done

# Broken signature: a resource changed after signing.
d="$(unpacked unsigned)"
echo tampered >> "$d/$APP_NAME.app/Contents/Resources/THIRD_PARTY_NOTICES.md"
mkdir -p "$tmp/unsigned-out"
pack "$d" "$tmp/unsigned-out/$good_name"
expect_reject "signature broken by a modified resource" "codesign --verify --strict failed" "$tmp/unsigned-out/$good_name"

# Non-executable binary.
d="$(unpacked noexec)"
chmod -x "$d/$APP_NAME.app/Contents/MacOS/$APP_NAME"
mkdir -p "$tmp/noexec-out"
pack "$d" "$tmp/noexec-out/$good_name"
expect_reject "binary without the executable bit" "not executable" "$tmp/noexec-out/$good_name"

# A second top-level entry.
d="$(unpacked extra)"
mkdir -p "$tmp/extra-out"
echo extra > "$d/README.txt"
(cd "$d" && ditto -c -k . "$tmp/extra-out/$good_name")
(cd "$tmp/extra-out" && shasum -a 256 "$good_name" > "$good_name.sha256")
expect_reject "second top-level entry" "exactly one top-level" "$tmp/extra-out/$good_name"

# The release entry point rejects bad versions before building (exit 64).
for v in "" "1.2" "01.2.3" "1.2.3-beta" "v1.2.3" "1.2.3.4"; do
  set +e
  out="$("$ROOT/Scripts/package_app.sh" release "$v" 2>&1)"
  status=$?
  set -e
  if [[ $status -eq 64 && "$out" != *"Building"* && "$out" != *"Compiling"* ]]; then
    pass "package_app.sh release '$v' exits 64 before building"
  else
    bad "package_app.sh release '$v' (exit $status)"
  fi
done

if (( failures > 0 )); then
  echo "$failures case(s) failed" >&2
  exit 1
fi
echo "All release checks passed"
