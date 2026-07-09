---
satisfies: [R3, R4]
---
## Description
Scaffold the second plugin **shell** and register both plugins so the package installs, and document the `supported=false` hard-stop contract the four `merge-request:*` skills share. This task owns the `merge-request` plugin shell (manifest + marketplace registration) and the **contract documentation only** — the four namespaced skills and their per-skill hard-stop enforcement are delivered by fn-9..fn-12.

**Size:** S/M
**Files:** `plugins/merge-request/.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `plugins/merge-request/README.md` (shared contract doc)

## Approach
- Create `plugins/merge-request/.claude-plugin/plugin.json` (name `merge-request`) ready to host a `skills/<name>/SKILL.md` subdir layout (flow-next multi-skill pattern). No skill dirs are created here — fn-9..fn-12 add `/merge-request:create`, `:review`, `:fix`, `:post-findings`.
- Add two entries to `.claude-plugin/marketplace.json` (`"source": "./plugins/detect-source-control"` and `"source": "./plugins/merge-request"`), matching the existing local-source entry shape (`name`, `displayName`, `description`, string `source`).
- Write the shared hard-stop contract doc: every `merge-request:*` skill first runs `/detect-source-control`, parses the stdout block, and when `supported=false` (with exit `0`) stops immediately with a clear message naming the detected forge/host. This is a documented reference contract in fn-8; fn-9..fn-12 wire the actual calls.

## Investigation targets
**Required:**
- `.claude-plugin/marketplace.json` -- entry shape + owner block
- `plugins/dick/.claude-plugin/plugin.json` -- manifest field shape (reference for the `merge-request` manifest)

**plugin.json shape (inline, from `plugins/dick`):**
```json
{
  "name": "merge-request",
  "displayName": "Merge Request",
  "version": "0.1.0",
  "description": "<one-line>",
  "author": { "name": "Chris Green (Software Assassin)" }
}
```

**marketplace entry shape (inline, local-source form):**
```json
{ "name": "detect-source-control", "displayName": "Detect Source Control", "description": "<one-line>", "source": "./plugins/detect-source-control" }
```

## Acceptance
- [ ] `plugins/merge-request/.claude-plugin/plugin.json` created (name `merge-request`), structured for a `skills/` subdir (shell only; no skill dirs yet).
- [ ] Both `detect-source-control` and `merge-request` are registered in `.claude-plugin/marketplace.json` (matching existing local-source entry shape).
- [ ] The `supported=false` hard-stop contract is documented as the shared reference the four skills follow (documentation only in this task; per-skill enforcement lands in fn-9..fn-12).

## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
