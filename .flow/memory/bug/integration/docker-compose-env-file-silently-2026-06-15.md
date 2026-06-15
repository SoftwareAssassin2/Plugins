---
title: "docker compose env_file silently corrupts values ($ interpolation, whitespace+# "
date: "2026-06-15"
track: bug
category: integration
module: plugins/init-project/templates/src/system-cli/build-config.sh
tags: [dotenv, docker-compose, env_file, encoding, scaffold, injection]
problem_type: integration
symptoms: Generated .env value truncated/emptied at container runtime despite passing validation
root_cause: "compose env_file parser is not shell: interpolates $, treats whitespace+# as inline comment, strips wrapping quotes"
resolution_type: fix
related_to: [bug/integration/grafana-datasource-must-point-at-2026-06-14]
---

## Problem
A scaffolded project's `src/Api/.env` is consumed by docker compose's `env_file:`
parser (NOT shell `source` — confirmed via Program.cs "loaded by docker compose" +
docs §7). When build-config emits external LLM credentials/base-URLs there, naive
encoding silently corrupts values. Two distinct failure modes, both confirmed
empirically with `docker compose config` (v2):
  1. `$` triggers variable interpolation: `KEY=a$b` -> `a` (the `$b` expands empty).
     The `$$` escape is compose-only and would corrupt a plain shell `source`.
  2. WHITESPACE-then-`#` is parsed as a trailing inline comment that TRUNCATES the
     value: `KEY=sk #suffix` -> `sk`. (A `#` NOT preceded by whitespace round-trips:
     `KEY=a#b` -> `a#b`.)
Also: compose STRIPS surrounding quotes (`KEY='v'` -> `v`), so shell-style
single-quoting does NOT round-trip — never assume shell quoting for a non-shell parser.

## What Didn't Work
First pass only rejected CR/LF/control + `$`, and tested `a#b` (passes) but NOT
`a #b` (truncates). Treating space and `#` as independently-safe missed the
`[[:space:]]#` inline-comment sequence. A clean codex impl-review caught it.

## Solution
build-config.sh `v_env_value()` emits values RAW and rejects what can't round-trip
across the consumer: CR/LF (`*$'\n'*`/`*$'\r'*`), `[[:cntrl:]]`, `*'$'*`, and the
`[[:space:]]#` sequence. Test matrix: space/`#`-no-space/`"`/`'` round-trip; `$`,
CR, LF, TAB, and space+`#` rejected. base_url validated by an injection-resistant
grammar FIRST (host class `[A-Za-z0-9.-]+` + separate port range-check 1..65535),
then path punctuation passed through the same v_env_value.

## Prevention
- For ANY generated `.env`, first identify EVERY consumer (shell source vs compose
  env_file vs a dotenv lib) — they have DIFFERENT escaping rules. Pick an encoding
  ALL accept, or reject chars that can't round-trip across all of them.
- Ground the decision empirically: `printf 'K=val\n' > .env && docker compose config`
  shows exactly what the parser produces. Test `$`, leading/embedded `#`,
  whitespace+`#`, wrapping quotes, and multi-line.
- Also: validate/preflight everything (incl. template existence + structural shape)
  BEFORE writing any artifact, so a late failure never leaves a partial update
  (e.g. Api/.env repointed at a gateway whose config was never generated).
