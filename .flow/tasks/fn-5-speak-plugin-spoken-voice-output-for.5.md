---
satisfies: [R5, R13, R23, R24, R25, R29]
---

## Description

Add four slash commands and the `doctor` diagnostic, plus runtime dependency detection. (The fifth command, `/speak:test`, ships with the test task `.6`.)

**Prerequisite:** fn-5.3's container→host proof is green (or the fallback transport is recorded) before this task starts. Also depends on `.4` (shared dep-detection helper) and `.8` (sourceable identity/lock helpers that `doctor --listener` reuses).

**Size:** M
**Files:** `plugins/speak/commands/now.md`, `plugins/speak/commands/on.md`, `plugins/speak/commands/off.md`, `plugins/speak/commands/status.md`, `plugins/speak/bin/speak` (doctor + dep detection)

## Approach

- `commands/*.md` slash-command files (markdown). Claude Code namespaces plugin commands as `/<plugin>:<command-file-name>`, so the `/speak:*` names come free from the plugin name (`speak`) + the file names — `now.md`, `on.md`, `off.md`, `status.md` here, `test.md` in `.6`; no dispatcher work involved. `/speak:now` (`commands/now.md`): the command file instructs Claude to FIRST ask which response to read — a pick list (AskUserQuestion) of the recent assistant responses since things may have accumulated between user prompts (short one-line summaries as labels, most-recent first, e.g. the last 4) — then send the chosen message body **as faithfully as possible** (best-effort verbatim — slash commands are model-mediated, so byte-identity isn't guaranteed for long markdown/code fences) to `"${CLAUDE_PLUGIN_ROOT}/bin/speak"` via a **robust stdin handoff** (a temp file, or a quoted heredoc with a generated unlikely delimiter — raw assistant markdown can contain backticks, code fences, and arbitrary delimiters). Do NOT add a public `speak --last` terminal command (R29 fixes the surface); any transcript-reuse stays a private/sourceable helper only. When forwarding is unreachable, show an **immediate** clear message (bypass the once-per-session debounce, since the user asked explicitly). `/speak:on` → `speak on`; `/speak:off` → `speak off`; `/speak:status` → `speak doctor`.
- `doctor` subcommand (with `speak status` as an alias): the full diagnostic, implementing **C3/C4/C5/C6/C7 exactly** (epic §Canonical Contracts — authoritative; do not restate-and-drift). Rendering: report toggle state (via `plugin_state_dir` per C3 — empty resolve → "toggle unavailable", never a crash), detected mode (C1), `SPEAK_PORT` (validated per C9), listener reachability (bounded retry/backoff per C4, with the correct per-context target — `127.0.0.1` host-side, `host.docker.internal` forward-side), and every dependency labelled **required-for-the-detected-mode vs optional/other-feature** with install guidance. Exit codes and the `--listener` / `--hook` classifications follow **C5 verbatim** (incl.: listener "not needed" in local mode; `jq` informational in default local/forward doctor; `--hook` = readiness-if-enabled with toggle state shown but not gating; `--listener` host-only with the four-way healthy / reachable-but-not-ours / unrelated-or-nothing / live-on-different-port classification, degrading to TCP-reachability-only in a container). Pidfile identity per **C7**, using `.8`'s sourceable identity/lock helpers (`listener_identity_check` rcs 0–6, `listener_stale_cleanup` rc 10 = valid, rc 11 = live-different-port → report "listener running on :recorded, not :checked", markers preserved) — `doctor --listener` never binds; listen `-l` is never pre-probed (C5).
- Dependency detect-and-warn: the **shared helper is owned/implemented by `.4`** (hook preflight needs it first); this task **reuses** it for `doctor`'s rendering + any listener-specific extensions — no duplicated detection logic. `doctor` likewise reuses the **shared `nc` capability helper from `.2`** (C6) — it does not re-derive detection, and the distinct unsupported-capability return is surfaced so "flag unsupported" is never conflated with "listener unreachable" (refused/unreachable/DNS-fail). Tests use fake `nc` stubs for the unsupported-flag vs refused-connection cases.

## Investigation targets
**Required:**
- `plugins/speak/bin/speak` — toggle/forward/reachability from `.1`/`.2`/`.4`
- existing `commands/`-style usage (none in-repo yet — follow Claude Code command-file format)
**Optional:**
- `plugins/init-project/templates/src/system-cli/help.sh:1-43` — self-describing listing pattern for `doctor`

## Acceptance
- [ ] `/speak:now` asks which recent assistant response to read (pick list, most-recent first; auto-speak never asks) and sends the chosen message body best-effort-verbatim via a robust stdin handoff (temp file / unlikely-delimiter heredoc); NO public `speak --last` command added (R29); manual evidence includes a prior response with code blocks/backticks AND a selection of a non-latest response; regardless of toggle; explicit unreachable → immediate clear message, bypassing debounce (R5, R25)
- [ ] `/speak:on` / `/speak:off` toggle auto-speak; `/speak:status` runs the diagnostic (R29, R13)
- [ ] `speak doctor` (aliased by `speak status`) reports toggle state, mode, port, listener reachability, the TTS backend `say`, and `nc`/`base64`/`jq` presence (R24, R13)
- [ ] A missing dependency is named with install guidance; exit codes match **C5 exactly** — spot-checks: default doctor passes a healthy local install with no listener running and with `jq` absent; forward mode fails on unusable `nc` or unreachable listener (R23, R10)
- [ ] Command surface includes `/speak:now`, `/speak:on`, `/speak:off`, `/speak:status`, and the CLI subcommands `speak on`/`speak off` (flag writes) + `speak status` (alias of `speak doctor`) (R29)
- [ ] `doctor` handles unset `${CLAUDE_PLUGIN_DATA}` (reports toggle unavailable, no crash) and uses detected nc flags for the reachability round-trip
- [ ] `speak doctor --hook` = readiness-if-enabled and `doctor --listener` = host-only four-way classification (incl. the C7 rc-11 "listener running on :recorded, not :checked" outcome, markers preserved), both per **C5** (`--listener` uses `.8`'s identity helpers per C7 + `listener_state_dir` per C3, never binds; container/forward → TCP-reachability only)
- [ ] On a Darwin host with missing/broken `say`, `doctor` stays in local context and reports `say` as the missing local dependency (does NOT report a listener-reachability failure) (R22, R24)
- [ ] `SPEAK_PORT` validated + reported per C9
- [ ] An invalid `SPEAK_MODE` (non-empty, not `local`/`forward`) fails clearly in CLI/`doctor`; `SPEAK_MODE=local` on non-Darwin reports "unsupported local TTS backend" (R22)
- [ ] `doctor`/health reachability uses bounded retry/backoff with the correct per-context target, per C4 (never the single fast hook probe)
- [ ] `doctor` reports `nc` **capability** per C6, not mere presence; `-l` reported "not checked; proven by --serve" per C5; forward-mode unusable flag fails (R23); a capability failure is **distinguishable** from an unreachable/refused listener in the output

## Done summary
Added the four /speak:* slash commands (now/on/off/status command files) and replaced the doctor stub in bin/speak with the full C5-exact diagnostic: default doctor with per-mode required-vs-other-feature dependency labelling, --hook readiness-if-enabled, and --listener host-only four-way classification (incl. C7 rc-11 live-different-port, markers preserved) reusing .8's identity helpers verbatim, .4's deps_missing (extended with a listener mode), .2's C6 nc capability cache, and a new C4 retry/backoff reachability wrapper. Codex impl-review: SHIP (first pass).
## Evidence
- Commits: 796fd4bc1a18e486b0ac474f3a2f3f4733c34c43
- Tests: bash -n plugins/speak/bin/speak (and /bin/bash 3.2 -n), shellcheck plugins/speak/bin/speak (clean), shellcheck -x plugins/speak/hooks/stop-speak.sh (clean), manual doctor battery: healthy local exit 0 (no listener, jq absent still 0); missing say -> exit 1 as missing LOCAL dep with no listener failure; SPEAK_MODE=bogus -> INVALID exit 1; forced-local on fake-Linux -> 'unsupported local TTS backend'; bare fake-Linux -> 'UNSUPPORTED host OS'; forward: refused connection -> UNREACHABLE distinct from fake nc without -z -> capability NOT CHECKED; invalid SPEAK_PORT non-fatal local / fatal forward; doctor --hook READY exit 0 with toggle shown not gating; doctor --listener four-way vs REAL --serve on :18765 (healthy 0; SPEAK_PORT=18766 -> C7 rc11 'listener running on :18765, not :18766' markers preserved; stopped -> 'unrelated process / nothing on port'; foreign nc -l -> 'port reachable but not recognized as this listener'; dead-pid stale markers cleaned); forward-context --listener TCP-only; speak status alias; /speak:now handoff sim: code-fence+backtick body via file-stdin to stubbed say -> cleaned text exit 0; explicit unreachable -> immediate stderr message with ./plugins/speak/bin/speak --serve
- PRs: