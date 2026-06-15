# Configuration management

This repo treats configuration as a first-class, single-source asset. Every
configurable value for local development lives in one tracked file, `config.json`
at the repo root, and is distributed from there to the per-component runtime
artifacts. This document is the authoritative standard: the schema table below
pins the exact field names, env-var names, generated-`.env` paths, and consumers
that the dispatcher subcommands and every component must follow so names never
drift.

## 1. Single source of truth

All local-dev configuration values live in `config.json` at the repo root.
Per-component config files (`.env` files, each SPA's public `config.json`, the
Keycloak realm-import file) are **downstream artifacts** — they are generated from
the root file, never edited directly.

To regenerate the downstream artifacts after editing `config.json`:

```bash
./system.sh build-config
```

When a component needs a new configuration value:

1. Add the value to `config.json` (and to `config.deploy.json` — see §7 — keeping
   the two key-sets identical).
2. Update `src/system-cli/build-config.sh` to write that value into the relevant
   downstream artifact(s), and add a row to the schema table in §4.

## 2. The `systems[]` / `services{}` model

`config.json` has two top-level shapes:

- **`systems[]`** — one entry per component the system *is made of*. There is a
  1:1 correspondence: every `src/<component>/` folder has exactly one `systems[]`
  entry keyed by `name` (matching the folder name), and vice versa. Class
  libraries carry a minimal entry (`{ "name": "Framework" }`); runtime components
  (`postgres`, `keycloak`, `Api`, the SPAs) carry their structural + secret
  fields.
- **`services{}`** — one entry per **external** service the system *connects to*
  but is not part of (e.g. a third-party API). Keyed by service name; the value is
  the credentials/endpoint the operator must supply. This scaffold ships **two
  canonical entries, both always present**: `claude-api` (Anthropic-compatible) and
  `openai-api` (OpenAI-compatible), each with an explicit `base_url` + `api_key`
  (see §4). The optional local LLM mock stack (`docs/local-llm.md`) *backs* these two
  services in local dev — it is internal dev tooling, **not** itself a `services{}`
  entry (it only repoints their `base_url`).

**Exceptions** (NOT `systems[]` entries): `src/system-cli/` (repo tooling), the
observability stack (`src/otel-collector/`, `src/prometheus/`, `src/grafana/` —
local dev tooling with no host/port secrets to distribute), and test projects
under `tests/<Component>.Tests/`. See the root `CLAUDE.md` for the full invariant.

A generic worked example: an image-resizing system has a `Resizer` component
(`systems[]` entry `Resizer`, with its host/port) and connects to an external
object store and a third-party virus-scanning API (two `services{}` entries, each
with `REPLACE_ME` credentials the operator fills in).

## 3. The Postgres component (`owner` / `migrator` / `api` roles)

The `postgres` component is a Postgres database running in a Docker container
(compose-managed, brought up by `system.sh up`). It hosts a single database named
**`platform`**.

Database access is gated through three least-privilege Postgres roles, applied as
a security baseline so that no component ever connects as the superuser:

| Role | Login | Used by | Purpose |
|---|---|---|---|
| `owner` | NOLOGIN | (assumed via `SET ROLE`) | Owns all objects. DDL runs under this role. |
| `migrator` | LOGIN | `system.sh migrate` (EF Core, design-time); `system.sh psql` (default) | Member of `owner`; runs migrations, issuing `SET ROLE owner` for owner-privileged DDL. EF cannot connect as a NOLOGIN role, so it logs in as `migrator`. |
| `api` | LOGIN | the `Api` component at runtime; `system.sh psql --role api` | Least-privilege runtime connection. Constrained by row-level security; the `Api` sets per-request session context (`app.user_id`/`app.roles`) and RLS policies key off `current_setting('app.*')`. |

**The role names `owner` / `migrator` / `api` and the database name `platform` are
FIXED scaffold constants** — they are NOT in `config.json`. This lets the static
EF migration SQL reference them literally (no placeholder mechanism). The roles are
bootstrapped by the `postgres` container's init script at first volume init,
*before* any EF migration runs (a migration cannot create the role it connects as).

What `config.json` *does* supply for `postgres` is only the **structural**
connection coordinates (host / ports / container host) and the three **generated**
role passwords (`owner_password`, `migrator_password`, `api_password`). See the
schema table in §4 for exact field and env-var names.

> Rotating a generated role password (edit `config.json` + rerun `build-config`)
> updates the `.env` but NOT the existing DB roles — the init script sets them only
> at first volume init. Rotation therefore requires resetting the postgres volume.
> Treat local-dev role passwords as fixed-per-volume.

**Interactive access.** `./system.sh psql <database>` opens a `psql` shell against
the database, reading the host/port and role password from `config.json` (passed via
`PGPASSWORD`, never on the argv). It connects as `migrator` by default — full schema
access for interactive work; `owner` is NOLOGIN and cannot connect. Pass `--role api`
to connect as the RLS-constrained runtime role (to reproduce what the `Api` sees), and
any trailing args are forwarded to `psql` (e.g. `./system.sh psql platform -c 'SELECT 1'`).
Requires the `postgresql-client` package, installed in the dev container.

## 4. Config schema (authoritative)

This table is the contract. The `build-config` subcommand and every component MUST
use these exact field names and env-var names; downstream tasks reference this
table so names cannot drift. "Secret/URL-safe" fields are generated by the scaffold
and validated against the URL-safe alphabet (§6). "Structural" fields are
configurable but validated for shape. Fields marked **fixed** are scaffold
constants, not in `config.json`.

The exact validators `build-config` enforces (a violation exits non-zero):

| Validator name | Regex / range | Applies to |
|---|---|---|
| URL-safe secret | `^[A-Za-z0-9_-]+$` | all generated secret fields (§6) |
| host | `^[A-Za-z0-9.-]+$` | `host` fields (hostname or dotted IPv4) |
| container-name | `^[a-zA-Z0-9][a-zA-Z0-9_.-]+$` | `container_host` fields (Docker/compose service-name shape) |
| realm / client-id | `^[A-Za-z0-9._-]+$` | `realm`, every `*_client_id` |
| URL | `^https?://[^[:space:]]+$` | `public_url`, `realm_url` |
| service base-URL | `^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[^[:space:]]*)?$` + port `1..65535` | `services.*.base_url` (injection-resistant; stricter than `URL`) |
| model name | `^[A-Za-z0-9._/-]+(:[A-Za-z0-9._-]+)?$` | `localLlm.model`, `localLlm.embeddingModel` (opt-in) |
| port | integer `1..65535` | every `*port` field |

### `postgres` (`systems[]` entry `postgres`)

| `config.json` field | Kind | Validator | Generated `.env` var | Consumer |
|---|---|---|---|---|
| `host` | structural | host (`^[A-Za-z0-9.-]+$`) | — (host-side `psql`/`pg_isready`) | devcontainer tooling |
| `container_host` | structural | container-name (`^[a-zA-Z0-9][a-zA-Z0-9_.-]+$`) | `POSTGRES_HOST` | compose, `Api`, `migrator` conn-strings |
| `container_port` | structural | port `1..65535` | `POSTGRES_PORT` | in-network connections |
| `port` | structural | port `1..65535` | — | host port mapping |
| `owner_password` | secret / URL-safe | `^[A-Za-z0-9_-]+$` | `POSTGRES_OWNER_PASSWORD` | postgres init script (role bootstrap) |
| `migrator_password` | secret / URL-safe | `^[A-Za-z0-9_-]+$` | `POSTGRES_MIGRATOR_PASSWORD` | `system.sh migrate` (EF design-time conn-string) |
| `api_password` | secret / URL-safe | `^[A-Za-z0-9_-]+$` | `POSTGRES_API_PASSWORD` | `Api` runtime conn-string |
| database name `platform` | **fixed constant** | — | — | init script, EF migrations, conn-strings |
| roles `owner`/`migrator`/`api` | **fixed constant** | — | — | init script, EF migration SQL, RLS policies |

**Assembled connection strings.** `build-config` derives two Npgsql connection
strings from the postgres fields above + the fixed `platform` db name and fixed
role names, and writes them under these exact env-var names:

| Generated `.env` var | `.env` path | Assembled from | Consumer |
|---|---|---|---|
| `MIGRATOR_CONNECTION_STRING` | `src/DataAccess/.env` | `container_host`/`container_port` + role `migrator` + `migrator_password` + db `platform` | `system.sh migrate` (EF design-time `IDesignTimeDbContextFactory`) |
| `API_CONNECTION_STRING` | `src/Api/.env` | `container_host`/`container_port` + role `api` + `api_password` + db `platform` | `Api` runtime least-privilege DB connection |

Generated per-component `.env`: `src/postgres/.env` (postgres fields above),
`src/DataAccess/.env` (`MIGRATOR_CONNECTION_STRING`), `src/Api/.env`
(`API_CONNECTION_STRING` + the keycloak/Api fields below). Only the **host, ports,
and generated passwords** flow from `config.json`. The **role names
(`owner`/`migrator`/`api`) and the database name (`platform`) are FIXED scaffold
constants** — they are NOT in `config.json` and are used as literals consistently
across `build-config`'s connection-string assembly, the postgres init SQL, the EF
migration SQL, and the RLS policies (fixed names are precisely what lets the static
migration SQL reference them literally — see §3).

### `keycloak` (`systems[]` entry `keycloak`)

| `config.json` field | Kind | Validator | Generated `.env` var | Consumer |
|---|---|---|---|---|
| `host` | structural | host (`^[A-Za-z0-9.-]+$`) | — (host-side tooling) | devcontainer tooling |
| `container_host` | structural | container-name (`^[a-zA-Z0-9][a-zA-Z0-9_.-]+$`) | `KEYCLOAK_HOST` | compose, in-network references |
| `container_port` | structural | port `1..65535` | `KEYCLOAK_PORT` | in-network connections |
| `port` | structural | port `1..65535` | — | host port mapping |
| `realm` | structural | realm/filename-safe (`^[A-Za-z0-9._-]+$`) | `KEYCLOAK_REALM` | realm-import stamp, `Api` JWT validation |
| `public_url` | structural | URL (`^https?://[^[:space:]]+$`) | `KEYCLOAK_PUBLIC_URL` | `Api` issuer/authority, SPA public config |
| `admin_user` | structural | — | `KEYCLOAK_ADMIN` | keycloak container bootstrap admin |
| `admin_password` | secret / URL-safe | `^[A-Za-z0-9_-]+$` | `KEYCLOAK_ADMIN_PASSWORD` | keycloak container bootstrap admin |
| `webapp_client_id` | **public, structural** | client-id (`^[A-Za-z0-9._-]+$`) | (realm import + SPA public config) | WebApp browser client (non-secret) |
| `marketingsite_client_id` | **public, structural** | client-id (`^[A-Za-z0-9._-]+$`) | (realm import + SPA public config) | MarketingSite browser client (non-secret) |
| `api_client_id` | structural | client-id (`^[A-Za-z0-9._-]+$`) | `KEYCLOAK_API_CLIENT_ID` | `Api` confidential client |
| `api_client_secret` | secret / URL-safe | `^[A-Za-z0-9_-]+$` | `KEYCLOAK_API_CLIENT_SECRET` | `Api` confidential client; realm-import stamp |

**Keycloak client model.** The realm defines:

- **Two public SPA clients** (`webapp`, `marketingsite`) — non-secret, public
  clients that reach the browser. Their client IDs are structural public values,
  never secrets.
- **One `Api` confidential client** — has a generated secret (`api_client_secret`)
  and **`serviceAccountsEnabled: true`** (its own service account for
  machine-to-machine calls). There are **NO separate per-service service-account
  client objects** — `BusinessLogic`/`DataAccess`/`Framework` are libraries, not
  services, so the `Api`'s own service account is the only one.

The committed realm template carries dummy secrets; `build-config` stamps a
gitignored runtime realm-import file (`src/keycloak/import/<realm>-realm.json`)
injecting the real realm/client ids/secrets from `config.json`. Real secrets are
never committed in the realm import.

### SPA public config (`MarketingSite`, `WebApp` `systems[]` entries)

Each SPA fetches **non-secret public runtime config** at runtime from a gitignored
`src/<SPA>/public/config.json` that `build-config` stamps. No secrets ever reach
`dist/`.

| `config.json` field | Kind | Validator | Stamped into | Consumer |
|---|---|---|---|---|
| `realm_url` | public, structural | URL (`^https?://[^[:space:]]+$`) | `src/<SPA>/public/config.json` `realmUrl` | SPA OIDC config (browser) |
| `public_client_id` | public, structural | client-id (`^[A-Za-z0-9._-]+$`) | `src/<SPA>/public/config.json` `clientId` | SPA OIDC config (browser) |

### `Api` (`systems[]` entry `Api`)

| `config.json` field | Kind | Validator | Generated `.env` var | Consumer |
|---|---|---|---|---|
| `host` | structural | host (`^[A-Za-z0-9.-]+$`) | `API_HOST` | `Api` listener |
| `port` | structural | port `1..65535` | `API_PORT` | `Api` listener |

The `Api` also reads `API_CONNECTION_STRING` (the postgres `api`-role connection
string, see the postgres section) and the keycloak issuer/client values
(`KEYCLOAK_REALM`, `KEYCLOAK_PUBLIC_URL`, `KEYCLOAK_API_CLIENT_ID`,
`KEYCLOAK_API_CLIENT_SECRET`) — all assembled by `build-config` into `src/Api/.env`
— for JWT validation and the least-privilege DB connection.

### `services{}` — external dependencies

There are **two canonical `services{}` entries**, both **always present** (no opt-in
branch) with key-set parity across `config.json` and `config.deploy.json`: the
Anthropic-compatible `claude-api` and the OpenAI-compatible `openai-api`. Each carries
an explicit `base_url` + `api_key`. `build-config` (unconditionally) distributes all
four values into the consuming component's `.env` (the `Api` by default), under the
**SDK-standard env-var names** below.

| `config.json` field | Kind | Validator | Generated `.env` var | Consumer |
|---|---|---|---|---|
| `services.claude-api.base_url` | external endpoint | service base-URL grammar (`^https?://[A-Za-z0-9.-]+(:port)?(/path)?$` + port `1..65535`) | `ANTHROPIC_BASE_URL` | the `Api` (Anthropic SDK base URL) |
| `services.claude-api.api_key` | external credential | **opaque** (transport-safe only) | `ANTHROPIC_API_KEY` | the `Api` (Anthropic SDK key) |
| `services.openai-api.base_url` | external endpoint | service base-URL grammar (as above) | `OPENAI_BASE_URL` | the `Api` (OpenAI SDK base URL) |
| `services.openai-api.api_key` | external credential | **opaque** (transport-safe only) | `OPENAI_API_KEY` | the `Api` (OpenAI SDK key) |
| `localLlm.embeddingModel` (opt-in; see below) | — | — | `OPENAI_EMBEDDING_MODEL=local-embed` | the `Api` (embeddings model name; only emitted when embeddings opted in) |

**Non-opt-in (real-provider) defaults:** `claude-api.base_url=https://api.anthropic.com`,
`openai-api.base_url=https://api.openai.com/v1`, keys `REPLACE_ME`. **Opt-in (local
LLM mock) values:** `claude-api.base_url=http://127.0.0.1:4000`,
`openai-api.base_url=http://127.0.0.1:4000/v1`, keys `sk-local-mock` — repointed by the
scaffold opt-in engine (the four env-var names are unchanged so app code never moves).

**`base_url` validation.** Each `base_url` is validated against an
**injection-resistant** grammar — a restrictive host character class
(`[A-Za-z0-9.-]+`, which rejects `?#@[]:` and other non-host characters in the host
portion) plus a **separately range-checked** port (`1..65535` — the `[0-9]{1,5}` class
alone would accept `99999`). An optional path may follow. This is anti-injection (a
malformed URL cannot poison the `.env`), **not** RFC-1123 hostname correctness:
odd-but-harmless hosts like `.example.com` or `-bad` are accepted (they simply fail to
resolve). It is stricter than the permissive `public_url`/`realm_url` `URL` validator.

**`.env` encoding (the consumer contract).** `src/Api/.env` is consumed by **docker
compose's `env_file:` parser** (see §7; `src/Api/Program.cs` reads these from the
environment). That parser takes each value **raw** (no shell close-reopen quoting —
surrounding quotes are *stripped*, so a `KEY='value'` form would NOT round-trip) and
performs `$`/`${VAR}` interpolation, and it cannot represent embedded newlines.
`build-config` therefore emits all four values **verbatim** and **rejects** any
character (or sequence) that cannot round-trip across that consumer: CR / LF /
control characters (break line parsing), `$` (compose interpolation; the `$$`
escape is compose-only and would corrupt a plain shell `source`), and a
**whitespace-immediately-followed-by-`#` sequence** (compose treats it as a
trailing inline comment and *truncates* the value — empirically `KEY=sk #x`
parses to `sk`). Punctuation that round-trips raw is accepted: a standalone space,
a `#` **not** preceded by whitespace (e.g. a URL fragment `host/p#frag`), `"`, and
`'`. This applies to all four values — a grammar-valid `base_url` *path* may still
carry such punctuation.

External-service `api_key`s ship as `REPLACE_ME` for the operator and are **exempt**
from the URL-safe alphabet validation — opaque provider keys may contain any
characters (only the transport-safety check above applies). Only fields declared
URL-safe (the generated postgres/keycloak credentials above) are alphabet-validated.

#### `localLlm` (opt-in only) — backs the `claude-api`/`openai-api` services in local dev

When the local LLM mock stack is installed (scaffold `--local-llm`), an **opt-in-only**
top-level `localLlm` object appears in `config.json`:

| `config.json` field | Kind | Validator | Drives |
|---|---|---|---|
| `localLlm.model` | opt-in, model name | Ollama model-name grammar `^[A-Za-z0-9._/-]+(:[A-Za-z0-9._-]+)?$` | the stamped `etc/local-llm/litellm/config.yaml` (`@@LLM_MODEL@@` → raw model) **and** the `LLM_MODEL` exported by `system.sh up`/`down` for the model-pull |
| `localLlm.embeddingModel` | opt-in, model name (optional) | same grammar | the `local-embed` entry in `config.yaml` (`@@LLM_EMBED_MODEL@@`) + the exported `LLM_EMBED_MODEL`; also makes `build-config` emit `OPENAI_EMBEDDING_MODEL=local-embed` |

The model-name grammar accepts a namespaced repo (`/`) and a single `:tag` suffix and
rejects whitespace / shell metacharacters / YAML-sensitive characters, so a hostile or
hand-edited value cannot corrupt the stamped `config.yaml` or the exported `LLM_MODEL`.

`build-config` behavior for `localLlm` (no `.env` is written for it):

- **Absent `localLlm`** → no-op (the `claude-api`/`openai-api` `.env` vars still emit).
- **`.localLlm` present but not an object** → fails clearly (a malformed hand-edit must
  not silently skip stamping while the app still points at the local gateway).
- **`localLlm.model` present** → validates it, then stamps the **gitignored**
  `etc/local-llm/litellm/config.yaml` from `config.yaml.template` by replacing every
  `@@LLM_MODEL@@` (it appears in both the wildcard `"*"` route and the `local` alias)
  with the raw model. The template line is already `ollama_chat/@@LLM_MODEL@@`, so the
  `ollama_chat/` prefix is **not** re-added.
- **Embeddings block (R12)** — the `local-embed` entry lives between
  `# >>> embeddings` / `# <<< embeddings` sentinel markers. `build-config` does a
  **block operation**: when `embeddingModel` is present it keeps the block, strips the
  marker lines, and substitutes `@@LLM_EMBED_MODEL@@`; when absent it **deletes the
  entire marked block** (no orphan entry, no leftover token, valid YAML either way).
- **`embeddingModel` set without `model`** → fails clearly (embeddings require a chat
  opt-in).
- **`localLlm.model` present but `config.yaml.template` missing** → fails clearly
  (opt-in invariant — never silently skipped). The template is also structurally
  validated (markers balanced/non-duplicated, required tokens present) and a post-stamp
  scan fails if any `@@…@@` token remains in the generated `config.yaml`.

**The local LLM mock stack itself is internal dev tooling — NOT a `systems[]`
component and NOT itself a `services{}` external dependency.** It *backs* the
`claude-api`/`openai-api` services in local dev (the app keeps talking to the same two
service endpoints; only their `base_url` repoints to the local gateway), mirroring how
the observability stack is classified as dev tooling rather than a `systems[]` entry.
See `docs/local-llm.md` for the stack itself.

### Class-library components

`Framework`, `DataAccess`, `BusinessLogic`, and the removable `SampleApp` are .NET
class libraries / a console sample; they carry a minimal entry (`{ "name": "…" }`)
to honor the `systems[]` invariant and have no configurable fields.

## 5. `build-config` and the deploy handoff

`./system.sh build-config` reads its source config and distributes the downstream
artifacts (per-component `.env` files, each SPA's public `config.json`, the
gitignored Keycloak realm-import file). It performs config→file edits via
structured `jq --arg` updates (never string replacement), and validates every
field declared URL-safe against the alphabet (§6) plus the structural validators in
§4 (realm/client-id regex, port `1..65535`, host/container-name shapes), exiting
non-zero with a descriptive error on any violation.

`build-config` takes an optional source:

```bash
./system.sh build-config                 # defaults to ./config.json
./system.sh build-config --config <path> # any concrete config file
```

The `--config <path>` form is the **deploy handoff**: a CI/CD pipeline renders
`config.deploy.json` (substituting its `{{VAR-NAME}}` placeholders from its secret
store) to a concrete file, then runs `build-config --config <rendered>`. The same
validation applies to whatever concrete config is passed.

## 6. Password alphabet (generated secrets)

All **generated** local-component passwords (the postgres role passwords, the
keycloak admin password, the Api confidential-client secret) must match the
URL-safe base64 alphabet:

```
[A-Za-z0-9_-]+
```

(letters, digits, underscore, hyphen — no padding `=`, no `/`, no `+`). This keeps
secrets safe to embed without escaping in:

- SQL literals (no quoting beyond Postgres's own `'...'` rules)
- `.env` file lines (no shell-quoting / `$VAR` expansion concerns)
- connection-string URI components (no percent-encoding required)

The scaffold generates each secret independently (every occurrence is a distinct
value) with:

```bash
openssl rand -base64 32 | tr -d '=' | tr '/+' '_-'
```

— a 43-character URL-safe string. `build-config` validates each URL-safe field
against the alphabet and errors on any out-of-alphabet character. External-service
credentials (`services{}`) are exempt — see §4.

## 7. 12-factor configuration and `config.deploy.json`

This repo adopts factor III ("Config") of the
[12-factor methodology](https://12factor.net/config) as a repo-wide standard. In
one sentence: **`config.json` is the source of truth at build time;
`build-config` distributes per-component `.env` files (and the SPA public config +
realm import); runtime components read only from environment / their stamped
config.**

The flow:

1. The operator edits `config.json` with values for their environment.
2. `./system.sh build-config` reads it and writes the downstream artifacts
   (`src/<component>/.env`, each SPA's `public/config.json`, the realm import).
3. Each runtime container reads its values from environment variables only —
   typically loaded by `docker compose` from the per-component `.env` via
   `env_file:` and `${VAR}` interpolation.
4. **`config.json` is never mounted into runtime containers**, and runtime
   components never read `config.json` directly. Any new component follows this
   pattern.

This separation buys the three properties 12-factor names: strict separation of
config from code, environment parity (a new environment differs only in `.env`
values, not in how config is consumed), and secret rotation without code change.

The intermediary build step is a deliberate departure from the strictest 12-factor
reading: we keep ONE tracked source-of-truth file because (a) this is a
single-operator-per-environment private repo, (b) the operator needs one place to
edit values that map into multiple `.env` files, and (c) rotation is a single
command. The crucial property — runtime reads only from environment — is preserved.

### Secret boundary and `config.deploy.json`

- **Tracked `config.json` holds dev-only generated local secrets.** It is committed
  as a deliberate trade-off for a small single-operator repo. These are NOT real
  or production secrets.
- **Real secrets are never committed.** They enter only via `config.deploy.json`'s
  `{{VAR-NAME}}` placeholders, which the CI/CD pipeline renders from its secret
  store at deploy time, plus the gitignored runtime realm-import file.
- **`config.deploy.json` mirrors the `config.json` shape** with every secret (and
  every deployment-environment string such as a host or realm URL) as a quoted
  `{{VAR-NAME}}` placeholder. **Structural integer fields — the `*port` fields —
  stay integer literals**, NOT quoted placeholders, so that a plain text-substituted
  render stays schema-valid (the schema in §4 requires integer ports `1..65535`; a
  quoted `"{{PORT}}"` would render to a string and fail validation). Override a
  deploy port by editing the rendered config, not the template. The two files keep
  an **identical key-set** (a CI diff-check guards drift). `config.deploy.json` is a
  deployment template and is **NEVER fed to validation directly** — the pipeline
  renders it to a concrete file first, then runs `build-config --config <rendered>`
  (§5).
- A future multi-tenant or public variant would replace tracked `config.json` with
  a vaulted secret store feeding `build-config` at the same point; the downstream
  contract (per-component `.env`, runtime reads from env only) does not change.
