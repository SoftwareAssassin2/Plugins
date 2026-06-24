---
satisfies: [R3, R4, R8, R9, R21, R23, R28]
---

## Description

Wire the `Stop` hook that drives automatic speech, the global auto-speak toggle, and the once-per-session "listener unreachable" notice.

**Prerequisite:** fn-5.3's container→host proof is green (or the fallback transport is recorded) before this task starts.

**Size:** M
**Files:** `plugins/speak/hooks/hooks.json`, `plugins/speak/hooks/stop-speak.sh`, `plugins/speak/bin/speak` (on/off flag handling + a **sourceable transcript-extraction function** so `.6` can unit-test it; shared dependency-detection helper)

## Approach

- `hooks/hooks.json`: a `Stop` hook (**no matcher**), exec form, invoking the hook script with a hook-config `timeout` (the hooks.json `timeout` field in **seconds** — NOT the external `timeout`/`gtimeout` binary, which macOS lacks). Mirror the header/contract style of `plugins/init-project/templates/.claude/hooks/claude-md-reminder.sh` (Description header, **always exit 0, never block**).

- `stop-speak.sh` sources `bin/speak` for its helpers. Because `bin/speak` enables `set -euo pipefail` **only when executed** (source-guarded), sourcing does NOT leak strict mode into the hook; the hook checks helper return codes explicitly and **always exits 0**. It runs as one **ordered algorithm**:
  1. **Read the toggle flag file first** (plain file read, no `jq`; missing/corrupt/unset data dir → OFF). If OFF → exit 0.
  2. **Read stdin once** into a variable/temp (so later checks reuse it). **Check `jq`.** If missing: honor the loop guard with a `jq`-free, **whitespace-tolerant** match `"stop_hook_active"[[:space:]]*:[[:space:]]*true` (handles minified JSON) → if it matches, exit 0 silently; otherwise emit ≤1 `systemMessage` via the fixed `missing-jq` debounce key (or exit 0 silently) and exit 0. The notice JSON is built from **hard-coded JSON-safe static strings (jq-free emitter, no untrusted interpolation)** so stdout stays valid JSON (R28). On the `jq`-present path, the SAME shared emitter uses `jq -n --arg message ...` to safely encode any value (e.g. an invalid `SPEAK_PORT` with quotes/newlines) — never string interpolation. **No hook-JSON parsing on this path.**
  3. **With `jq` present:** parse stdin; if `stop_hook_active` is true → exit 0 (loop guard).
  4. **Transcript extraction** (sourceable `extract_last` in `bin/speak`, unit-tested by `.6`): inspect ONLY the FINAL record of `transcript_path` — speak iff it is an assistant message (text parts, skip tool_use/thinking); not-assistant or empty-after-cleaning → exit 0 silently; **never scan backward**. Assumed schema (**confirm against a real transcript FIRST**): final line `.type=="assistant"`, text via `jq -r '[.message.content[]? | select(.type=="text") | .text] | join(" ")'` (or the raw string when content is a string).
  5. **Preflight synchronously** via the shared helpers (`deps_missing`, `speak_mode`, port-validate, `listener_reachable`). **Reachability is checked ONLY when `speak_mode=forward`; in local mode preflight only the local dep `say` + `jq` (base64 is NOT a local dep — wire-transport only) and never emit a "start `speak --serve`" notice.** Two distinct outcomes:
     - **Missing dep / invalid port** (`jq`/`say`/local; or `base64`/`nc`/capability in forward; or invalid `SPEAK_PORT`) → emit one debounced reason-specific `systemMessage` (missing dep → names the exact tool + install guidance; invalid-port → bad value + 1..65535) and **exit 0 without dispatching** (playback genuinely can't proceed).
     - **Forward listener probe failure with deps+port valid** → do NOT exit here: optionally prepare the `listener-unreachable` notice, **fall through to step 6 and still dispatch the async send-with-retry**, emitting at most one JSON notice. A transient false-negative probe must never drop auto-speech.
     Notices are **self-contained** (no hard README dependency; `.7` verifies agreement). Keyed `<plugin_state_dir>/debounce/<sanitized-session-id>.<reason>` (reason ∈ `listener-unreachable`/`missing-jq`/`missing-<tool>`/`invalid-port`, via the shared `sanitize_session_id` — never a raw id as a path; prune markers older than **7 days** on hook entry). An invalid `SPEAK_MODE` with auto-speak on yields a debounced `invalid-config` notice (reason set: `listener-unreachable`/`missing-jq`/`missing-<tool>`/`invalid-port`/`invalid-config`). The hook's forward notify decision uses the **single fast `listener_reachable` probe** (advisory) — not the retry/backoff path.
     (Forward mode: a failed `listener_reachable` probe does NOT skip the send — when deps + port are valid, always dispatch the async send-with-retry in step 6; the probe result only decides whether to *also* emit the debounced unreachable notice. A transient false-negative probe must never drop auto-speech.)
  6. **Otherwise dispatch playback ASYNCHRONOUSLY:** write the extracted text to a temp file (or pipe it in explicitly — do NOT let the child inherit the hook's stdin or read empty stdin), then start `"${CLAUDE_PLUGIN_ROOT}/bin/speak"` (explicit path — `bin/` isn't on the hook's PATH) with `SPEAK_SESSION=<session_id>` **detached** (`nohup`/`setsid`/disowned subshell) so playback isn't tied to the hook's lifetime, stdout/stderr redirected to a log. **Temp cleanup ownership:** the detached child removes the temp file after it has read it (or the text is passed via an already-open fd) — the parent must NOT delete it and race the child. Return immediately — `say` is synchronous, so a blocking call would stall the hook for the full speech duration and risk the hook timeout. Exit 0; the hook prints nothing otherwise.

- Dependency detection uses the **shared helper in `bin/speak`** — **this task owns its initial implementation** (`.5`'s `doctor` reuses it; no divergence), and includes `nc` **capability** (connect-timeout + EOF-shutdown flags), not mere presence.

- `speak on` / `speak off`: write the single global flag file **`<plugin_state_dir>/auto-speak` containing exactly `on\n` or `off\n`, atomically (temp + rename)**, where `plugin_state_dir = ${SPEAK_DATA_DIR:-${CLAUDE_PLUGIN_DATA:-}}` (nounset-safe; NO HOME fallback — the hook reads the same dir; NOT `${CLAUDE_PLUGIN_ROOT}`, which is ephemeral). Any other/absent/unreadable content reads as OFF. Outside Claude with neither var set, `speak on/off` reports "toggle unavailable" (it does NOT write a HOME dir the hook won't read); a missing/corrupt flag → OFF. (The diagnostic surface — `speak doctor`, with `speak status` as its alias — ships in `.5`.)

## Investigation targets
**Required:**
- `plugins/init-project/templates/.claude/hooks/claude-md-reminder.sh:1-30` — Stop-hook precedent (exit-0 contract, BASH_SOURCE)
- `plugins/speak/bin/speak` — forward/reachability from `.2`, local from `.1`
**Optional:**
- docs-scout Stop-hook stdin schema + `systemMessage` semantics

## Acceptance
- [ ] `bin/speak` enables `set -euo pipefail` only when executed (source-guard); sourcing it into `stop-speak.sh` does NOT leak strict mode, and the hook always exits 0
- [ ] Single ordered algorithm: (1) toggle first → off=exit0; (2) no-`jq` → grep loop-guard then ≤1 `missing-jq` notice/silent, exit 0, no JSON parse; (3) `jq` present → parse + `stop_hook_active` guard; (4) FINAL-record extraction; (5) preflight notice; (6) async playback
- [ ] Transcript schema: implement against the assumed schema; confirm against a real transcript when available (manual evidence). If unavailable in the impl env, the **explicit fallback** is — ship against the assumed schema, `.6` includes fixtures documenting the assumption, and a manual verification note is required before auto-speak is considered complete. Fixture capture + tests owned by `.6`
- [ ] No-`jq` `systemMessage` uses a jq-free static-string emitter producing valid JSON (R28)
- [ ] Reachability checked only in forward mode; local mode never emits a "start `speak --serve`" notice (R10, R22)
- [ ] Forward mode with valid deps/port ALWAYS dispatches the async send-with-retry; a failed probe only adds the debounced notice, never suppresses the send (no dropped auto-speech on a transient false-negative)
- [ ] Invalid `SPEAK_PORT` → debounced `invalid-port` notice naming the bad value + 1..65535 range (not a serve-command notice)
- [ ] Notice content is reason-specific AND self-contained (no hard README dependency; `.7` verifies agreement later): listener-unreachable → `speak --serve` command; missing dep/capability → names the exact tool + install guidance
- [ ] The unreachable notice is self-contained (command + one-line setup hint), README pointer supplementary
- [ ] Playback is dispatched asynchronously and **detached** (text handed off via temp file/explicit pipe — never inherited/empty stdin; child output → log; the **child** removes the temp after reading it so the parent can't race-delete it) so the hook returns immediately and never blocks on `say` or the hook timeout
- [ ] Debounce keys: the pre-parse `missing-jq` notice uses a **fixed global** key (`session_id` is unavailable without `jq`); ALL parsed-path notices (listener-unreachable/missing-`<tool>`/invalid-port) use `<sanitized-session-id>.<reason>`
- [ ] No-`jq` loop guard uses the whitespace-tolerant regex `"stop_hook_active"[[:space:]]*:[[:space:]]*true` (matches minified JSON); stdin is read once before checks
- [ ] Missing-dependency detection covers `nc` **capability** (connect-timeout + EOF-shutdown flags), not just presence — in forward mode an unusable flag triggers the debounced notice
- [ ] Transcript extraction is a sourceable function in `bin/speak` that `stop-speak.sh` calls
- [ ] `hooks/hooks.json` registers a `Stop` hook (no matcher, exec form, timeout) invoking the hook script (R3, R28)
- [ ] Hook bails when `stop_hook_active` is true — both `jq` (parsed) and no-`jq` (grep) paths (no loop)
- [ ] Auto-speak OFF by default; `speak on`/`speak off` write `<plugin_state_dir>/auto-speak` = `on\n`/`off\n` atomically (temp+rename); other/absent/unreadable content → OFF; outside Claude with neither `SPEAK_DATA_DIR`/`CLAUDE_PLUGIN_DATA` set → "toggle unavailable" (R4, R21)
- [ ] Hook inspects only the FINAL transcript record: assistant → speak; non-assistant/empty → exit 0 silently; never scans backward (R3)
- [ ] Hook stdout is empty or exactly one JSON object with `systemMessage`; the child `speak` invocation's output is captured, not leaked (R28)
- [ ] Unreachable listener → `systemMessage` containing `./plugins/speak/bin/speak --serve`, shown at most once per session+reason; the debounce-marker filename is `<sanitized-session-id>.<reason>` (no raw id as a path); distinct reasons aren't mutually suppressed; stale markers pruned (R8, R9)
- [ ] Per-context deps: local needs `say` (+`jq` for the hook), forward needs `base64`/`nc`; a missing required-in-context dep → one debounced `systemMessage` naming it, never a hard-fail (shared `bin/speak` dep helper); missing-dep/invalid-port exit without dispatch, forward-probe-failure still dispatches (R23, R28)
- [ ] hooks.json `timeout` uses the Claude hook-config field (seconds), not the external `timeout` binary
- [ ] `plugins/speak/hooks/stop-speak.sh` is committed executable (`test -x`)

## Done summary
_(filled on completion)_

## Evidence
_(filled on completion)_
