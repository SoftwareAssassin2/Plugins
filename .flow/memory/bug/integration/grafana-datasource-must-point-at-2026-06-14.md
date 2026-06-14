---
title: "Grafana datasource must point at Prometheus, not the OTel Collector exporter end"
date: "2026-06-14"
track: bug
category: integration
module: templates/etc/observability/docker-compose.yml
tags: [observability, grafana, opentelemetry, prometheus, docker-compose]
problem_type: integration
symptoms: Grafana Prometheus datasource pointed at OTel Collector :8889 exposition endpoint; panels/dashboards return no data
root_cause: "Collector prometheus exporter serves /metrics exposition text, not the /api/v1/query_range query API Grafana needs"
resolution_type: fix
---

## Problem
A Grafana provisioning stack pointed its Prometheus-type datasource directly at
an OpenTelemetry Collector's `prometheus` exporter endpoint (`otel-collector:8889`).
That endpoint serves Prometheus *exposition* format (`/metrics` text) — it is NOT
a Prometheus query API. Grafana Prometheus panels call `/api/v1/query_range`, so
the provisioned datasource and dashboards were non-functional.

## Solution
Add a real Prometheus service (pinned `prom/prometheus:v3.0.1`) that scrapes the
collector exporter (`otel-collector:8889`) and serves the query API; repoint the
Grafana datasource at `http://prometheus:9090`. See
`templates/etc/observability/docker-compose.yml` + `prometheus/prometheus.yml`.

Also hardened the dev-tooling compose: bind all published ports to `127.0.0.1`
(anonymous-admin Grafana must never be LAN-reachable) and drop hardcoded
`container_name` (collides across two scaffolded projects / pre-existing containers).

## Prevention
When wiring Grafana to OTel, remember the collector exporter is a scrape target,
not a query backend — Grafana needs Prometheus (or Mimir/Thanos) in between. Add a
scaffold-test assertion that the datasource URL points at the query backend, that
ports are loopback-bound, and that no `container_name` is hardcoded.
