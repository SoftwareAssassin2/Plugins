---
title: Propose-then-confirm preview must be byte-identical to the confirmed write
date: "2026-07-09"
track: bug
category: runtime-errors
module: plugins/merge-request/skills/post-findings/scripts/merge-prefs.sh
tags: [bash, awk, propose-confirm, dry-run, idempotent, keyed-merge, preferences]
problem_type: runtime-error
symptoms: PROPOSED= preview differed from the confirmed write; count-only flag accepted on non-counted sections
root_cause: "increment/count logic applied in the transform without gating by section, and dry-run reused passed text instead of the existing entry's text kept by the write"
resolution_type: fix
related_to: [bug/runtime-errors/forge-triage-true-swallowed-listingcli-2026-07-09, bug/runtime-errors/merge-requestcreate-pushed-to-origin-2026-07-09, bug/runtime-errors/mkdir-lock-helpers-released-a-lock-they-2026-07-08]
---

## Problem
A propose-then-confirm keyed preferences writer (`merge-prefs.sh upsert`) had two
model-fidelity bugs, both caught in impl-review:
1. `--increment` (a Don't-raise-only concept — only that section carries a
   `(count: N)`) was accepted for ANY `--section`. Running it on a Wording or
   Confirmed-valued key rewrote that entry into a counted `- \`key\` (count: N) — …`
   line, corrupting a section that must not carry counts.
2. On `--increment` of an EXISTING Don't-raise key, the confirmed write keeps the
   existing entry text and only bumps the count — but the propose (dry-run) path
   previewed the freshly-passed `--text`. So `PROPOSED=` was not byte-identical to
   what `--confirm` would land: the user could confirm one rule and get a different
   one written.

## Solution
1. Reject `--increment` at argument validation unless `--section dont-raise`
   (exit 2, write nothing).
2. In the propose path, when `--increment` targets an existing key, read the
   existing entry's count AND text via awk and reuse the existing text in the
   preview, so PROPOSED == the eventual ENTRY. A new key still previews the passed
   text at count 1.

## Prevention
For any propose-then-confirm / dry-run vs commit pair, add a test that asserts the
previewed artifact is byte-identical to what the confirmed write lands — especially
on the update/increment path where the write intentionally ignores some inputs
(here: text is held stable, only count moves). Also: guard flags that only make
sense for one variant (a count only exists on one section) at argument validation,
not deep in the transform, and test the refusal.
