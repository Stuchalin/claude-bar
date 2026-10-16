# ClaudeBar: Claude subscription limits in the macOS menu bar via the user's proxy

**Executor:** `/peer-planning:exec`. A subagent implements each task and Codex reviews the diff
before the task closes; a task marked `**Discuss:** yes` has its approach agreed with Codex first.

## Stories
- As the owner, I see at a glance in the menu bar how much of my 5-hour and weekly Claude limits is left, and can tell ClaudeBar's icon apart from CodexBar's.
- As the owner, I open the menu and see Session, Weekly, model-scoped weekly and Extra usage cards with reset times and a pace forecast, in CodexBar's style.
- As the owner, I open a history submenu and see a burn-down chart of the current window and observed peak usage of past windows.
- As the owner, when the proxy is unreachable or rejects me, I see the last known values clearly marked stale, why, and when the next retry happens — never invented numbers.
- As the owner, I enter the proxy URL and secret once in Settings; the app keeps working after reboots and rebuilds and can start at login.

## Overview
- CodexBar cannot show Claude limits for this user: it calls `api.anthropic.com/api/oauth/usage` directly with local OAuth credentials, while this Mac reaches Claude only through a self-hosted [claude-code-proxy](https://github.com/shanuflash/claude-code-proxy) gated by an `x-proxy-secret` header.
- The proxy forwards any path upstream and injects the OAuth token, so `GET {proxy}/api/oauth/usage` with the secret returns the full usage JSON (session evidence: HTTP 200 on 2026-10-16, checked by Claude with curl).
- ClaudeBar is a new, small, single-provider menu bar app that polls that endpoint, stores observations locally (the endpoint has no history) and renders CodexBar-style cards, charts and pace.
- Background and reasoning: `docs/brainstorm/claudebar-design.md`. Where this plan and the design doc differ, this plan wins.

## Decisions
- **Own app, not a CodexBar fork** — owner ruling (option A), chosen to avoid maintaining a fork against upstream.
- **Scope of display:** Session (`five_hour`), Weekly (`seven_day`), model-scoped weekly (possibly several), Extra usage (`extra_usage`). No `seven_day_breakdown`. Owner ruling.
- **Icon:** CodexBar's two-bar template icon (top = session, bottom = weekly, fill = remaining) at 18×18 pt, plus a large gray Claude-logo watermark behind the bars (alpha ≈ 0.3) with a ≈1 px knockout around each bar so rays never cross bars. Logo is our own simplified vector starburst, not a copied asset. Unknown/stale must be visually distinct from 0 % and 100 %. Owner ruling (watermark); alpha/gap are starting values tuned at owner review.
- **Single Claude account behind the proxy** — owner ruling. No profiles/multi-account; Clear history plus a documented limitation that account switches are undetectable.
- **Stack:** Swift tools version ≥ 6.2, Swift 6 language mode, macOS 14+, SPM only (no Xcode project), AppKit `NSStatusItem` + `NSMenu` with `NSMenuItem.view = NSHostingView(SwiftUI)`, Swift Charts, no third-party packages. Evidence: CodexBar uses this composition (`Sources/CodexBar/StatusItemController.swift`, `StatusItemController+MenuCardItems.swift`); `swiftc -swift-version 6.2` is rejected by the local 6.3.3 toolchain (valid: 4, 4.2, 5, 6). Pair-settled.
- **Packaging:** a small script assembling `ClaudeBar.app` (Contents/MacOS, Resources, generated Info.plist with `LSUIElement`), modelled on CodexBar's `Scripts/package_app.sh` without its dependency machinery. Stable bundle ID and a stable install path (e.g. `~/Applications/ClaudeBar.app`) that the login item registers. Ad-hoc signing stability for Keychain/login is unverified until Task 2. Pair-settled.
- **Secret storage:** Keychain only. Settings are the source of truth; no reading of `ANTHROPIC_*` env or shell rc files; the app must work when launched without those env vars. Secret never in URL/query, never logged, never forwarded on cross-origin redirects. Plaintext-file or memory-only fallbacks are out of v1 and need an owner ruling. Pair-settled.
- **Deferred (not in v1):** "Import from environment" in Settings; adaptive refresh; usage breakdown by surface.
- **Response mapping precedence** (pair-settled; percent units verified in the real response: `seven_day.utilization` 1.0 ↔ `limits[weekly_all].percent` 1):
  - Session: `five_hour` when present and valid; else `limits[]` row with `kind == "session"`; else unavailable.
  - Weekly: `seven_day` when present and valid; else `limits[]` row with `kind == "weekly_all"`; else unavailable.
  - Scoped weeklies: every `limits[]` row with `kind == "weekly_scoped"`; rows render regardless of `is_active` (CodexBar `ClaudeUsageFetcher.swift` deliberately does not filter on it: "observed enforceable scoped limits report false"; amended during Task 3 review, pair-settled). Identity is best-effort and namespaced by provenance: `id:<model id>` when the id is non-empty after trimming, else `name:<conservatively normalized display_name>` (the real response has `model.id == null` for Fable; CodexBar `ClaudeScopedWeeklyLimitMapper.swift` likewise falls back from model id to name), and `legacy:<field>` for the fallback below. Rows whose keys collide are never merged: show them as ambiguous/unavailable and keep their history apart. A rename or a name→id transition starts a new stream; no migration. Agreed in plan review (pair-settled); the limitation is documented in README. If there are no `weekly_scoped` rows, fall back to non-null `seven_day_sonnet` / `seven_day_opus` (CodexBar's `ClaudeUsageFetcher.swift` uses `seven_day_sonnet ?? seven_day_opus`).
  - Extra: `extra_usage`; amounts are cents ÷ 100 (CodexBar `ClaudeUsageFetcher.swift`, extra-usage mapping).
- **Parsing:** tolerant decoding; unknown fields ignored; missing/malformed metrics are *unavailable*, never 0; non-finite numbers rejected; one bad optional row does not drop the rest. `resets_at == null` means "not started" only together with utilization 0, otherwise "reset unknown" without pace. Extra usage states: disabled / no cap / zero cap / missing currency are distinct. Pair-settled.
- **Error semantics:** the proxy mirrors upstream status and body (`server.js`, upstream response handler), so 401/403/502 are ambiguous: 403 can be upstream, proxy model/effort policy, or access-window expiry; 502 can be missing host credentials or upstream transport failure. Recognize the proxy's own known body shapes for specific hints, otherwise report a generic authorization / access / server error. Pair-settled.
- **Refresh contract** (pair-settled; detailed in Task 4's approach agreement):
  - Auto modes (1/2/5/15/30 min, default 5): fetch at launch, on interval, on menu open (throttled to 30 s), on wake (`NSWorkspace.didWakeNotification`).
  - Manual mode: no timer, no launch/menu/wake fetch; only the menu's Refresh and Settings' Check connection.
  - One request in flight; triggers arriving during a request collapse into at most one follow-up, and menu-open triggers never create a perpetual trailing loop.
  - 429 → `Retry-After` (seconds or HTTP date) or 5 min default cooldown, which blocks every trigger including manual; transient failures use bounded exponential backoff. Auto modes show "next attempt at"; manual mode shows "retry available at" / "cooldown ends at", since nothing is scheduled.
  - Any config change (proxy URL or secret) advances the request generation: in-flight responses and errors from the old config never update state or write history. Only a URL/source change also hides old-source values immediately; a secret change at the same URL keeps displayed values and history.
  - Availability is per metric: a fresh weekly value never makes a missing session look fresh.
  - A snapshot is stale when its age exceeds 2× the interval (auto) or 10 min (manual), or after any failed attempt. These thresholds are v1 policy defaults agreed in plan review, not measured values. When a cached window's reset time passes without a new fetch, the card shows "waiting for fresh data": no renewed capacity, no forecast.
- **History storage:** system SQLite3 (`import SQLite3`; present in the macOS SDK as `extern module SQLite3` in `usr/include/module.modulemap` plus `usr/lib/libsqlite3.tbd`) behind a small Swift adapter, single serialized connection, off the main actor. Observations stored as runs of unchanged values (firstSeenAt / lastSeenAt, extended on each successful fetch), explicit break records on failures and missing metrics, never joined across reset, source change or long gaps. No synthetic heartbeats. Schema v1 with a stored version; a newer unsupported version is refused without modification. On corruption: keep the original file, show a nonfatal storage error, never auto-delete or recreate, live usage keeps working; repair is out of v1. Retention 1 year, separate from chart downsampling. Rejected: CodexBar's hourly-peak JSON (too coarse for 5 h charts), state.json + JSONL segments (non-atomic two-file transitions). Pair-settled.
- **Stream identity:** normalized proxy URL + metric id + model id (never `display_name` when a model id exists). Pair-settled.
- **Pace:** CodexBar's linear `UsagePace` (`Sources/CodexBarCore/UsagePace.swift`): expected = elapsed/duration·100, delta = used − expected, rate = used/elapsed, stages by |delta| ≤ 2 / 6 / 12. Labelled as average pace since window start. Expected ≥ 3 % guard applies to session only (`Sources/CodexBar/UsagePaceText.swift`, `sessionPace`). No pace/ETA for stale, unknown, past-reset or implausible windows, nor for Extra usage. Pair-settled, verified in code.
- **Visual reference values** (CodexBar 0.77.1): menu width 310; card layout constants in `UsageMenuCardLayout.swift`; progress bar height 6, capsule, track `tertiaryLabelColor.opacity(0.22)` (`UsageProgressBar.swift`); Claude accent RGB(204,124,94) (`ClaudeProviderDescriptor.swift`); icon geometry in `IconRenderer.swift`; wording in `UsagePaceText.swift` and `UsageFormatter.swift`.
- **Owner acceptance:** every owner visual check records either "approved" or concrete rejected deltas in the task's commit message or `docs/acceptance.md`; "looked at it" does not close a task.
- **License:** CodexBar is MIT; substantially copied code keeps its copyright notice.

## Context
- Git repository with `main` holding `.gitignore`, `AGENTS.md` (collaboration rules, skills) and `CLAUDE.md`; no Swift code yet.
- Project-local skills (git-ignored, see `AGENTS.md`): `swiftui-expert-skill`, `swift-concurrency`, `swift-testing-expert`. Implementers and reviewers use them for SwiftUI, Swift 6 concurrency and Swift Testing work.
- Reference sources (read-only, outside the repo, never built or run): CodexBar at `/tmp/codexbar-src`, commit `a91669f2ff972ac2a549ed8c20725fdc1a510194` (version.env 0.77.1); proxy at `/tmp/ccp-src/claude-code-proxy`, commit `da4ce5c6ce5781a8a1502493c83250e18ca9b612`. If `/tmp` was cleaned, clone each repo into a fresh empty directory and check out exactly these commits.
- Toolchain: Apple Swift 6.3.3; `xcode-select -p` is `/Library/Developer/CommandLineTools`; `/Applications/Xcode.app` exists. Task 1 settles the test framework and, if CommandLineTools cannot run it, the `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` prefix; the result goes into Execution → Validation so later tasks reuse it. Global `xcode-select` stays untouched.
- Real response shape: design doc "Факты" section. Fixtures are sanitized (no account identifiers).

## Execution
- **Implementer:** the `implementer` agent definition (Opus at medium). Task 2 and the owner parts of Tasks 6–9 are executor exceptions (see each task).
- **Validation:** `swift build`; `swift test` (whole suite; uses injected fakes, no real Keychain or network); `Scripts/package_app.sh` producing `build/ClaudeBar.app` for any task touching the app target. Exact test command (settled in Task 1): `make test`, which runs `swift test` with the Command Line Tools Swift Testing paths: `swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -F -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib`. Plain `swift test` fails under CLT ("no such module 'Testing'"), and `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` fails until the owner accepts the Xcode license (`sudo xcodebuild -license`); with Xcode active use `make test TEST_FLAGS=`. No formatter/linter configured.
- **Commits:** one per task, `type(scope): subject`, after Codex's review.

## Tasks

### Task 1: Buildable app skeleton with Settings, Keychain secret and launch-at-login
**Discuss:** yes

**Agreed approach (Claude and Codex, 2026-10-17):**
- AppKit entry (`main.swift` + `AppDelegate`, accessory activation policy), not a SwiftUI `App`. Settings is an owned `NSWindowController` hosting a SwiftUI form (proxy URL, secret `SecureField`, Launch at login, Save), opened from the status menu with app activation.
- Three SPM targets: `ClaudeBarCore` (library), `ClaudeBar` (executable), `ClaudeBarCoreTests`; tools 6.2, Swift 6 mode, macOS 14.
- Core: `ProxyEndpoint` accepts http or https, rejects userinfo, query and fragment, keeps a path prefix and joins `api/oauth/usage` by path components with or without a trailing slash. `SecretStore` protocol (read/write/delete) with `KeychainSecretStore` (generic password, service = bundle ID, account `proxy-secret`) that distinguishes a missing item from a read failure; in-memory and throwing fakes for tests. `SettingsStore` over an injected `UserDefaults` suite.
- Save: validate the draft, perform the Keychain mutation first, and only on success persist and publish the new URL. On failure keep the draft, show an inline error, leave prior committed settings untouched; a denied read is never treated as an empty secret.
- HTTP is allowed with a visible warning that the secret travels unencrypted. Info.plist sets `NSAppTransportSecurity` → `NSAllowsArbitraryLoads = true` and no `NSAllowsLocalNetworking` (it would override the broad exception); HTTPS validation unchanged. A real bundled HTTP fetch is verified in Task 3 or 4.
- Launch at login via `SMAppService.mainApp`; the toggle shows enabled / not registered / requires approval (explanation + Open System Settings) / not found, re-read when Settings opens and when the app becomes active; errors inline.
- `Scripts/package_app.sh`: release build, assembles `build/ClaudeBar.app` with Info.plist (`ru.sdfpro.ClaudeBar`, `LSUIElement`, `LSMinimumSystemVersion` 14.0, `CFBundleVersion` from `BUILD_NUMBER`, default a timestamp), ad-hoc signs with identifier = bundle ID; an `install` subcommand quits a running copy and installs to `~/Applications/ClaudeBar.app`. A Makefile wraps build, test, app, install.
- Swift Testing, settled: it runs under Command Line Tools via `make test` (`swift test` with explicit CLT framework/rpath flags); running under Xcode via `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` is optional once the Xcode license is accepted. The exact command is recorded in Execution → Validation.
- Tests: `ProxyEndpoint` validation and joining, `SettingsStore` persistence, Save ordering with a throwing fake leaving prior settings intact. No real Keychain or network in `swift test`.
**Goal:** an SPM package in the existing repository with `ClaudeBarCore` (library), `ClaudeBar` (executable) and tests; `Scripts/package_app.sh` produces and installs a runnable `ClaudeBar.app` with a placeholder status item, a menu with Settings…/Quit, a Settings window storing the proxy URL in defaults and the secret in Keychain, and a Launch at login toggle via `SMAppService`.
**Starting points:** CodexBar `Package.swift`, `Scripts/package_app.sh`, `Sources/CodexBar/CodexbarApp.swift`, `Sources/CodexBar/StatusItemController.swift`.
**Constraints:** Decisions → Stack, Packaging, Secret storage, Deferred. The approach agreement fixes bundle ID, install path, signing mode and the credential-store protocol. No network fetching in this task. Routine tests use an injected fake credential store. URL validation rejects credentials in URL/query; URL joining with a path prefix is explicit. The existing `.gitignore` already covers build output and local skills; extend it only if needed.
**Done when:**
- [x] `swift build`, `swift test` and `Scripts/package_app.sh` succeed from a clean checkout, and Execution → Validation states the exact test command
- [ ] launching the installed bundle shows a status item and no Dock icon
- [x] Settings persists the URL; the secret round-trips through the credential-store protocol
- [x] tests pin URL validation/joining and Settings persistence against the fake store

Note: implementation is complete; the visible-status-item acceptance (installed bundle) moves to Task 2.

### Task 2: OWNER-RUN — bundle, Keychain and login smoke gate
**Executor:** the primary agent with the owner at the machine; not the implementer subagent. The owner performs Finder launches, Keychain prompts and logout/login; the agent records results and owns any packaging/signing fix, reviewed by Codex.
**Goal:** a recorded gate verdict — PASS, BLOCKED, or OWNER-ACCEPTED LIMITATION — on whether the installed bundle keeps Keychain access across rebuilds and starts at login.
**Starting points:** `Scripts/package_app.sh`, the Settings/credential-store code from Task 1.
**Constraints:** use a dummy Keychain value, never the real secret, in tests and evidence; clean the test item afterwards. Test two distinguishable builds (e.g. different build number) installed at the same stable path, and the exact artifact the login item registers. A new Keychain prompt per rebuild is not PASS. BLOCKED pauses Tasks 3+; setting up a stable local signing identity or changing storage requires an owner ruling, and stable signing is not promised to fix `SMAppService` (Apple TN2206).
**Done when:**
- [ ] owner confirmed the installed ~/Applications/ClaudeBar.app shows a visible status item, its menu opens Settings and Quit, and there is no Dock icon; in Settings, Cmd-V and Cmd-A work in both the URL and secret fields and Cmd-C works in the URL field (the secure field need not allow copying)
- [ ] build A installed, dummy secret saved; build B installed at the same path reads it without a prompt (or the failure is recorded)
- [ ] Launch at login: enable → logout/login → app starts; disable → logout/login → app does not start
- [ ] verdict, builds tested and any signing change recorded in `docs/smoke-gate.md`

### Task 3: Usage client and snapshot model
**Goal:** `ClaudeBarCore` fetches `{proxy}/api/oauth/usage` and returns either a validated `UsageSnapshot` (session, weekly, scoped weeklies, extra usage, each independently available or unavailable) or a typed error carrying a user-facing hint.
**Starting points:** CodexBar `Sources/CodexBarCore/Providers/Claude/ClaudeOAuth/ClaudeOAuthUsageFetcher.swift`, `ClaudeUsageFetcher.swift`, `ClaudeScopedWeeklyLimitMapper.swift`; proxy `server.js` request handler and its error responses; design doc response facts.
**Constraints:** Decisions → Response mapping precedence, Parsing, Error semantics, Secret storage. Headers `x-proxy-secret`, `anthropic-beta: oauth-2025-04-20`, `Accept`/`Content-Type: application/json`; 30 s timeout; no header logging; no secret on cross-origin redirect.
**Done when:**
- [x] sanitized real-response fixture parses into the expected snapshot
- [x] tests cover null/missing/unknown/malformed/non-finite fields, ISO8601 variants (fractional seconds, offsets), each precedence fallback, multiple scoped rows incl. null and whitespace-only model id, duplicate fallback names (ambiguous, not merged), all extra-usage states
- [x] transport-stub tests cover each known proxy error body vs an identical upstream status, timeout, malformed 200, 429 with seconds and HTTP-date `Retry-After`, and redirect without secret forwarding

### Task 4: Refresh coordinator and connection state
**Discuss:** yes

**Agreed approach (Claude and Codex, 2026-10-17):**
- `RefreshCoordinator` in ClaudeBarCore, `@MainActor @Observable`, with an injected `UsageFetching` protocol (prod adapter = `UsageClient.fetchUsage(endpoint:secrets:)`, secret read per attempt) and an injected Sendable `RefreshClock` (`now`, cancellable `sleep(until:)`; tests use a manual clock). One driver `Task`; a pure `RefreshPolicy.decide(trigger:state:now:)` holds the trigger rules for table tests.
- Triggers: launch, timer, menuOpen, wake, manualRefresh, checkConnection, configChanged(urlChanged). Auto modes fetch on launch, timer, wake, and menuOpen when the last attempt is older than 30 s. Manual mode: no timer, launch/menuOpen/wake ignored, only manualRefresh and checkConnection fetch; configChanged bumps generation without fetching.
- Trigger and config intake is synchronous on the main actor: policy, in-flight classification and generation bumps apply immediately when called, even while the driver awaits a fetch; the AsyncStream only wakes the driver.
- One request in flight. During a flight, manualRefresh/checkConnection/configChanged collapse into a single follow-up (re-checked against policy afterwards); timer/menuOpen/wake are dropped. No trailing loops.
- 429: `cooldownUntil = retryAfter` if strictly after now, else now + 5 min (as CodexBar `ClaudeOAuthUsageRateLimitGate.recordRateLimit`); it blocks every trigger including manual. Transient failures (timeout, network, serverError, upstreamUnreachable) back off `min(30 s · 2^(n-1), interval)` in auto modes, reset on success; manual never schedules retries. Non-transient failures keep the normal interval. Next timer deadline = attempt start + interval (or backoff/cooldown deadline); an interval change re-arms from the last attempt.
- `generation` bumps on any URL or secret change; results from an older generation are discarded. URL change also clears the snapshot and per-metric last-known values immediately; secret change keeps them and, in auto modes, triggers a fetch. Config comes from `SettingsModel` as committed endpoint + a secret revision counter; no secret value reaches the coordinator.
- Exposed state: connection (idle/loading/succeeded/failed(error)), lastSuccessAt, lastAttemptAt, nextAttemptAt (auto) / retryAvailableAt (manual during cooldown), cooldownUntil; derived phase first-load / first-failure / failure-with-cache / fresh. Per metric (session, weekly, each scoped key, extra) a last-known value with its observation time and a presentation fresh / stale(value, lastSeenAt) / waitingForFreshData / unavailable, plus `allowsForecast` (fresh with a future reset only). A metric missing from the latest snapshot can show its prior value as stale, never fresh; reset/waiting is judged on each metric's own last-known value.
- Stale when snapshot age > 2 × interval (auto) or > 10 min (manual), or the latest attempt after the last success failed. The driver keeps a presentation deadline (earliest stale-by-age moment and cached `resetsAt`) in every mode and re-publishes observable state at it without fetching.
- Placeholder UI until Tasks 6/7: status item text like `S 88% · W 99%` (remaining), `—` when unknown, marked when stale; menu rows for Session/Weekly/scoped with reset, Updated/Stale since, error hint row, Next attempt at (auto) / Retry available at (manual cooldown), Refresh, Settings…, Quit. AppDelegate forwards wake (`NSWorkspace.didWakeNotification`) and menu-open; Settings gains a refresh-interval picker (manual/1/2/5/15/30, default 5) persisted in SettingsStore and a Check connection button.
- Tests: policy tables; coalescing (menu opens during flight → no extra fetch; manual during flight → exactly one follow-up); slow A → save URL B → three Refresh → A discarded and one follow-up against B; throttle; wake; cooldown incl. repeated 429 with Retry-After 0 and a past date; backoff capped and reset; manual mode; late response discarded after URL and after secret change; URL change hides values, secret change keeps them; phases; stale by age and waiting-for-fresh-data asserted as published-state changes on fake-clock advance; per-metric availability.
- The "packaged app shows real percentages" box needs the owner's secret in Settings and is checked by the owner (the implementer never reads secrets).
**Goal:** a single coordinator owns fetching per the Refresh contract and exposes connection state and per-metric availability separately from the last successful snapshot; the placeholder status item and menu show live values, staleness, the error row and next attempt time.
**Starting points:** client from Task 3; CodexBar `UsageStore+Refresh.swift`, `ClaudeOAuthUsageRateLimitGate.swift`.
**Constraints:** Decisions → Refresh contract, Error semantics. Injectable clock and transport. The approach agreement writes down trigger/coalescing, cooldown vs backoff, stale-age and source-switch behavior before code.
**Done when:**
- [x] fake-clock tests pin: coalescing without perpetual trailing requests, menu-open throttle, wake fetch, cooldown blocking every trigger, bounded backoff, manual mode (no timer/launch/menu/wake fetch, "retry available at" wording), late-response discard on URL and on secret change, old-source hiding on URL change only
- [x] tests pin states first-load / first-failure / failure-with-cache / fresh, stale-by-age, per-metric availability, and a cached window passing its reset with no fetch → waiting-for-fresh-data, no forecast
- [ ] the packaged app shows real percentages from the proxy

### Task 5: SQLite history wired to the coordinator
**Discuss:** yes

**Agreed approach (Claude and Codex, 2026-10-17):**
- `HistoryStore` owns one SQLite connection (`import SQLite3`, small adapter) on a private serial `DispatchQueue`; writes enqueue and return, reads are `async` on the same queue. File `~/Library/Application Support/ClaudeBar/history.sqlite`, path injectable. Default rollback journal.
- Schema v1 (`PRAGMA user_version = 1`): `streams(id, source, metric session|weekly|scoped, model_key '' or scoped provenance key, UNIQUE(source, metric, model_key))`; `runs(id, stream_id, first_seen_at, last_seen_at, used_percent REAL, reset_kind at|notStarted|unknown, resets_at, closed_at, close_reason changed|reset|failure|missing|source|gap)` with a partial unique index allowing one open run per stream; `breaks(id, source, at, reason failure|missing|source, stream_id NULL for global)`; `meta(key, value)` holding `cleared_at`. Extra usage is not recorded.
- Event contract: an injected `HistoryRecording` (default no-op) is called synchronously on the main actor from `RefreshCoordinator.finishFetch` only after the generation check passes and the result is not cancelled (`.failure(.cancelled)` excluded explicitly): `.observed(source, at, interval, snapshot)`, `.failed(source, at)` for every accepted failure including 401/403, and `.sourceChanged(oldSource, at)` from `configure` on a URL change. `at` is the acceptance time, never the attempt start. Source = `ProxyEndpoint` normalized string.
- Run rules, one `BEGIN IMMEDIATE` transaction per event: no open run → open; equal `used_percent` (exact Double) and equal reset identity (same kind and `abs(Δresets_at) < 120 s`, as CodexBar `areEquivalentPlanUtilizationResetBoundaries`) and gap within `maxJoinGap` → extend `last_seen_at`; value change → close `changed` + open; reset change → close `reset` + open; `at - last_seen_at > maxJoinGap` (2.5 × captured interval, 10 min in manual) → close `gap` at `last_seen_at` + open. A metric missing/unavailable/ambiguous in a successful observation closes only its stream (`missing`) + break. `.failed` closes all open runs of the source (`failure`) + global break. `.sourceChanged` closes the old source's open runs (`source`) + break. No synthetic heartbeats.
- Write errors: ROLLBACK, publish a nonfatal storage error, and mark the source with a pending discontinuity on the serial queue; the next event for that source first closes its open runs at their own `last_seen_at` (`failure`) and writes a break inside the same transaction; the flag clears only after COMMIT. Lost samples are not replayed.
- Clear history: enqueued on the same queue (FIFO boundary over accepted events); one transaction deletes runs/breaks/streams and sets `meta.cleared_at`; events with `at < cleared_at` are ignored; a result accepted after Clear is a new observation. Settings "Clear history…" with confirmation; only ClaudeBar's rows.
- Retention: on open and at most daily on write, delete closed runs and breaks older than 365 days and orphan streams. Downsampling belongs to Task 8.
- Open failures: `user_version > 1` → refuse, file untouched; open error / not a database / `PRAGMA quick_check` failing → unavailable, file untouched, never deleted or recreated; empty file → create v1. While unavailable, recording is a no-op, live usage continues, the state shows as a nonfatal row in the menu/Settings.
- Queries for Task 8: `streams()`, `runs(streamID:from:to:)`, `breaks(source:from:to:)`.
- Tests as listed in the Done-when, plus: failed-event rollback followed by an equal observation does not extend the old run; repeated resets within one hour; unique index blocks a second open run; corrupt and newer-schema files are byte-identical afterwards.
**Goal:** every accepted coordinator result and every observed failure is recorded per stream in SQLite under `~/Library/Application Support/ClaudeBar/`, queryable for charts, with retention and Clear history.
**Starting points:** coordinator from Task 4, snapshot model from Task 3; CodexBar `PlanUtilizationHistoryStore.swift`, `UsageStore+PlanUtilization.swift` (reset-boundary ideas only).
**Constraints:** Decisions → History storage, Stream identity, Single account. The approach agreement fixes schema v1, the event contract between coordinator and store, and Clear history's cutoff. Close/open of a run happens in one transaction. Clear history is serialized with pending writes so queued older data cannot reappear.
**Done when:**
- [x] end-to-end tests: each accepted result is written once under its captured source/metric identity; discarded or cancelled old-config results are not written; a missing metric breaks only its own stream; a scoped name→id transition starts a new stream; restart reads the same runs
- [x] store tests pin run extension, new run on change, breaks on failure / reset / source change, reset within one hour, gaps, retention cutoff, transaction failure + reopen leaving no duplicate open run, refusal of a newer schema, corruption handling per Decisions
- [x] Clear history in Settings empties only ClaudeBar's store and survives in-flight writes
- [x] a one-year size estimate at 1-minute polling with continuously changing values is recorded in the design doc (informational, not a performance proof)

### Task 6: CodexBar-style menu cards with pace
**Executor:** implementer; the owner visual check at the end is performed by the owner and recorded by the primary agent.
**Goal:** the menu shows quota cards (Session, Weekly, each scoped weekly) with title + "NN% left", progress bar with pace marker, reset text and pace line, an Extra usage card, and Refresh / Settings… / Quit, matching CodexBar's look.
**Starting points:** CodexBar `MenuCardView.swift`, `MenuCardMetricRow.swift`, `UsageMenuCardLayout.swift`, `UsageProgressBar.swift`, `UsageFormatter.swift`, `UsagePaceText.swift`, `Sources/CodexBarCore/UsagePace.swift`.
**Constraints:** Decisions → Pace, Parsing, Refresh contract (staleness, waiting-for-fresh-data), Visual reference values, Owner acceptance, License. Card visibility: scoped rows show regardless of `is_active` (see Decisions → Response mapping precedence), keeping unavailable/ambiguous handling; explicitly disabled extra usage may be hidden; missing/malformed Session or Weekly stays visible as unavailable or shows the prior value marked stale with its timestamp; a previously known optional metric that goes missing is never reclassified as inactive/disabled. Extra usage shows amount / cap / currency or its specific state, with no reset or pace unless provided. No chart or storage changes in this task.
**Done when:**
- [x] pace tests pin zero elapsed, 0 % and 100 % used, past and far-future reset, threshold edges 2/6/12, session-only 3 % guard
- [x] formatter and card-visibility tests pin reset/pace wording and the visibility rules above
- [ ] owner compared the menu with CodexBar's Codex card in light and dark mode; approval or rejected deltas recorded

### Task 7: Menu bar icon with Claude watermark
**Executor:** implementer; owner visual approval recorded by the primary agent.
**Goal:** the status item renders the two-bar template icon with the gray Claude starburst watermark and bar knockout, distinct unknown and stale variants, and an accessibility description.
**Starting points:** CodexBar `Sources/CodexBar/IconRenderer.swift` (PixelGrid, bar rects, alphas, stale dimming).
**Constraints:** Decisions → Icon, Owner acceptance, License. Template image; fill = remaining.
**Done when:**
- [ ] deterministic raster tests at 1x and 2x for 0 / 50 / 100 / unknown / stale, including no logo pixels inside the knockout zone
- [ ] VoiceOver label states both percentages or the unknown/stale condition
- [ ] owner inspected the icon on light and dark menu bars next to CodexBar; approved alpha/gap or recorded deltas

### Task 8: Usage history charts submenu
**Executor:** implementer; owner visual approval recorded by the primary agent.
**Goal:** a "Usage history" submenu shows a burn-down chart of the current window (ideal dashed line vs observed) with a Session/Weekly/scoped picker, and a bar chart of observed peaks per past window.
**Starting points:** CodexBar `QuotaBurndownChartMenuView.swift`, `QuotaBurndownModel.swift`, `PlanUtilizationHistoryChartMenuView.swift`, `StatusItemController+UsageHistoryMenu.swift`; history store from Task 5.
**Constraints:** Decisions → History storage, Visual reference values, Owner acceptance, License. Never draw a line across a break or gap; runs are plotted by their observed endpoints. Peaks are labelled as observed peaks. Past windows exist only where reset boundaries were observed; windows without observations are shown as unobserved, never 0 %, and are not reconstructed.
**Done when:**
- [ ] chart-model tests on synthetic fixtures pin current-window filtering, segment splits at breaks/gaps, a reset, multiple past windows, unobserved windows, all-missing data, downsampling
- [ ] a debug fixture mode lets the owner see both charts populated without waiting for real history
- [ ] owner reviewed both charts on the fixtures (real history optional); approval or rejected deltas recorded

### Task 9: Documentation and final acceptance
**Executor:** primary agent; owner confirms the story checks.
- [ ] `README.md` describes build/install, Settings, the proxy requirement, data location, Clear history, the undetectable-account-switch limitation and the best-effort scoped-limit identity; the design doc is marked as background superseded by README and code where they differ
- [ ] every story and every Done-when above holds, owner-confirmed where marked
- [ ] `swift build`, full `swift test` and `Scripts/package_app.sh` pass from a clean checkout of the final state; result recorded in the final commit message

## Post-Completion
Outside this plan, owner-coordinated only:
- Optionally propose upstream to CodexBar a configurable base URL + custom header for the Claude provider; if accepted, ClaudeBar could be retired.
