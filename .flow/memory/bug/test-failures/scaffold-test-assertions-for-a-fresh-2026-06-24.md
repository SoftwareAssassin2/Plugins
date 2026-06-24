---
title: Scaffold-test assertions for a fresh-scaffold feature must use a pristine scaffo
date: "2026-06-24"
track: bug
category: test-failures
module: plugins/init-project/tests/scaffold_test.sh
tags: [scaffold-test, test-validity, fresh-scaffold, stderr, grep-precision, init-project]
problem_type: test-failure
symptoms: "New scaffold_test assertions passed but did not actually prove what they claimed (mutated scaffold, stdout-only guard, file-wide greps)"
root_cause: Structural assertions reused a project mutated by earlier --update/--replace-config; no-upstream guard discarded stderr; multi-signal/cross-ref greps matched anywhere instead of the exact line/surface
resolution_type: fix
---

## Problem
New scaffold_test.sh assertions for the async-collaboration feature had three test-validity defects the impl-review caught:
1. Structural "feature lands in a FRESH scaffold" assertions ran against the shared `$WORK/demo-app`, which earlier `--update`/`--replace-config` cases had already mutated — so they no longer proved a fresh scaffold (the R14 requirement).
2. The no-upstream `@{u}` regression piped the hook through `run_hook` which discarded stderr; an UNGUARDED `@{u}` probe prints `fatal: ... '@{u}'` to STDERR while still emitting valid JSON on stdout, so a stdout-only JSON assertion could never catch the regression it was meant to guard.
3. Loose `grep` predicates: the README PII-caveat check matched its three signals (collaboration / private / secrets) anywhere in the file rather than on the same line; the three-surface cross-ref checks accepted `docs/collaboration.md` when the spec required the inbox DIRECTORY surface `docs/collaboration/`.

## Solution
1. Scaffold a dedicated pristine `collab-app` project for the structural block instead of reusing the mutated `demo-app`.
2. Re-run the no-upstream fixture capturing stderr (`2>&1 >/dev/null`) and assert it carries no `@{u}`/`fatal:`/`no upstream` noise — alongside the existing stdout-JSON check.
3. Pull the collaboration-mentioning README line(s) and assert the private + secrets signals on THAT line; switch cross-ref checks to `grep -qF "docs/collaboration/"`.

## Prevention
- A "lands in a fresh scaffold" assertion must run against an UNMUTATED scaffold — in a suite that mutates a shared project with `--update`/`--replace-config`, create a fresh project for fresh-state assertions rather than reusing the shared one.
- When asserting a tool does NOT emit a diagnostic, capture STDERR — a guard that only checks stdout (or valid-JSON-on-stdout) cannot detect an error written to stderr while the happy-path output still succeeds.
- Co-locate multi-signal content assertions (grep the specific line/paragraph), and grep the EXACT surface the spec names (`docs/collaboration/` dir vs `docs/collaboration.md` doc) so a loose match can't pass on unrelated text.
