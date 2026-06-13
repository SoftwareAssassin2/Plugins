---
satisfies: [R5]
---

## Description
Scaffold a separate **observability compose stack** template (Grafana + OpenTelemetry Collector) that lives OUTSIDE `.devcontainer/`, consistent with the dev-container philosophy that runtime services are not part of the dev environment. Brought up via the project's dispatcher CLI.

**Size:** M
**Files:** `src/init-project/templates/etc/observability/docker-compose.yml` (path TBD per generalized layout), OTel Collector config, Grafana provisioning dirs (`datasources/`, `dashboards/`)

## Approach (from docs-scout)
- Grafana: `grafana/grafana` image, mount `provisioning/{datasources,dashboards}` → `/etc/grafana/provisioning`.
- OTel Collector: `otel/opentelemetry-collector-contrib`, config at `/etc/otelcol-contrib/config.yaml`, expose 4317/4318/13133.
- Wire a dispatcher subcommand (fn-2….6) to bring the stack up/down (e.g. `./<name>.sh observability-up`).
- Keep this OUT of `.devcontainer/` per `dev-container.md` service-container rule.

## Investigation targets
**Required:**
- `src/project-init/dev-container.md:26` — service-containers-live-outside rule (the principle this task honors)

## Acceptance
- [ ] Compose stack template defines Grafana + OTel Collector with pinned images
- [ ] Grafana provisioning + OTel config files included and referenced correctly
- [ ] Stack is launchable via a dispatcher subcommand; lives outside `.devcontainer/`
- [ ] `docker compose config` validates the template (smoke test)

## Done summary
_(filled on completion)_

## Evidence
_(filled on completion)_
