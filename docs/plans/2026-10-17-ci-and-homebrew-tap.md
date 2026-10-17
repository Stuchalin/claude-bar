# ClaudeBar: GitHub CI, tagged releases and a Homebrew tap

**Executor:** `/peer-planning:exec`. A subagent implements each task and Codex reviews the diff
before the task closes; a task marked `**Discuss:** yes` has its approach agreed with Codex first.

## Stories
- As the owner, every push and pull request to ClaudeBar on GitHub runs the build and the tests, so a broken change is visible before I install it.
- As the owner, pushing a `vX.Y.Z` tag publishes a GitHub release with a ready-to-install `ClaudeBar.app` zip and its checksum.
- As the owner, I install and update ClaudeBar with Homebrew from my own tap, the same way as weeek-cli, and the tap follows new releases without manual edits.

## Overview
- ClaudeBar (this repository, `main`) builds and installs only from a local checkout today; there is no remote.
- The owner's other projects set the pattern: `Stuchalin/weeek-cli` has `.github/workflows/ci.yml` (checks on every push/PR, release build and `gh release create` on `v*` tags, `.sha256` sidecars), and `Stuchalin/homebrew-weeek-cli` has `Formula/weeek.rb`, `scripts/update-formula.sh` (renders the formula from the latest release, verifies digests, rewrites only on change) and an hourly `update-formula.yml` workflow that commits the result.
- This plan reproduces that pattern for a macOS `.app`: CI and releases in `Stuchalin/claude-bar`, a Cask in `Stuchalin/homebrew-claude-bar`.

## Decisions
- **Repositories:** `Stuchalin/claude-bar` (this repo) and `Stuchalin/homebrew-claude-bar` (the tap), both **public** — owner ruling 2026-10-17. Public is what lets `brew` download releases without a token.
- **Who publishes:** the orchestrator creates both public repositories, pushes `main`, and pushes tags and publishes releases (first `v0.1.0`) itself with the local `gh` login (account `Stuchalin`, scopes `repo`, `workflow`), without the owner present — owner ruling 2026-10-17. Installation, first launch and upgrade acceptance on the owner's Mac remain owner-run. Before acting, confirm the active `gh` identity without printing the token.
- **Pattern source:** mirror weeek-cli's CI and homebrew-weeek-cli's tap structure: pinned action SHAs with version comments, `permissions: contents: read` by default and `write` only on the release job, `.sha256` sidecars, `gh release create --verify-tag --generate-notes`, an updater that renders, verifies digests and rewrites only on change, a scheduled + `workflow_dispatch` workflow that commits as `github-actions[bot]`. One strict tag grammar everywhere: `^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$` (the weeek updater's looser regex is not copied). Evidence: the files named in Overview, read 2026-10-17. Pair-settled.
- **Toolchain:** `Package.swift` is swift-tools-version 6.2. On GitHub, `macos-15-arm64` (image 20260907.0337.1) ships `/Applications/Xcode_26.2.app` (Swift 6.2.3) while its default Xcode is 16.4 (Swift 6.1), so CI jobs set `DEVELOPER_DIR=/Applications/Xcode_26.2.app/Contents/Developer`, print `xcodebuild -version` and `swift --version` first, and run `make test TEST_FLAGS=`. Sources: actions/runner-images `images/macos/macos-15-arm64-Readme.md`, developer.apple.com/xcode/system-requirements. Re-verify the image before Task 2 executes. Pair-settled.
- **Universal binary:** release artifacts are arm64 + x86_64. SwiftPM 6.2 with several `--arch` switches to the Xcode build system (swift-package-manager `Sources/CoreCommands/Options.swift`, swift-6.2-RELEASE), so the release path uses full Xcode; the everyday native build under Command Line Tools stays as it is. If two native builds are joined with `lipo` instead, both slices use the same deployment target and signing happens after joining. Pair-settled.
- **Cask, not formula:** ClaudeBar is an `.app`, so the tap ships `Casks/claudebar.rb` (token `claudebar`, `app "ClaudeBar.app"`), installed with `brew install --cask stuchalin/claude-bar/claudebar`. A fully qualified install grants tap trust for that cask (docs.brew.sh/Tap-Trust).
- **Gatekeeper:** releases stay ad-hoc signed, not notarized. Homebrew keeps the quarantine attribute and current `brew install` has no `--no-quarantine` (Homebrew `Library/Homebrew/cmd/install.rb`, docs.brew.sh/Manpage). The Cask stays declarative — no `postflight` `xattr` (flight blocks are only temporarily tolerated in third-party taps, docs.brew.sh/Cask-Cookbook) — and carries a short caveat pointing to Privacy & Security → Open Anyway (support.apple.com/102445). Whether first launch actually needs that step is verified on the owner's Mac, not assumed. The owner accepted ad-hoc signing and possible Keychain re-prompts after updates (`docs/smoke-gate.md`). Pair-settled.
- **Install location:** `/Applications/ClaudeBar.app` (Homebrew's default appdir) becomes the single supported location; `~/Applications` was only the pre-tap local install. `Scripts/package_app.sh install` and the Settings hint (`SettingsView`, launch-at-login `.notFound` text naming `make install` and `~/Applications`) follow. Moving from the old copy keeps history and the Keychain item (they are not inside the bundle); the old copy is removed by the owner after the brew copy works. Pair-settled.
- **Version and build number:** the tag sets `CFBundleShortVersionString` (`X.Y.Z`); today `Scripts/package_app.sh` hardcodes `MARKETING_VERSION="0.1.0"` and defaults `CFBundleVersion` to a timestamp. Release builds derive `CFBundleVersion` by a fixed rule that increases with every release (Task 1 defines it, e.g. from the version or the CI run number); local builds may keep the timestamp.
- **Scheduled updater lifetime:** GitHub disables scheduled workflows in public repositories after 60 days without activity (docs.github.com, "Disable and enable workflows"); the tap README says how to re-enable or run it manually; no keepalive commits.
- **Local-only paths:** `/.peer-planning/` and `/.revmux/tasks/` move from `.git/info/exclude` into the committed `.gitignore` before the first public push (checked 2026-10-17: neither path is tracked or in history).
- **No third-party build tools:** SPM + `Scripts/package_app.sh` + `Makefile`; no GoReleaser, no Xcode project.

## Context
- Build/test entry points: `Makefile` (`build`, `test` with Command Line Tools `TEST_FLAGS`, `app`, `install`), `Scripts/package_app.sh` (release build via `swift build -c release` and `--show-bin-path`, Info.plist, ad-hoc signing, notices and icon checks), `Package.swift`.
- App icon: `Assets/AppIcon/`. Launch-at-login text: `Sources/ClaudeBar/SettingsView.swift` (`LaunchAtLoginRow` / `.notFound` case), `Sources/ClaudeBar/LaunchAtLoginModel.swift`.
- Pattern files (outside this repo, read-only): `/Users/denisstuchalin/work/sdf/weeek-cli/.github/workflows/ci.yml`, `/Users/denisstuchalin/work/sdf/homebrew-weeek-cli/Formula/weeek.rb`, `.../homebrew-weeek-cli/scripts/update-formula.sh`, `.../homebrew-weeek-cli/.github/workflows/update-formula.yml`.
- The tap repository does not exist yet; Task 4 creates it at `/Users/denisstuchalin/work/sdf/homebrew-claude-bar` with its own `git init`.

## Execution
- **Implementer:** the `implementer` agent definition (Opus at medium). Task 3 and the publication part of Task 6 are executed by the primary agent; acceptance on the owner's Mac is performed by the owner.
- **Validation:** `make build`, `make test`, `Scripts/package_app.sh`; workflows: `actionlint` when available (else record why not) plus a YAML parse; shell: `bash -n` and `shellcheck` when available; Cask: `brew style` and `brew audit --cask` on the local tap when possible.
- **Commits:** one per task, `type(scope): subject`, after Codex's review. Tap tasks commit in the tap repository.

## Tasks

### Task 1: Release-ready universal packaging
**Discuss:** yes

**Agreed approach (Claude and Codex, 2026-10-17):**
- New mode `Scripts/package_app.sh release <X.Y.Z>` (and `make release VERSION=X.Y.Z`); strict grammar `^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$` checked before any build, invalid → exit 64.
- Two single-arch builds (`swift build -c release --arch arm64|x86_64 --product ClaudeBar`) with separate `--scratch-path`s, each binary taken from `--show-bin-path` called with identical flags; `lipo -create`, assemble, ad-hoc sign once after joining. Works under Command Line Tools here (Xcode license not accepted; multi-`--arch` would need the Xcode build system) and in CI.
- Release sets `CFBundleShortVersionString` and `CFBundleVersion` to `X.Y.Z` (dotted values valid per Apple's CFBundleVersion documentation); local builds keep 0.1.0 and the timestamp.
- Artifact `dist/ClaudeBar-X.Y.Z.zip` (`ditto -c -k --keepParent`) plus `dist/ClaudeBar-X.Y.Z.zip.sha256` in `<hash>  <filename>` form; `dist/` git-ignored.
- `Scripts/verify_release.sh <zip>` (reused by CI): the expected version comes from the release input / the strict file name, never from the bundle being checked; unzip to temp; exactly one top-level `ClaudeBar.app`; both bundle versions equal it; executable bit; `codesign --verify --strict`; `lipo -archs` arm64 + x86_64; each slice's minos ≤ 14.0; sidecar digest matches. A 0.1.0 bundle packaged as 0.1.1, or a missing Intel slice, must fail.
- `install` → `/Applications/ClaudeBar.app`; Settings `.notFound` hint and README follow. No real install run as a test.
- If the x86_64 cross-build fails locally, an arm64-only dry run does not close Task 1; universal validation stays outstanding until it passes in CI.
**Goal:** a release entry point produces, for a given version, a universal `ClaudeBar.app` zipped as `ClaudeBar-<version>.zip` with a `.sha256` sidecar, ad-hoc signed, and verified from the unpacked zip; local native builds and install keep working, with install now targeting `/Applications`.
**Starting points:** `Scripts/package_app.sh`, `Makefile`, `README.md`, `Sources/ClaudeBar/SettingsView.swift` (launch-at-login `.notFound` text).
**Constraints:** Decisions → Toolchain, Universal binary, Version and build number, Install location, No third-party build tools. `--show-bin-path` must use the same arch/build flags as the build, or a native binary gets packaged. Do not run a real install on the developer Mac as a test.
**Done when:**
- [x] the unpacked release zip contains exactly one top-level `ClaudeBar.app` with the given `CFBundleShortVersionString`, the release `CFBundleVersion` rule applied, an executable binary, `codesign --verify --strict` passing, `lipo -archs` showing arm64 and x86_64, and each slice's minimum macOS not above 14; the sidecar digest matches the zip
- [x] an invalid version string is rejected before building
- [x] the native local build keeps its bundle ID, Resources (notices, icon), version handling and signing checks; `install` targets `/Applications/ClaudeBar.app`
- [x] the Settings `.notFound` hint and README's install section name `/Applications` and the tap install (tap command may be marked "after release" until Task 5)

### Task 2: CI workflow for checks and tagged releases
**Discuss:** yes
**Goal:** `.github/workflows/ci.yml` runs build and tests on every push and pull request, and on a strict `vX.Y.Z` tag builds Task 1's release artifact and publishes a GitHub release with the zip and its sidecar; `.gitignore` gains the local-only paths.
**Starting points:** weeek-cli `.github/workflows/ci.yml`; `Makefile`; Task 1's release entry point.
**Constraints:** Decisions → Pattern source, Toolchain, Version and build number, Local-only paths. The approach agreement fixes action SHAs, caching (if any), and how the tag is checked against the built bundle version. Release jobs never run on non-tag pushes.
**Done when:**
- [ ] the workflow parses and passes `actionlint` (or the reason is recorded)
- [ ] checks job pins the Xcode 26.2 developer dir, logs `xcodebuild -version` and `swift --version`, runs build and `make test TEST_FLAGS=`
- [ ] release jobs are gated on the strict tag grammar and need the checks; the release uploads exactly the zip and its sidecar via `gh release create --verify-tag --generate-notes`, after confirming the bundle version equals the tag
- [ ] `.gitignore` contains `/.peer-planning/` and `/.revmux/tasks/`
- [ ] README says CI exists and that pushing a `vX.Y.Z` tag cuts a release

### Task 3: Publish the repository and the first release
**Executor:** the primary agent (orchestrator), not the implementer subagent; authorized by Decisions → Who publishes.
**Goal:** `Stuchalin/claude-bar` exists on GitHub (public) with `main` and the execution branch `ci-and-homebrew-tap` pushed, CI green on the branch, and release `v0.1.0` published from a tag on the branch head (the owner asked for execution in a separate branch; `main` gets the branch when it lands).
**Constraints:** Decisions → Repositories, Who publishes, Local-only paths. The proxy secret must never be published.
**Done when:**
- [ ] a secret scan over every ref to be pushed and the final tree is recorded (tool, scope, redacted result); "clean" means no findings by that scanner, not proof of absence
- [ ] `.peer-planning/` and `.revmux/tasks/` are neither tracked nor in history
- [ ] repository created, `main` and the branch pushed, CI checks green on the branch (run URL recorded)
- [ ] no existing `v0.1.0` tag or release is overwritten (checked first; a rerun reuses or stops); tag `v0.1.0` pushed, release published, the downloaded zip matches its sidecar and passes the Task 1 checks after unpacking

### Task 4: Tap with the Cask
**Discuss:** yes
**Goal:** a local tap repository at `/Users/denisstuchalin/work/sdf/homebrew-claude-bar` with `Casks/claudebar.rb` for release `v0.1.0` and a short README with install, upgrade and the Gatekeeper caveat.
**Starting points:** homebrew-weeek-cli `Formula/weeek.rb`; docs.brew.sh Cask Cookbook.
**Constraints:** Decisions → Cask, Gatekeeper, Install location. The approach agreement fixes the stanzas (`version`, `sha256`, `url`, `name`, `desc`, `homepage`, `depends_on macos`, `app`, `caveats`, `zap` for `~/Library/Application Support/ClaudeBar` and the preferences domain; the Keychain item stays the user's) and `livecheck` if useful.
**Done when:**
- [ ] `brew style` and `brew audit --cask` on the local tap pass, or each remaining offense is explained
- [ ] the Cask's `sha256` equals the `v0.1.0` sidecar and the downloaded zip
- [ ] the tap README has install and upgrade commands, the caveat, and that the app lives in `/Applications`

### Task 5: Tap auto-updater
**Goal:** `scripts/update-cask.sh` renders the Cask from the latest ClaudeBar release, verifies the zip digest against its sidecar, and rewrites only on change; `.github/workflows/update-cask.yml` runs it on a schedule and on demand and commits as `github-actions[bot]`.
**Starting points:** homebrew-weeek-cli `scripts/update-formula.sh`, `.github/workflows/update-formula.yml`.
**Constraints:** Decisions → Pattern source (strict tag grammar), Scheduled updater lifetime. The zip is always verified before any rewrite. Tests use stubbed `gh`/`curl` fixtures, never real publications.
**Done when:**
- [ ] fixture tests cover: change → rewrite; repeat → no-op; malformed tag, digest mismatch, missing asset and network failure → non-zero exit with the Cask unchanged
- [ ] the workflow parses (`actionlint` or recorded reason); `bash -n`/`shellcheck` clean
- [ ] the tap README explains re-enabling the schedule after GitHub disables it and running it manually

### Task 6: Publish the tap; OWNER-RUN install and upgrade check
**Executor:** the primary agent publishes the tap and cuts the second release unattended; the owner performs the install and upgrade checks on their Mac.
**Goal:** `Stuchalin/homebrew-claude-bar` is public; the owner installed `v0.1.0` from the tap, then the updater proved a real update to `v0.1.1` by itself, and the owner upgraded to it.
**Constraints:** Decisions → Who publishes, Gatekeeper, Install location. Strict order, a technical dependency of the check rather than a permission gate: publish the tap at `v0.1.0` → owner installs and confirms → only then cut `v0.1.1` (a plain version bump) → updater commit → owner upgrades. If the owner is unavailable, the task stays open with outstanding acceptance and `v0.1.1` is not cut ahead.
**Done when:**
- [ ] tap repository created and pushed with the `v0.1.0` Cask; a `workflow_dispatch` run succeeds (run URL)
- [ ] owner: install from the tap (old `~/Applications` copy quit first) runs the brew copy from `/Applications` with `CFBundleShortVersionString` 0.1.0, live data, settings and history kept; whether "Open Anyway" was needed is recorded
- [ ] after that confirmation, release `v0.1.1` is cut and the updater commits the new version and hash by itself (commit URL)
- [ ] owner: `brew upgrade --cask claudebar` runs 0.1.1 with data kept; launch at login re-enabled from the brew copy and checked after a logout/login; the old `~/Applications` copy removed

### Task 7: Verify acceptance and documentation
- [ ] every story and every Done-when above holds, owner-confirmed where marked; anything SKIPPED stays listed as outstanding rather than counted as met
- [ ] ClaudeBar README and the tap README describe the current state only; results recorded in the final commit message

## Post-Completion
- Consider a Developer ID certificate and notarization if Gatekeeper friction or Keychain re-prompts become annoying.
