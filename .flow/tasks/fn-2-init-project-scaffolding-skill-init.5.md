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
_(filled on completion)_

## Evidence
_(filled on completion)_
