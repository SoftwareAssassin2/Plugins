# Configuration standards

## 1. Single source of truth

All configuration values live in `config.json` at the repo root. Per-app config files are downstream artifacts — they are generated from the root file, not edited directly.

To regenerate per-app configs after editing `config.json`:

```
./system.sh build-config
```

When an app needs a new configuration value:

1. Add the value to `config.json`.
2. Update `platform/system-cli/build-config.sh` to write that value into the relevant app-level config file(s).

## 2. Keys consumed by `play.sh` telemetry subcommands

The `play.sh` telemetry subcommands (`ad-campaign-impressions`, `ad-campaign-clicks`, `store-listing-views`, `app-installs`) read the following keys directly from `config.json`. Add them when adding a new game; populate them with real values per game before running the corresponding subcommand.

### Top-level

| Key | Type | Purpose |
|---|---|---|
| `play.reports_bucket` | string | GCS bucket holding the Play Console bulk-report CSVs. Accepts either a bare bucket name (`pubsite_prod_xxx`) or a `gs://`-prefixed URI. Consumed by `store-listing-views` and `app-installs`. |

### Per-game (each entry in `games[]`)

| Key | Type | Consumed by | Purpose |
|---|---|---|---|
| `id` | string | all subcommands | Positional `<game-id>` argument is looked up against this. |
| `ads_campaign_id` | string | `ad-campaign-impressions`, `ad-campaign-clicks` | Single Google Ads campaign per game in v1. |
| `play_package_name` | string | `store-listing-views`, `app-installs` | The Play Store package name (e.g. `com.hg.template`). Used to construct CSV filenames in the reports bucket. |
| `ad_campaign_launched_on` | string (ISO `YYYY-MM-DD`) | `ad-campaign-impressions`, `ad-campaign-clicks` | Default `--from-date` for ad-* subcommands when the flag is omitted. |
| `game_published_on` | string (ISO `YYYY-MM-DD`) | `store-listing-views`, `app-installs` | Default `--from-date` for store/install subcommands when the flag is omitted. |

A subcommand only validates the fields it consumes for the named game. Missing a required per-game field → exit 64 with a stderr line naming the offending field.

## 3. Keys consumed by `platform-db` (Postgres service)

`platform/system-cli/build-config.sh` reads the top-level `platform-db` section and writes `platform/platform-db/.env`. The compose file under `platform/platform-db/docker-compose.yml` then interpolates these values into the `platform-db`, `flyway`, and `platform-api` service definitions.

### Top-level `platform-db`

Every component of the Postgres connection string lives here — no hardcoded literals in `build-config.sh`, the compose file, the init script, or the migration SQL. Migrations reference the role names via Flyway placeholders (`${owner_role}`, `${migrator_user}`, `${api_user}`) and the init script reads them from env (passed by compose from this section).

| Key | Type | Purpose |
|---|---|---|
| `driver` | string | SQLAlchemy URL driver scheme. Default `postgresql+asyncpg`. Used as the prefix of `DATABASE_URL` written into the API's .env. |
| `container_host` | string | Compose service name + network alias for the Postgres service. Default `platform-db`. Other services use this as the in-network host (`...@<container_host>:<container_port>/...`). |
| `container_port` | integer | Postgres's listener port INSIDE the container (the port other compose services connect to). Default `5432`. |
| `host_port` | integer | Port mapped to the host. `pg_isready`/`psql` from the devcontainer connect to `127.0.0.1:<host_port>`. May differ from `container_port` if you collide with a host-side Postgres. |
| `database` | string | Postgres database name. Default `platform`. Used by the init script, every migration, and both `DATABASE_URL` + `FLYWAY_URL`. |
| `bootstrap_user` | string | Postgres superuser role. Default `postgres` (matches the `postgres` image's default). Used by the official-image entrypoint and by Task 5's operator-inspection steps. |
| `bootstrap_password` | string | Password for `bootstrap_user`. Must match `[A-Za-z0-9_-]+` — see §5. |
| `owner_role` | string | NOLOGIN owner role. Default `platform_owner`. Every migration runs `SET ROLE <owner_role>;` and resets at end; every `CREATE POLICY` references it. Substituted into migrations as `${owner_role}` at apply time. |
| `migrator_user` | string | LOGIN role used by Flyway. Default `platform_migrator`. Member of `owner_role` (granted in the init script). Substituted into migrations as `${migrator_user}`. |
| `migrator_password` | string | Password for `migrator_user`. Used by Flyway when `./system.sh migrate` runs. Must match `[A-Za-z0-9_-]+`. |
| `api_user` | string | LOGIN role used by the platform-api at runtime. Default `platform_api`. Constrained by RLS per `R__rls_policies.sql`; substituted into migrations as `${api_user}`. |
| `api_password` | string | Password for `api_user`. Used by the platform-api service at runtime. Must match `[A-Za-z0-9_-]+`. |

## 4. Keys consumed by `platform-api`

`build-config.sh` reads the top-level `platform-api` section and writes `platform/platform-api/.env`. The API container reads these at startup; `config.json` is never read inside the API container at runtime.

### Top-level `platform-api`

| Key | Type | Purpose |
|---|---|---|
| `host_port` | integer | Host-mapped port for the platform-api service (default 8000). |
| `log_level` | string | Uvicorn log level (`debug`, `info`, `warning`, `error`, `critical`). Default `info`. |
| `google_oauth_web_client_id` | string | Web OAuth Client ID from Google Cloud Console. Must be the **Web** client (NOT the Android client) in the SAME GCP project as the Play Games Services app. Used by the API to exchange Play server-auth-codes at `oauth2.googleapis.com/token`. |
| `google_oauth_web_client_secret` | string | Web OAuth Client secret paired with `google_oauth_web_client_id`. |

### What is NOT configurable

A handful of values are not exposed in `config.json`. They're either hard contracts with external systems or values the user explicitly chose to leave fixed at the SQL level:

- **OAuth `redirect_uri`**: always `""` (empty string) per Google's PGS v2 server-side flow contract — see [PGS server-access docs](https://developer.android.com/games/pgs/android/server-access). The token-exchange POST must include `redirect_uri=""` but the value is fixed; it is hardcoded in `_api_auth.py`.

Postgres role names, the database name, the compose service name, the driver scheme, and both container + host ports all flow from `config.json` per §3 above. Only the values that operators must provide (passwords, OAuth credentials) carry `REPLACE_ME` defaults.

## 5. Password alphabet

All generated platform passwords must match the URL-safe base64 alphabet `[A-Za-z0-9_-]+` (letters, digits, underscore, hyphen — no padding `=`, no `/`, no `+`). This keeps passwords safe to embed in:

- SQL literals (no quoting / escaping needed beyond Postgres's own `'...'` rules)
- `.env` file lines (no shell-quoting / `$VAR` expansion concerns)
- `DATABASE_URL` URI components (no percent-encoding required)

`build-config.sh` validates each platform password against this regex and exits 64 with a descriptive error if any password has out-of-alphabet characters.

Recommended generation: `openssl rand -base64 32 | tr -d '=' | tr '/+' '_-'` — produces a 43-character URL-safe-base64 string.

## 6. 12-factor configuration

This repo adopts factor III ("Config") of the [12-factor methodology](https://12factor.net/config) as a repo-wide standard. The pattern, in one sentence: **`config.json` is the source of truth at build time; `build-config.sh` distributes per-component `.env` files; runtime services read only from environment variables.**

The flow:

1. The operator edits `config.json` with values for their environment (local dev, future Cloud SQL deployment, etc.).
2. `./system.sh build-config` runs `platform/system-cli/build-config.sh`, which reads `config.json` and writes per-component `.env` files (`platform/platform-db/.env`, `platform/platform-api/.env`, …).
3. Each runtime container reads its values from environment variables only — typically loaded by `docker-compose` from the per-component `.env` file via `env_file:` (which injects into the container) and `${VAR}` interpolation (which substitutes into the compose file itself).
4. **`config.json` is never mounted into runtime containers**, and runtime services never call out to `config.json` directly. Any future component consuming config follows this pattern.

This separation gives us three things 12-factor names explicitly:

- **Strict separation of config from code.** The same image runs against local Postgres, staging Postgres, and production Cloud SQL — only the env values change.
- **Environment parity.** A new contributor's local dev environment differs from CI and prod only in the values written into `.env`, not in how config is consumed.
- **Secret rotation without code change.** Rotating `api_password` is a `config.json` edit + `./system.sh build-config` + restart. No source changes; no rebuild of the runtime image.

The intermediary build step (`build-config.sh`) is a deliberate departure from the strictest 12-factor reading, which says "config is in environment, period." We keep a tracked source-of-truth file because (a) this is a single-operator-per-environment private repo, (b) the operator needs ONE place to edit values that map into multiple `.env` files, and (c) rotation is a single command rather than N manual edits. The crucial 12-factor property — runtime services read only from environment — is preserved.

Note that `config.json` is tracked in git as a deliberate trade-off for a small private repo with one operator. A future multi-tenant or public-facing variant of this repo would replace tracked `config.json` with a vaulted secret store (Google Secret Manager, HashiCorp Vault) feeding `build-config.sh` at the same point. The downstream contract — per-component `.env`, runtime reads from env only — does not change.
