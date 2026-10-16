# ClaudeBar — agent guide

macOS menu bar app showing Claude subscription limits fetched through the owner's
claude-code-proxy, in CodexBar's visual style. Built jointly by Claude Code and Codex.

## Collaboration
- Plans live in `docs/plans/`, executed with `/peer-planning:exec`: a subagent implements each
  task, Codex reviews the diff before the commit. Tasks marked `**Discuss:** yes` agree the
  approach with Codex first.
- The agent whose pane received the owner's request is the only writer in the worktree; the peer
  stays read-only and reviews.
- Technical decisions are settled between the agents; only product questions go to the owner.
- Communicate with the owner in Russian.

## Skills
Project-local skills are installed with `npx skills` (skills.sh) into `.agents/skills/`
(Codex) with symlinks in `.claude/skills/` (Claude Code); both directories and `skills-lock.json`
are git-ignored, so a fresh checkout reinstalls them:

```bash
npx skills add AvdLee/SwiftUI-Agent-Skill -s swiftui-expert-skill -a claude-code -a codex -y
npx skills add AvdLee/Swift-Concurrency-Agent-Skill -s swift-concurrency -a claude-code -a codex -y
npx skills add AvdLee/Swift-Testing-Agent-Skill -s swift-testing-expert -a claude-code -a codex -y
```

Installed 2026-10-17 with skills CLI 1.7.2 from each repo's default branch (latest at install
time, not pinned). Use them where relevant:
- `swiftui-expert-skill` — SwiftUI views, state, layout, performance.
- `swift-concurrency` — actors, `@MainActor`, `Sendable`, Swift 6 strict concurrency.
- `swift-testing-expert` — Swift Testing structure, traits, async tests.

Codex discovers project skills only when launched from this directory (or below the repo root);
otherwise read the `SKILL.md` files directly.

## Conventions
- Swift tools ≥ 6.2, Swift 6 language mode, macOS 14+, SPM only, no third-party packages.
- One commit per plan task, `type(scope): subject`.
- Never log or commit the proxy secret; it lives only in Keychain.
- Reference sources (read-only, never build or run): CodexBar and claude-code-proxy at the commits
  pinned in the active plan.
