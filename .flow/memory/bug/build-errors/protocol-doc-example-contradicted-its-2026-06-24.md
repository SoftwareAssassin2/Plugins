---
title: Protocol-doc example contradicted its own slug algorithm (false collision)
date: "2026-06-24"
track: bug
category: build-errors
module: plugins/init-project/templates/docs/collaboration.md
tags: [protocol-doc, slug, contract, examples, init-project]
problem_type: build-error
symptoms: "Slug-collision example showed bob@x.com/bob@y.com -> bob, impossible under the whole-email slug rule"
root_cause: Illustrative example not traced through the doc's own stated algorithm; implied a local-part-only handle model
resolution_type: fix
---

## Problem
The collaboration protocol standard (docs/collaboration.md) documented a slug-collision example that contradicted its own slug algorithm. The algorithm slugs the WHOLE git-email (lowercase, every non-[a-z0-9] run -> single `-`, trim), but the collision example claimed `bob@x.com` and `bob@y.com` both -> `bob`. Under the documented algorithm they slug to distinct handles (`bob-x-com`, `bob-y-com`), so it was a false collision.

## Solution
Replaced with a real collision under the algorithm: `bob.smith@x.com` and `bob+smith@x.com` both slug to `bob-smith-x-com` (the `.` and `+` are both non-[a-z0-9] runs collapsing to a single `-`). docs/collaboration.md:~83.

## Prevention
When a doc is a build-time-complete protocol contract that later code/tests implement against, every concrete example MUST be checked against the doc's own stated rules — an example that silently implies a different model (here: local-part-only handles vs whole-email slugs) propagates the wrong model into the hook implementation and its tests. Trace each illustrative example through the algorithm it illustrates before shipping.
