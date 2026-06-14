---
title: Template .gitignore silently drops committed fixtures from the plugin repo
date: "2026-06-14"
track: bug
category: build-errors
module: plugins/init-project/templates/.gitignore
tags: [scaffold, gitignore, git-add, templates, angular]
problem_type: build-error
symptoms: Clean-checkout scaffold missing src/<SPA>/public/config.json; SPA startup fails on GET /config.json
root_cause: "templates/.gitignore pattern src/*/public/config.json matched the template path inside the plugin repo, so git add -A skipped the committed sample"
resolution_type: fix
---

## Problem
The two Angular SPA templates ship a committed sample `src/<SPA>/public/config.json`
fixture so a fresh scaffold builds before `system.sh build-config` runs. The
template's own `templates/.gitignore` carries `src/*/public/config.json` (the rule
for the *scaffolded project*). But because the templates live at
`plugins/init-project/templates/src/<SPA>/public/config.json` inside the PLUGIN repo,
that same `.gitignore` matched there too — so `git add -A` silently skipped the
fixtures. The committed templates were missing the files; a clean checkout would
scaffold projects with no public config sample, and the runtime
`provideAppInitializer(() => AppConfigService.load())` would fail on `GET /config.json`.

## What Didn't Work
Fresh-scaffold build/test passed locally and I claimed it worked — but only because
the fixtures existed in my WORKING TREE. The committed tree was broken. Trusting a
working-tree scaffold hid a clean-checkout regression.

## Solution
`git add -f` the two fixtures so they are tracked despite the ignore rule. Verified
via `git checkout-index -a --prefix=<cleandir>/` (materializes ONLY tracked+staged
content) then scaffolding + `npm install`/`ng build`/`jest` from that clean export.
Added scaffold_test.sh guards asserting both `src/<SPA>/public/config.json` land in
scaffold output AND contain only non-secret public fields.

## Prevention
- When a template tree carries its own `.gitignore`, that ignore applies INSIDE the
  meta-repo too — any template file matching a pattern is silently dropped by
  `git add -A`. Scan with: for each template file, `git ls-files --error-unmatch`
  + check staged; flag any "untracked & matched by check-ignore".
- Verify scaffolds from a CLEAN git export (`git checkout-index`/`git archive`),
  never just the working tree, before claiming a build works.
