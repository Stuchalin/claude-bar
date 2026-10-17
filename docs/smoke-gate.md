# Owner smoke gate (plan Task 2) and owner acceptance

Date: 2026-10-17. Performed by the owner on their own Mac (remote from the build Mac), with builds
downloaded as zip files, quarantine attribute removed, installed to `~/Applications/ClaudeBar.app`.

## Builds

| Build | CFBundleVersion | Icon | Source commit |
|---|---|---|---|
| build 1, build 2 | 1, 2 | watermark (superseded) | 97a8f6b + docs |
| build 3, build 4 | 3, 4 | variant E | 1b1b2f5 |

All builds are ad-hoc signed with identifier `ru.sdfpro.ClaudeBar`; each build has its own CDHash.

## Verdict: PASS with one OWNER-ACCEPTED LIMITATION

| Check | Result |
|---|---|
| Installed bundle shows a visible status item; menu opens Settings and Quit; no Dock icon | owner: ok |
| Cmd-V / Cmd-A in the Settings URL and secret fields, Cmd-C in the URL field | owner: ok |
| Real percentages from the proxy after saving URL and secret | owner: ok |
| Launch at login: enable → logout/login starts the app; disable → it does not start | owner: ok |
| Keychain secret readable without a prompt after installing a second build at the same path | not tested — owner ruling: skip, distribution will move to a Homebrew tap later |

No signing change was made. Open risk: with ad-hoc signing, an update may trigger a Keychain
access prompt; to be resolved when the Homebrew tap is set up.

## Owner visual acceptance (Tasks 6, 7, 8)

Owner reply "все ок" after checking the menu cards next to CodexBar, the variant E icon, and the
usage history charts in fixture mode: approved, no rejected deltas.
