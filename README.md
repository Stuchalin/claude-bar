# ClaudeBar

A macOS menu bar app for Claude subscription limits, styled after
[CodexBar](https://github.com/steipete/CodexBar). It fetches usage through your
[claude-code-proxy](https://github.com/shanuflash/claude-code-proxy), using the proxy's
shared secret, for Macs without local Claude OAuth credentials.

## Requirements

- macOS 14+.
- Swift 6.2+; Command Line Tools are enough. No third-party packages.
- A running claude-code-proxy, its URL and shared secret.

## Build and install

Run from the repository root:

```bash
make build                       # Debug build
make test                        # Tests with Command Line Tools framework paths
make app                         # Release bundle: build/ClaudeBar.app
Scripts/package_app.sh install   # Build and install to ~/Applications/ClaudeBar.app
```

`make install` is an alias for the install command. Installation quits and replaces
the existing app. With a full Xcode toolchain, use `make test TEST_FLAGS=`.

Launch `~/Applications/ClaudeBar.app`, open **Settings…**, enter the proxy URL and
secret, then **Save**. The secret is stored in Keychain.

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
