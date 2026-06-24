---
satisfies: [R2, R3, R8, R9, R10]
---

## Description
Implement the **read-only SessionStart hook** that resolves the current user via git identity and surfaces threads where it's their turn, and wire it into the scaffolded `.claude/settings.json` alongside the existing Stop hook. **Early proof point** — proves a project-level SessionStart hook reliably injects context.

**Size:** M
**Files:** `plugins/init-project/templates/.claude/hooks/collaboration-inbox.sh` (new), `plugins/init-project/templates/.claude/settings.json`

## Approach
- **Hook script** mirrors `claude-md-reminder.sh` (self-locating via `${BASH_SOURCE[0]}`/`dirname`; reads + ignores stdin JSON) BUT uses `set -uo pipefail` (NOT `-e`) like `statusline.sh:13-34` — it runs tolerant `git`/`jq` probes that may exit non-zero. ALWAYS `exit 0`; never blocks.
- **Identity (three cases, per R3):** read at the **project root** — `project_root="$(cd "$claude_dir/.." && pwd)"`, then `git -C "$project_root" config --get user.email`, guarded (`|| true`) — the SINGLE match key (`user.name` display-only; resolves repo-local→global). Match the email against the fixed `team.md` markdown table — skip the header row, the `|---|` separator row, and the fake placeholder example row (no real `user.email` matches it); trim cells. (a) **no `user.email`** (even if `user.name` set) → silent; (b) **email present but not in `team.md`** → brief "register yourself" advisory **emitted in the SessionStart `additionalContext` JSON envelope** (same shape as pending output), attribute nothing; (c) **email in `team.md`** → recognized, proceed.
- **Surface, routed by turn (latest-turn-wins, streaming parse):** scan each `docs/collaboration/*.md` **top-to-bottom** — a `## thread:` header starts the current thread (carrying its `id`/`asker`/`assignee`), and subsequent `### turn` lines belong to that thread until the next header (never mix turns across threads). For each thread take the **highest-`<n>` turn** and route ONLY off that latest turn's status — surface to the `assignee` when it's `awaiting-assignee`, to the `asker` when it's `awaiting-asker` (a superseded earlier status must NOT re-alert). Match the current identity's **handle** against those header handles. Emit via SessionStart **`additionalContext`** JSON (`{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"…"}}`) so it reaches the session (project-level settings — NOT a plugin hook, per issue #16538). **JSON-escape `additionalContext` with a robust encoder** (`jq -Rs`/`jq -n --arg`) since subjects/bodies are free-form markdown (quotes/newlines/backslashes); if `jq` is unavailable, fall back to **raw-text stdout** (also injected by SessionStart) rather than emit malformed JSON. Parse the ASCII `|`-delimited headers (cut/awk-friendly). Terse; silent/empty when nothing pending or no `docs/collaboration/`.
- **Freshness (R10):** ONLY when the hook is already emitting collaboration context, append "as of your last pull" + suggest `git pull` (advisory TEXT in the additionalContext; a no-pending session stays silent — never emit bare freshness). The hook **executes** no `git fetch`/`git pull` (only mentions `git pull` as advice). Guard `@{u}` (`git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null`) before any `rev-list --left-right --count` so no-upstream / detached HEAD never errors.
- **Fast/non-blocking/idempotent:** read the already-pulled tree only; no writes (Claude does writes per the protocol); safe to re-fire on resume/clear/compact.
- **settings.json wiring:** add a sibling `hooks.SessionStart` key (`[{ "hooks": [{ "type":"command", "command":"bash .claude/hooks/collaboration-inbox.sh" }] }]`) — do NOT nest under or replace `hooks.Stop`; preserve `statusLine` + `extraKnownMarketplaces`. settings.json stays valid JSON (no scaffold tokens; copied byte-verbatim).

## Investigation targets
**Required:**
- `plugins/init-project/templates/.claude/hooks/claude-md-reminder.sh:13-30` — hook template (self-location, stdin, exit-0)
- `plugins/init-project/templates/.claude/statusline.sh:13-34` — `set -uo pipefail`, guarded git/jq, graceful degradation
- `plugins/init-project/templates/.claude/settings.json:2-25` — statusLine + extraKnownMarketplaces + hooks.Stop shape to extend
**Optional:**
- Claude Code hooks ref (SessionStart: source field, additionalContext, exit codes, matcher/timeout)

## Key context
- SessionStart `additionalContext` from a *plugin* hook does NOT reach Claude (issue #16538) — but this is a *project* `.claude/settings.json` hook, where stdout/additionalContext IS injected. Proving that in a real session is the point of the proof point.
- `@{u}` is fragile (no upstream / detached HEAD / unfetched) and ahead/behind is only as fresh as the last fetch — guard + label honestly, never fetch in-hook.

## Acceptance
- [ ] `collaboration-inbox.sh`: read-only, `set -uo pipefail`, self-locating, reads+ignores stdin, ALWAYS exits 0, no writes, no network/`git fetch`, idempotent across resume/clear/compact
- [ ] Identity read at project root (`git -C "$project_root" config --get user.email`); email-only key: no `user.email` → silent; email not in `team.md` → register advisory (additionalContext envelope); email in `team.md` → recognized — non-attributing until confirmed; parses the fixed `team.md` table
- [ ] `additionalContext` is JSON-escaped via a robust encoder (jq); jq-absent → raw-text stdout fallback (never malformed JSON)
- [ ] Surfaces by turn: assignee sees `awaiting-<them>`, asker sees own `awaiting-asker`; emitted via SessionStart `additionalContext`; silent when nothing pending / no `docs/collaboration/`
- [ ] Freshness ("as of last pull" + suggest `git pull`) appears ONLY alongside surfaced context; no-pending stays silent; `@{u}` guarded so no-upstream/detached-HEAD never errors
- [ ] `settings.json` gains `hooks.SessionStart` as a sibling of `hooks.Stop`; `hooks.Stop` + `statusLine` + `extraKnownMarketplaces` preserved; file stays valid JSON
- [ ] Routing is latest-turn-wins: a thread with turns `awaiting-assignee → awaiting-asker → resolved` does NOT alert (verified by .4's behavioral fixture); identity matched by handle against the thread-header asker/assignee
- [ ] `shellcheck` + `bash -n` clean
- [ ] **Manual proof-point evidence:** record a real scaffolded session where a pending fixture thread's advisory appears via SessionStart `additionalContext` (separate from the automated output-shape tests in .4)

## Done summary
_(filled on completion)_

## Evidence
_(filled on completion)_
