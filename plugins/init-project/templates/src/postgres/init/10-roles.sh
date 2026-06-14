#!/usr/bin/env bash
# Description: Bootstrap the FIXED least-privilege roles (owner/migrator/api) for the platform DB.
#
# Runs ONCE, at first volume init, from the official postgres image's
# /docker-entrypoint-initdb.d/ hook (as the bootstrap superuser, against the
# already-created `platform` database). It must run BEFORE any EF migration: a
# migration cannot create the role it connects as (`migrator`). See
# docs/keycloak.md §4 and docs/config-management.md §3 for the authoritative model.
#
# The role names owner/migrator/api and the database name `platform` are FIXED
# scaffold constants (NOT in config.json) so static EF migration SQL can reference
# them literally. Only the role PASSWORDS flow in (from the generated .env via the
# compose `environment:`):
#   POSTGRES_OWNER_PASSWORD / POSTGRES_MIGRATOR_PASSWORD / POSTGRES_API_PASSWORD
#
# Role model (least privilege — no component connects as the superuser):
#   owner    NOLOGIN  owns the schema; DDL runs as owner.
#   migrator LOGIN    member of owner; EF connects as migrator and issues
#                     `SET ROLE owner` for owner-privileged DDL (EF can't connect
#                     as a NOLOGIN role).
#   api      LOGIN    least-privilege runtime role the Api connects as. Constrained
#                     by row-level security; the per-table ENABLE/FORCE + policies
#                     ship in the EF entity migrations (RLS is table-specific and
#                     can't be enabled before the tables exist).
#
# Passwords are set ONLY here, at first volume init. Rotating a password requires
# resetting the volume — re-running build-config updates .env but not live roles.

set -euo pipefail

: "${POSTGRES_OWNER_PASSWORD:?POSTGRES_OWNER_PASSWORD must be set (run build-config)}"
: "${POSTGRES_MIGRATOR_PASSWORD:?POSTGRES_MIGRATOR_PASSWORD must be set (run build-config)}"
: "${POSTGRES_API_PASSWORD:?POSTGRES_API_PASSWORD must be set (run build-config)}"

# Connect as the bootstrap superuser to the platform database. Passwords are passed
# as psql variables and emitted via quote_literal so they are safely quoted in the
# dynamic CREATE ROLE / ALTER ROLE statements (the URL-safe alphabet already
# guarantees no quoting hazards — quote_literal is belt-and-suspenders).
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "platform" \
  -v owner_pw="$POSTGRES_OWNER_PASSWORD" \
  -v migrator_pw="$POSTGRES_MIGRATOR_PASSWORD" \
  -v api_pw="$POSTGRES_API_PASSWORD" <<'SQL'
-- owner: NOLOGIN role that owns all schema objects. DDL runs under this role.
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'owner') THEN
    CREATE ROLE owner NOLOGIN;
  END IF;
END
$$;
ALTER ROLE owner WITH PASSWORD :'owner_pw';

-- migrator: LOGIN role EF connects as. Member of owner -> issues SET ROLE owner for
-- owner-privileged DDL. EF cannot connect as the NOLOGIN owner directly.
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'migrator') THEN
    CREATE ROLE migrator LOGIN;
  END IF;
END
$$;
ALTER ROLE migrator WITH PASSWORD :'migrator_pw';
GRANT owner TO migrator;

-- api: least-privilege LOGIN role the runtime Api connects as. Row-level security
-- (set up by EF entity migrations) constrains what it can read/write; the Api sets
-- per-request session context (app.user_id / app.roles) inside a transaction.
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'api') THEN
    CREATE ROLE api LOGIN;
  END IF;
END
$$;
ALTER ROLE api WITH PASSWORD :'api_pw';

-- The platform database is owned by owner so all DDL (run via SET ROLE owner) is
-- owner-owned. Revoke the default PUBLIC connect (Postgres grants CONNECT to
-- PUBLIC by default) so ONLY the explicitly-granted least-privilege roles can
-- connect — no future login role inherits connect implicitly.
ALTER DATABASE platform OWNER TO owner;
REVOKE CONNECT ON DATABASE platform FROM PUBLIC;
GRANT CONNECT ON DATABASE platform TO migrator;
GRANT CONNECT ON DATABASE platform TO api;

-- Public schema: owner owns it; the api role gets USAGE but NOT create. Table-level
-- grants + RLS policies are applied per-table by the EF entity migrations (they run
-- as owner via migrator's SET ROLE), keyed off current_setting('app.user_id', true).
ALTER SCHEMA public OWNER TO owner;
GRANT USAGE ON SCHEMA public TO api;

-- Revoke the default PUBLIC create-on-public-schema so only owner-run DDL creates
-- objects (least privilege baseline; EF migrations run as owner).
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
SQL

# Lock down the bootstrap superuser: rotate its password to an unguessable random
# value AFTER the roles are created. The superuser was only needed transiently to
# run this init script; no component connects as it. Rotating away from the known
# bootstrap literal means that literal no longer grants superuser access — the
# owner/migrator/api roles (with their own distinct passwords) are the only usable
# logins. The rotated value is never persisted anywhere (intentionally lost).
#
# The superuser name is POSTGRES_USER when set, else the image default `postgres`.
# The random value is 64 hex chars (/dev/urandom) — alphanumeric only, so it is
# safe to embed in the SQL literal without any quoting hazard. (psql `:'var'`
# interpolation does NOT work with `-c`, so the value is built in shell and the
# statement is fed on stdin.)
SUPERUSER="${POSTGRES_USER:-postgres}"
BOOTSTRAP_THROWAWAY="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
psql -v ON_ERROR_STOP=1 --username "$SUPERUSER" --dbname "platform" <<SQL2
ALTER ROLE "$SUPERUSER" WITH PASSWORD '$BOOTSTRAP_THROWAWAY';
SQL2
unset BOOTSTRAP_THROWAWAY

echo "postgres init: bootstrapped roles owner/migrator/api on database platform (bootstrap superuser password rotated to a discarded random value)"
