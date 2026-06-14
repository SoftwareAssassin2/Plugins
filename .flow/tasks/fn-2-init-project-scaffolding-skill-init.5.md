---
satisfies: [R5]
---

## Description
Author the **observability** compose stack template (Grafana + OpenTelemetry Collector) — an **internal tooling** stack under `etc/observability/`, OUTSIDE `.devcontainer/` AND outside the `src/<component>`/`systems[]` invariant (dev tooling, not a system component nor a `services{}` external dep), brought up by `system.sh up`.

**Size:** M
**Files:** `src/init-project/templates/etc/observability/docker-compose.yml` (path per generalized layout), OTel Collector config, Grafana provisioning (`datasources/`, `dashboards/`)

## Approach (from docs-scout)
- Grafana: `grafana/grafana` (pin), mount `provisioning/{datasources,dashboards}` → `/etc/grafana/provisioning`.
- OTel Collector: `otel/opentelemetry-collector-contrib` (pin), config at `/etc/otelcol-contrib/config.yaml`, expose 4317/4318/13133.
- Orchestrated by `system.sh up`/`down` (fn-2….6) **hardcoded** (it's tooling, not a `systems[]` component, so it has no `systems[]` entry); lives under `etc/observability/`, OUTSIDE `.devcontainer/`.

## Investigation targets
**Required:**
- `src/init-project/templates/docs/dev-container.md` (fn-2….8) — services-live-outside rule

## Acceptance
- [ ] Compose stack defines Grafana + OTel Collector with pinned images + config files
- [ ] Launchable via `system.sh up`; lives under `etc/observability/`, outside `.devcontainer/` and outside the `systems[]` invariant (hardcoded in up/down, no `systems[]` entry)
- [ ] `docker compose config` validates the template

## Done summary
Authored the build-time-complete observability dev-tooling stack as templates under
`templates/etc/observability/`: a pinned docker-compose stack (Grafana 11.4.0 + OTel
Collector contrib 0.116.0 + Prometheus v3.0.1 as the query backend), the OTel
Collector config (OTLP receivers -> Prometheus exporter + debug), a Prometheus scrape
config, and Grafana provisioning (Prometheus datasource + dashboard provider + starter
dashboard). It is internal tooling (no config.json systems[] entry; up/down/status
already hardcode the path), ports are loopback-bound, and 21 focused scaffold-test
assertions were added (164 -> 185 passing). Codex impl-review: SHIP.
## Evidence
- Commits: 54050ca, 9545b0c, 31e93c4
- Tests: bash src/init-project/tests/scaffold_test.sh (185 passed, 0 failed), bash src/init-project/tests/dispatcher_test.sh (60 passed, 0 failed), docker compose -f etc/observability/docker-compose.yml config (VALID, on template + freshly scaffolded copy), python3 YAML/JSON parse of all 6 observability files (ok)
- PRs: