# ClaudeBar

A macOS menu bar app for Claude subscription limits, styled after
[CodexBar](https://github.com/steipete/CodexBar). It fetches usage through your
[claude-code-proxy](https://github.com/shanuflash/claude-code-proxy), using the proxy's
shared secret, for Macs without local Claude OAuth credentials.

## Requirements

- macOS 14+.
- For source builds only: Swift 6.2+; Command Line Tools are enough. No third-party packages.
- A running claude-code-proxy, its URL and shared secret.

## Install

Install and upgrade from the Homebrew tap, always with the fully qualified name (the official
Homebrew cask `claudebar` is a different app):

```bash
brew install --cask stuchalin/claude-bar/claude-bar
brew update
brew upgrade --cask stuchalin/claude-bar/claude-bar
```

If ClaudeBar was installed under the old token `claudebar`, see the
[tap README](https://github.com/Stuchalin/homebrew-claude-bar#migrating-from-the-old-claudebar-token)
for the manual migration.

The app lives in `/Applications/ClaudeBar.app` and is ad-hoc signed, not notarized.
The tested Homebrew install required **System Settings → Privacy & Security → Open Anyway**
on first launch. Expect a Keychain password prompt to allow access to the saved proxy secret
on installation or upgrade.

For first-time setup, open **Settings…**, enter the proxy URL and secret, then **Save**.
The secret is stored in Keychain. When moving from `~/Applications`, quit the old copy,
launch the Homebrew copy and re-enable **Launch at login** in Settings. Remove the old copy
once the Homebrew copy works.

Uninstalling without `--zap` keeps history, preferences and the Keychain secret. `--zap`
removes history and preferences but keeps the secret; see the
[tap's uninstall instructions](https://github.com/Stuchalin/homebrew-claude-bar#uninstall).

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

Parts of ClaudeBar are adapted from CodexBar (MIT). See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
