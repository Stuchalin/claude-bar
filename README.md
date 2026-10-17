# ClaudeBar

A macOS menu bar app for Claude subscription limits, styled after
[CodexBar](https://github.com/steipete/CodexBar). It fetches usage through your
[claude-code-proxy](https://github.com/shanuflash/claude-code-proxy), using the proxy's
shared secret, for Macs without local Claude OAuth credentials.

## Requirements

- macOS 14+.
- Swift 6.2+; Command Line Tools are enough. No third-party packages.
- A running claude-code-proxy, its URL and shared secret.

## Install

After the first release, install from the Homebrew tap:

```bash
brew install --cask stuchalin/claude-bar/claudebar   # available after the first release
brew upgrade --cask claudebar
```

The app lives in `/Applications/ClaudeBar.app`. It is ad-hoc signed and not notarized, so
macOS may block the first launch; allow it under **System Settings → Privacy & Security →
Open Anyway**. A copy left in `~/Applications` by an earlier local install can be removed
once the `/Applications` copy works; history and the Keychain secret are kept outside the app.

Launch ClaudeBar, open **Settings…**, enter the proxy URL and secret, then **Save**. The
secret is stored in Keychain.

## Build from source

Run from the repository root:

```bash
make build                       # Debug build
make test                        # Tests with Command Line Tools framework paths
make app                         # Release bundle: build/ClaudeBar.app
make install                     # Build and install to /Applications/ClaudeBar.app
make release VERSION=X.Y.Z       # Universal zip: dist/ClaudeBar-X.Y.Z.zip and .sha256
```

Installation quits and replaces the existing app. With a full Xcode toolchain, use
`make test TEST_FLAGS=`. A release build joins arm64 and x86_64 slices, sets both bundle
versions to `X.Y.Z` and checks the zip with `Scripts/verify_release.sh`;
`Scripts/test_release.sh dist/ClaudeBar-X.Y.Z.zip` runs that check against tampered copies.

GitHub Actions (`.github/workflows/ci.yml`) builds and tests every push and pull request.
Pushing a `vX.Y.Z` tag also builds the universal zip and publishes it with its `.sha256` as a
GitHub release.

Downloaded ZIP builds were tested with quarantine removed; see the
[installation test notes](docs/smoke-gate.md).

To regenerate the app icon from its vector drawing:

```bash
Assets/AppIcon/build.sh
```

## Local data and limitations

- History: `~/Library/Application Support/ClaudeBar/history.sqlite`.
- Secret: Keychain service `ru.sdfpro.ClaudeBar`, account `proxy-secret`.
- Proxy URL and refresh interval: the app's `UserDefaults`.

ClaudeBar cannot detect an account switch behind the proxy. Use **Settings… →
Clear history…** after switching accounts to avoid mixing their history.

The app is ad-hoc signed. An update may prompt for Keychain access again; access
across updates has not been verified.

Parts of ClaudeBar are adapted from CodexBar (MIT). See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
