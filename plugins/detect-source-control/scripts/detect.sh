#!/usr/bin/env bash
#
# detect.sh — detect the source-control forge of the current git repo.
#
# Emits a parseable, newline-delimited key=value block on stdout (all keys
# present, in this exact order, no surrounding prose):
#
#   forge=github|gitlab|unsupported
#   host=<hostname>|unknown
#   cli=gh|glab|none
#   cli_authenticated=true|false
#   supported=true|false
#
# Contract notes:
#   - forge=unsupported is a SUCCESSFUL result (exit 0), not an error.
#   - Exit 0 whenever the block is emitted (including unsupported). Non-zero
#     ONLY for operational failures where the block cannot be produced
#     (git missing, not inside a git repo).
#   - Consumers key the hard-stop off `supported=false` + exit 0, never off a
#     non-zero exit.
#
# Detection is two-phase, precedence-major, stopping at the first confident
# match. Every probe is strictly READ-ONLY — no mutating command is ever run.
#   Phase A (remotes): iterate remotes in precedence order (origin, upstream,
#     then the rest by name). Per remote: exact host, then host substring. The
#     first remote that confidently classifies wins and returns immediately —
#     origin is authoritative; a later remote never overrides an earlier one.
#   Phase B (repo-global, only if no remote resolved):
#     (1) CI-config: .github/ -> github, .gitlab-ci.yml -> gitlab, BOTH -> unsupported.
#     (2) repo-scoped read-only CLI probe: `gh repo view` -> github,
#         `glab repo view` -> gitlab, BOTH succeed -> unsupported.
#     (3) else unsupported.
#   `auth status` is NEVER a forge signal — it proves global auth, not repo
#   ownership. It runs only AFTER forge detection to populate cli_authenticated.

set -uo pipefail

# --- pure helpers (also unit-tested by sourcing this file) -----------------

# normalize_host <git-remote-url> -> host on stdout (empty if unparseable).
# Handles HTTPS (scheme://[user[:token]@]host[:port]/path) and scp-like SSH
# ([user@]host:path). Both forms are reduced to the bare host.
normalize_host() {
  local url host
  url="$1"
  host=""
  case "$url" in
    *://*)
      host="${url#*://}"   # [user[:token]@]host[:port]/path
      host="${host#*@}"    # host[:port]/path   (no-op when no '@')
      host="${host%%/*}"   # host[:port]
      host="${host%%:*}"   # host
      ;;
    *@*:*)
      host="${url#*@}"     # host:path
      host="${host%%:*}"   # host
      ;;
    *:*/*)
      host="${url%%:*}"    # bare scp form without user: host:path
      ;;
    *)
      host=""
      ;;
  esac
  printf '%s' "$host"
}

# classify_host <host> -> github | gitlab | (empty). Exact host first, then
# substring (covers self-hosted github.acme.com / gitlab.internal).
classify_host() {
  local host lc
  host="$1"
  lc="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')"
  case "$lc" in
    github.com) printf 'github'; return 0 ;;
    gitlab.com) printf 'gitlab'; return 0 ;;
  esac
  case "$lc" in
    *github*) printf 'github'; return 0 ;;
    *gitlab*) printf 'gitlab'; return 0 ;;
  esac
  return 0
}

# ordered_remotes -> remote names, one per line, in precedence order:
# origin, then upstream, then everything else alphabetically.
ordered_remotes() {
  local all
  all="$(git remote 2>/dev/null)"
  [ -z "$all" ] && return 0
  printf '%s\n' "$all" | grep -qx origin && printf 'origin\n'
  printf '%s\n' "$all" | grep -qx upstream && printf 'upstream\n'
  printf '%s\n' "$all" | grep -vx origin | grep -vx upstream | sort
  return 0
}

# --- main ------------------------------------------------------------------

main() {
  # Operational preconditions — the only cases that exit non-zero.
  if ! command -v git >/dev/null 2>&1; then
    printf 'detect-source-control: git is not installed\n' >&2
    return 2
  fi
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf 'detect-source-control: not inside a git repository\n' >&2
    return 3
  fi

  local forge host cli cli_auth supported root
  forge=""
  host="unknown"

  # Phase A — remotes, precedence-major, first confident remote wins.
  local r url h f
  for r in $(ordered_remotes); do
    url="$(git remote get-url "$r" 2>/dev/null)"
    [ -z "$url" ] && continue
    h="$(normalize_host "$url")"
    [ -z "$h" ] && continue
    # Preserve the first parseable host (precedence-major). host=unknown is
    # reserved for "no remote host could be parsed"; an unsupported-but-parseable
    # remote (e.g. bitbucket.org) must still report its host so the hard-stop
    # message can name it. A confident remote below overrides with its own host.
    [ "$host" = "unknown" ] && host="$h"
    f="$(classify_host "$h")"
    if [ -n "$f" ]; then
      forge="$f"
      host="$h"
      break
    fi
  done

  root="$(git rev-parse --show-toplevel 2>/dev/null)"
  [ -z "$root" ] && root="."

  # Phase B.1 — CI-config, only if no remote resolved.
  if [ -z "$forge" ]; then
    local gh_ci gl_ci
    gh_ci=false; gl_ci=false
    [ -d "$root/.github" ] && gh_ci=true
    [ -f "$root/.gitlab-ci.yml" ] && gl_ci=true
    if $gh_ci && $gl_ci; then
      forge="unsupported"
    elif $gh_ci; then
      forge="github"
    elif $gl_ci; then
      forge="gitlab"
    fi
  fi

  # Phase B.2 — repo-scoped read-only CLI probe, only if still unresolved.
  if [ -z "$forge" ]; then
    local gh_ok gl_ok
    gh_ok=false; gl_ok=false
    if command -v gh >/dev/null 2>&1; then
      gh repo view >/dev/null 2>&1 && gh_ok=true
    fi
    if command -v glab >/dev/null 2>&1; then
      glab repo view >/dev/null 2>&1 && gl_ok=true
    fi
    if $gh_ok && $gl_ok; then
      forge="unsupported"
    elif $gh_ok; then
      forge="github"
    elif $gl_ok; then
      forge="gitlab"
    fi
  fi

  # Phase B.3 — nothing matched.
  [ -z "$forge" ] && forge="unsupported"

  # CLI for the RESOLVED forge, only when that CLI is installed. An irrelevant
  # installed CLI does not count. auth status runs only now, never as a signal.
  cli="none"
  cli_auth="false"
  case "$forge" in
    github)
      if command -v gh >/dev/null 2>&1; then
        cli="gh"
        gh auth status >/dev/null 2>&1 && cli_auth="true"
      fi
      ;;
    gitlab)
      if command -v glab >/dev/null 2>&1; then
        cli="glab"
        glab auth status >/dev/null 2>&1 && cli_auth="true"
      fi
      ;;
  esac

  if [ "$forge" = "github" ] || [ "$forge" = "gitlab" ]; then
    supported="true"
  else
    supported="false"
  fi

  printf 'forge=%s\n' "$forge"
  printf 'host=%s\n' "$host"
  printf 'cli=%s\n' "$cli"
  printf 'cli_authenticated=%s\n' "$cli_auth"
  printf 'supported=%s\n' "$supported"
  return 0
}

# Run main only when executed directly, not when sourced (tests source this
# file to unit-test the pure helpers without running detection).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
  exit $?
fi
