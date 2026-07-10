#!/usr/bin/env bash
# Description: First-create provisioning for this project's dev container.
#
# Installs the script-only tools that don't ship as devcontainer features (the
# features themselves — node, the cloud CLIs, gh, jq, docker-in-docker — are in
# devcontainer.json). Then it best-effort enables the Claude Code marketplace +
# the nine curated plugins. MCP servers are NOT installed here: they are declared
# build-time-complete in the committed .mcp.json (see docs/dev-container.md).
#
# Contract (docs/dev-container.md §2): this script is IDEMPOTENT and re-runnable.
# Required tool installs run under `set -e`; best-effort enable-steps (plugins,
# anything needing per-user auth) are isolated so a single failure WARNS but never
# aborts the build. A fresh `devcontainer build` must succeed end-to-end.

set -euo pipefail

# ---- logging ---------------------------------------------------------------
log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '    \033[1;32mok\033[0m  %s\n' "$*"; }
warn() { printf '    \033[1;33mwarn\033[0m %s\n' "$*" >&2; }

# Run a best-effort (non-fatal) step: log the failure as a warning, keep going.
# Usage: try "<human label>" <command> [args...]
try() {
  local label="$1"; shift
  if "$@"; then
    ok "$label"
  else
    warn "$label failed (rc=$?) — continuing (best-effort)"
  fi
}

have() { command -v "$1" >/dev/null 2>&1; }

# ---- pinned tool versions --------------------------------------------------
# Pin every script-installed tool to an EXACT version so a fresh container build
# is reproducible (the devcontainer features are pinned in devcontainer.json;
# these are the script-only installs). Bump deliberately. The Angular CLI is the
# one exception — it is pinned by READING the root package.json (single source).
DUCKDB_VERSION="v1.4.2"      # DuckDB CLI (https://github.com/duckdb/duckdb/releases)
CODEX_VERSION="0.5.0"        # OpenAI Codex CLI (npm @openai/codex)
GLAB_VERSION="1.95.0"        # GitLab CLI / glab (https://gitlab.com/gitlab-org/cli/-/releases)
STRIX_VERSION="1.0.4"        # Strix AI pentest agent (PyPI strix-agent; opt-in, needs Python >=3.12)
UV_VERSION="0.11.28"         # Astral uv (provisions Strix's isolated Python 3.12 tool env; opt-in)

# Pin the Angular CLI to the SAME exact version the root package.json declares —
# the single source of truth (owned by the SPA task). Never hard-code a second
# copy here: read it back so CLI and project deps can never drift.
angular_version() {
  local pkg="package.json"
  [[ -f "$pkg" ]] || return 1
  if have jq; then
    jq -r '.devDependencies["@angular/cli"] // .dependencies["@angular/core"] // empty' "$pkg"
  fi
}

# ---- required tool installs (strict: set -e aborts on failure) -------------

install_angular_cli() {
  log "Angular CLI"
  local ver; ver="$(angular_version || true)"
  if have ng && [[ -n "$ver" ]] && ng version 2>/dev/null | grep -q "$ver"; then
    ok "Angular CLI $ver already present"
    return 0
  fi
  if [[ -n "$ver" ]]; then
    npm install -g "@angular/cli@$ver"
    ok "Angular CLI pinned to $ver (from package.json)"
  else
    npm install -g @angular/cli
    warn "package.json @angular version not found — installed latest Angular CLI"
  fi
}

install_dotnet_tools() {
  log "dotnet local tools (dotnet-ef, pinned via .config/dotnet-tools.json)"
  if [[ -f .config/dotnet-tools.json ]]; then
    dotnet tool restore
    ok "dotnet tool restore complete"
  else
    warn ".config/dotnet-tools.json not found — skipping dotnet tool restore"
  fi
}

install_duckdb() {
  log "DuckDB CLI"
  if have duckdb; then
    ok "duckdb already present ($(duckdb --version 2>/dev/null || echo present))"
    return 0
  fi
  # Official install script, PINNED via DUCKDB_INSTALL_VERSION so the build is
  # reproducible (never silently tracks "latest"). Installs into ~/.duckdb/cli.
  curl -fsSL https://install.duckdb.org | DUCKDB_INSTALL_VERSION="$DUCKDB_VERSION" bash
  # The installer adds duckdb to ~/.duckdb/cli/latest; expose it on PATH for this
  # shell and via a profile drop-in so future shells (and `ng`/`dotnet`) see it.
  if [[ -x "$HOME/.duckdb/cli/latest/duckdb" ]]; then
    export PATH="$HOME/.duckdb/cli/latest:$PATH"
  fi
  ok "DuckDB CLI installed"
}

install_acli() {
  log "Atlassian CLI (acli — Jira + Confluence)"
  if have acli; then
    ok "acli already present"
    return 0
  fi
  # Atlassian's official static binary. Resolve arch; install to /usr/local/bin.
  local arch dl
  case "$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) warn "unsupported arch $(uname -m) for acli — skipping"; return 0 ;;
  esac
  dl="https://acli.atlassian.com/linux/latest/acli_linux_${arch}/acli"
  if curl -fsSL "$dl" -o /tmp/acli && sudo install -m 0755 /tmp/acli /usr/local/bin/acli; then
    rm -f /tmp/acli
    ok "acli installed (${arch})"
  else
    rm -f /tmp/acli
    warn "acli download failed — install manually from https://developer.atlassian.com/cloud/acli/"
  fi
}

install_glab() {
  log "GitLab CLI (glab)"
  if have glab; then
    ok "glab already present ($(glab --version 2>/dev/null | head -1 || echo present))"
    return 0
  fi
  # GitLab's official release binary. GitLab CLI ships NO maintained first-party
  # devcontainer feature (gh does — that's why it lives in devcontainer.json),
  # so glab installs here, mirroring acli. PINNED via GLAB_VERSION so a fresh
  # build is reproducible. Resolve arch; the tarball holds bin/glab.
  local arch dl tmp
  case "$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) warn "unsupported arch $(uname -m) for glab — skipping"; return 0 ;;
  esac
  dl="https://gitlab.com/gitlab-org/cli/-/releases/v${GLAB_VERSION}/downloads/glab_${GLAB_VERSION}_linux_${arch}.tar.gz"
  tmp="$(mktemp -d)"
  if curl -fsSL "$dl" -o "$tmp/glab.tar.gz" \
     && tar -xzf "$tmp/glab.tar.gz" -C "$tmp" bin/glab \
     && sudo install -m 0755 "$tmp/bin/glab" /usr/local/bin/glab; then
    rm -rf "$tmp"
    ok "glab $GLAB_VERSION installed (${arch})"
  else
    rm -rf "$tmp"
    warn "glab download failed — install manually from https://gitlab.com/gitlab-org/cli/-/releases"
  fi
}

install_claude_code() {
  log "Claude Code CLI"
  if have claude; then
    ok "claude already present"
    return 0
  fi
  curl -fsSL https://claude.ai/install.sh | bash
  # The installer drops the binary in ~/.local/bin; expose for the rest of setup.
  [[ -d "$HOME/.local/bin" ]] && export PATH="$HOME/.local/bin:$PATH"
  ok "Claude Code installed"
}

install_codex_cli() {
  log "Codex CLI"
  if have codex; then
    ok "codex already present"
    return 0
  fi
  # OpenAI Codex CLI ships on npm; install globally PINNED (node feature provides
  # npm). Exact version keeps the build reproducible; bump CODEX_VERSION to update.
  npm install -g "@openai/codex@$CODEX_VERSION"
  ok "Codex CLI $CODEX_VERSION installed"
}

# ---- best-effort: Claude Code marketplace + plugins ------------------------
# Declarative source of truth for the marketplace is .claude/settings.json
# (extraKnownMarketplaces); these CLI steps are an advisory smoke-enable. The
# remote is the PUBLISHED git marketplace — never the local ./src sources, which
# a scaffolded project does not contain. All steps are non-fatal.

MARKETPLACE_REMOTE="SoftwareAssassin2/Plugins"
# The nine curated marketplace plugins (NOT init-project itself, NOT the two MCP
# servers — those are declared in .mcp.json). Names match .claude-plugin/marketplace.json.
PLUGINS=(
  dick
  handoff
  tdd
  ubiquitous-language
  domain-modeling
  grilling
  grill-with-docs
  preferred-browser-automation-plugin
  preferred-ralph-loops-plugin
)

enable_claude_plugins() {
  log "Claude Code marketplace + plugins (best-effort)"
  if ! have claude; then
    warn "claude CLI not on PATH — skipping plugin enable (re-run setup.sh after Claude Code is installed)"
    return 0
  fi
  try "register marketplace $MARKETPLACE_REMOTE" \
    claude plugin marketplace add "$MARKETPLACE_REMOTE"
  local p
  for p in "${PLUGINS[@]}"; do
    try "install plugin $p" claude plugin install "${p}@${MARKETPLACE_REMOTE}"
  done
}

# ---- best-effort: opt-in Strix AI pentest agent ----------------------------
# Installed ONLY when the project opted in at scaffold time — the presence of
# etc/strix/ (laid down by `init-project --strix`) is the install signal. Strix
# ships on PyPI as `strix-agent` and needs Python >=3.12, which the .NET base image
# does not provide; `uv` fetches a standalone 3.12 and installs the PINNED CLI in an
# isolated tool env (exposing `strix` on ~/.local/bin). Docker (the docker-in-docker
# feature) backs Strix's sandbox at RUNTIME. Per-user LLM auth (STRIX_LLM +
# LLM_API_KEY) is a documented follow-up — see etc/strix/README.md. Best-effort: a
# network failure warns but never aborts the build.
install_strix() {
  log "Strix AI pentest agent (opt-in)"
  if [[ ! -f etc/strix/README.md ]]; then
    ok "Strix not enabled (no etc/strix/) — skipping"
    return 0
  fi
  export PATH="$HOME/.local/bin:$PATH"
  if ! have uv; then
    # Astral's official installer, PINNED via the versioned URL so the build is
    # reproducible (never silently tracks "latest"). Installs uv into ~/.local/bin.
    try "install uv $UV_VERSION" bash -c "curl -LsSf https://astral.sh/uv/${UV_VERSION}/install.sh | sh"
  fi
  if ! have uv; then
    warn "uv unavailable — cannot install Strix; install it later per etc/strix/README.md"
    return 0
  fi
  # uv provisions Python 3.12 on demand and installs the pinned strix-agent as an
  # isolated tool. The `strix` command lands on ~/.local/bin.
  try "uv tool install strix-agent==$STRIX_VERSION" \
    uv tool install --python 3.12 "strix-agent==$STRIX_VERSION"
}

main() {
  log "Provisioning the dev container"

  # Required toolchain (set -e: a failure here is a real build failure).
  install_angular_cli
  install_dotnet_tools
  install_duckdb
  install_acli
  install_glab
  install_claude_code
  install_codex_cli

  # Best-effort enable-steps (never abort the build).
  enable_claude_plugins
  install_strix

  log "Dev container provisioning complete"
  printf '\n  MCP servers (context7, github-mcp-server) are declared in .mcp.json.\n'
  printf '  Per-user auth (gh, glab, the cloud CLIs, acli, GitHub MCP token) is a follow-up\n'
  printf '  documented in docs/dev-container.md.\n\n'
}

main "$@"
