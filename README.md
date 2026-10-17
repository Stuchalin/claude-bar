# ClaudeBar

A macOS menu bar app that shows your Claude subscription limits (5-hour session, weekly,
model-scoped weekly and extra usage) in the visual style of
[CodexBar](https://github.com/steipete/CodexBar).

CodexBar reads these limits from `api.anthropic.com/api/oauth/usage` with local OAuth
credentials. ClaudeBar is for a Mac that has no such credentials and reaches Claude only through a
self-hosted [claude-code-proxy](https://github.com/shanuflash/claude-code-proxy): it asks the
proxy for the same usage data, authenticated with the proxy's shared secret.

## Requirements

- macOS 14 or later.
- Swift 6.2+ tools (Command Line Tools are enough; Xcode is not required). Swift Package Manager
  only, no third-party packages.
- A running claude-code-proxy (see [Proxy](#proxy)).

## Build, test and install

```bash
make build      # swift build (debug)
make test       # swift test with the Command Line Tools Swift Testing paths
make app        # Scripts/package_app.sh: release build, assembles build/ClaudeBar.app
make install    # Scripts/package_app.sh install: the above, then installs ~/Applications/ClaudeBar.app
```

- Under Command Line Tools plain `swift test` fails with "no such module 'Testing'"; `make test`
  passes the framework paths explicitly. With a full Xcode toolchain active, run
  `make test TEST_FLAGS=`.
- `install` quits a running copy first and replaces `~/Applications/ClaudeBar.app`, the path the
  login item registers. `BUILD_NUMBER` sets `CFBundleVersion` (default: a UTC timestamp).
- The bundle (ID `ru.sdfpro.ClaudeBar`, `LSUIElement`, so no Dock icon) is ad-hoc signed with the
  bundle ID as its identifier. Install, launch at login and live data were confirmed by the owner
  (`docs/smoke-gate.md`); whether Keychain access survives a rebuild of an ad-hoc-signed bundle
  was not tested and may require re-approving the Keychain prompt after an update.
- The app icon (`Assets/AppIcon/ClaudeBar.icns`) was drawn for this project: an own vector
  starburst in `#CC7C5E`, the colour CodexBar uses for Claude, in a composition modelled on
  CodexBar's app icon. Regenerate it from `Assets/AppIcon/render.swift` with
  `Assets/AppIcon/build.sh`.

## Settings

Open **Settings…** from the menu.

- **Proxy URL** — `http://` or `https://`, optionally with a path prefix; credentials, query and
  fragment are rejected. A plain-HTTP URL shows a warning that the secret travels unencrypted.
- **Secret** — stored only in the Keychain. **Save** writes the secret first and commits the URL
  only if that succeeded; a failed save leaves the previous settings in effect.
- **Refresh** — Manual, 1, 2, 5 (default), 15 or 30 min, applied immediately.
  - Automatic intervals fetch at launch, on each interval, when the menu opens (at most once per
    30 s) and after the Mac wakes. Transient failures retry with a backoff capped at the
    interval.
  - **Manual** fetches only on the menu's **Refresh** and on **Check connection**; nothing is
    scheduled.
  - An HTTP 429 starts a cooldown (the response's `Retry-After`, otherwise 5 min) that blocks every
    fetch, manual ones included.
- **Launch at login** — via `SMAppService`. Besides on/off it can show that macOS needs approval
  (with an **Open System Settings** button) or that macOS cannot find the app as a login item
  (install it with `make install` and launch it from `~/Applications`).
- **Check connection** — fetches once with the saved settings and shows the result.
- **Clear history…** — after confirmation deletes every recorded observation; current usage is
  not affected.

## Proxy

ClaudeBar sends `GET {proxy URL}/api/oauth/usage` with the secret in the `x-proxy-secret` header
(plus `anthropic-beta: oauth-2025-04-20`). claude-code-proxy forwards it upstream with its own
OAuth token. The secret is never put in the URL, and redirects are followed only within the same
scheme, host and port. The proxy passes upstream status codes through, so an error such as 403 or 502 may come
from the proxy or from Anthropic; known proxy error bodies get a specific hint.

## What the menu shows

- **Menu bar icon** — two bars, top = session, bottom = weekly, filled by the share **remaining**,
  with a Claude starburst at 70 % opacity to their right, not overlapping them (24×18 pt). A
  stale value is drawn dimmed; an unknown value is a dashed
  hollow outline, distinct from 0 %. The tooltip and VoiceOver label read both values.
- **Quota cards** — Session, Weekly and each model-scoped weekly limit, each with "NN% left", a
  progress bar, reset time and pace. A value from an earlier fetch is marked "Stale · seen …";
  once a cached window's reset time passes without a fresh fetch the card says it is waiting for
  fresh data. Data is stale after a failed attempt or when older than 2× the interval (10 min in
  manual mode).
- **Extra usage** — this month's spend against the monthly cap, or a specific state (no monthly
  cap, cap of 0, cap unknown, currency unknown), plus percent used and a remaining bar when a
  percentage can be calculated (a positive cap and either the spend or the reported utilization). No reset time and no pace. Hidden when disabled or never seen; a last-known value is
  marked stale.
- **Pace** — the average pace since the window started: how far usage is ahead of ("in deficit")
  or behind ("in reserve") an even burn, and whether it lasts until reset. Not shown for stale,
  unknown or past-reset windows, nor for Extra usage; the session needs at least 3 % of its window
  elapsed.
- **Usage history** submenu — for Session, Weekly or a scoped limit: a burn-down of the current
  window (ideal line vs observed remaining, never drawn across a gap) and the observed peak of
  each past window. Windows without observations are shown as unobserved, never as 0 %.
- Footer: next attempt time (or "Retry available at" during a cooldown in manual mode), history
  storage problems, **Refresh**, **Settings…**, **Quit ClaudeBar**.

To see the charts populated without real history, launch with `--history-fixtures`, e.g.
`open ~/Applications/ClaudeBar.app --args --history-fixtures`. This launch only, the submenu is
labelled "Usage history (fixtures)" and shows synthetic data; real recording continues untouched.

## Data location

- History: `~/Library/Application Support/ClaudeBar/history.sqlite` (SQLite, kept for one year).
  Extra usage is not recorded.
- Secret: Keychain generic password, service `ru.sdfpro.ClaudeBar`, account `proxy-secret`.
- Proxy URL and refresh interval: the app's standard `UserDefaults` (domain `ru.sdfpro.ClaudeBar`
  for the installed bundle), keys `proxyURL` and `refreshIntervalSeconds`.

## Limitations

- One Claude account behind the proxy. If the proxy switches to another account, ClaudeBar cannot
  tell; use **Clear history…** so the old account's history does not mix with the new one.
- Scoped limits are identified best-effort: by model id when the response has one, otherwise by
  the display name. Renaming a limit that has a model id keeps its series; without a model id a
  rename starts a new series, and so does a limit that gains a model id. Rows whose identity
  collides (same model id, or same name when there is no id) are shown as ambiguous and are not
  recorded, so their values never mix in one history series.
- A history file written by a newer ClaudeBar, in WAL mode, damaged or not recognized is refused
  and left untouched: history turns off with a message in the menu and Settings, live usage keeps
  working. There is no repair.

## Notices and collaboration

- Parts of the code are adapted from CodexBar (MIT); see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
- Built jointly by Claude Code and Codex; agent conventions are in [AGENTS.md](AGENTS.md).
