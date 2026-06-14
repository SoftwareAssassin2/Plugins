---
title: Postgres bootstrap superuser pw must not reuse a role secret; revoke PUBLIC conn
date: "2026-06-14"
track: bug
category: security
module: plugins/init-project/templates/src/postgres
tags: [postgres, least-privilege, docker-compose, rls, scaffold, pg_hba, scram]
problem_type: security
symptoms: owner role credential doubles as bootstrap superuser; any future login role can connect to the db
root_cause: POSTGRES_PASSWORD reused POSTGRES_OWNER_PASSWORD; default PUBLIC CONNECT never revoked
resolution_type: fix
---

## Problem
The postgres service compose set `POSTGRES_PASSWORD` (the bootstrap superuser
credential the official image requires) to the SAME value as
`POSTGRES_OWNER_PASSWORD` (a least-privilege application role secret). That makes
the `owner` role credential double as the superuser credential — anyone holding the
owner secret can log in as the bootstrap superuser and bypass the entire
owner/migrator/api separation the role model exists to enforce. A second, related
gap: the init script granted CONNECT to migrator/api but never revoked the default
PUBLIC CONNECT that Postgres grants on every new database, so any future login role
could connect.

## What Didn't Work
- Reusing a role password as the superuser password "to avoid generating another
  secret" — silently collapses the privilege boundary.
- Rotating the superuser password with `psql -c "ALTER ROLE ... PASSWORD :'var'"`:
  psql `:'var'` interpolation does NOT work with `-c` (only in scripts/stdin),
  producing a `syntax error at or near ":"`. Feed the statement on stdin (heredoc)
  with the value built in shell instead.
- Verifying password auth over the LOCAL socket or 127.0.0.1: the stock postgres
  image's default pg_hba.conf is `trust` for local + loopback, so wrong passwords
  still connect. That masks both the reuse bug and the rotation. To PROVE a
  password actually changed, compare the stored SCRAM verifier in
  `pg_authid.rolpassword` against a probe role created with the candidate password
  (verifiers differ => password changed), rather than relying on a login attempt.

## Solution
- Set `POSTGRES_PASSWORD` to a DISTINCT transient bootstrap literal (never a role
  secret), then ROTATE it to a discarded random value (`head -c 32 /dev/urandom |
  od -An -tx1`) as the LAST step of the init script — so the known bootstrap literal
  no longer grants superuser access and no component ever needs the superuser.
- Add `REVOKE CONNECT ON DATABASE <db> FROM PUBLIC;` before the explicit
  `GRANT CONNECT` to the least-privilege roles.

## Prevention
- A bootstrap/superuser credential must never equal any application/role secret —
  generate or rotate it independently; treat the superuser as transient-init-only.
- Always `REVOKE CONNECT ... FROM PUBLIC` (and `REVOKE CREATE ON SCHEMA public FROM
  PUBLIC`) when building a least-privilege Postgres role model; Postgres's PUBLIC
  defaults are permissive.
- Don't trust loopback/socket login as proof of password auth on the stock image
  (trust-auth by default) — assert on the stored SCRAM verifier instead.
