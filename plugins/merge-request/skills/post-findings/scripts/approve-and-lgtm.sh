#!/usr/bin/env bash
#
# approve-and-lgtm.sh — formally sign off a CLEAN pull/merge request: cast a real
# approval and post a note that is exactly `Looks good.` — nothing else, ever.
# The deterministic clean-path half of /merge-request:post-findings.
#
# A formal approval is high-impact, so this script enforces the clean condition
# ITSELF against the staged artifact (../../ARTIFACT.md), independent of the
# assistant's own check — belt and suspenders. It approves ONLY when BOTH hold:
#
#   1. the review's explicit machine marker `<!-- merge-review-status: clean -->`
#      is present in the artifact header, AND
#   2. the `## Findings` section is PRESENT and has ZERO finding records.
#
# The marker and the section must agree (ARTIFACT.md). Any of: a missing marker,
# a missing/absent `## Findings` heading (malformed / truncated artifact), or one
# or more staged findings → REFUSE (exit 1, approve nothing, post nothing). A
# session where the user skipped every finding is NOT clean: the artifact still
# carries findings + the `findings` marker, so this guard refuses it. Approval is
# never a side effect of "nothing got posted".
#
# The note is exactly `Looks good.` The --message override exists ONLY for tests;
# production callers pass nothing and get the canonical wording.
#
# Usage:
#   approve-and-lgtm.sh --forge <github|gitlab> --id <ID> --artifact <path> \
#                       [--message <text>]     # default: "Looks good."
#
# Machine-readable stdout:
#   APPROVED=1
#   NOTE=<the exact note posted>
#
# Exit codes:
#   0  approved and the note posted.
#   2  usage / bad arguments (nothing was changed).
#   1  NOT clean (guard refused), or an operational failure (missing CLI, forge
#      rejected the approval/note). In every non-zero case NOTHING is approved
#      and NOTHING is posted.
#
# Env:
#   GITLAB_REPO=group/project   Set when glab can't infer the project from the remote.
#
# Requires: gh (github) or glab (gitlab).
#
# NOTE: strictly `set -uo pipefail` (no `-e`) — failures handled explicitly via die.

set -uo pipefail

PROG="merge-request:post-findings/approve-and-lgtm"

die()  { printf '%s: %s\n' "$PROG" "$*" >&2; exit "${2:-1}"; }

# --- argument parsing ------------------------------------------------------

forge=""
id=""
artifact=""
message="Looks good."

while [ $# -gt 0 ]; do
  case "$1" in
    --forge)    forge="${2:-}"; shift 2 || die "usage: --forge needs a value" 2 ;;
    --id)       id="${2:-}"; shift 2 || die "usage: --id needs a value" 2 ;;
    --artifact) artifact="${2:-}"; shift 2 || die "usage: --artifact needs a value" 2 ;;
    --message)  message="${2-}"; shift 2 || die "usage: --message needs a value" 2 ;;
    -h|--help)  grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'; exit 0 ;;
    *) die "unknown argument: $1" 2 ;;
  esac
done

case "$forge" in
  github|gitlab) : ;;
  "") die "--forge is required (github|gitlab)" 2 ;;
  *)  die "unsupported forge '$forge' — only github and gitlab" 2 ;;
esac
[ -n "$id" ] || die "--id is required" 2
case "$id" in ''|*[!0-9]*) die "--id must be a numeric PR/MR id (got '$id')" 2 ;; esac
[ -n "$artifact" ] || die "--artifact is required (the staged .data/merge/<ID>.md)" 2
[ -f "$artifact" ] || die "artifact '$artifact' does not exist — refusing to approve without proof of a clean review" 1
[ -n "$message" ] || die "--message must not be empty" 2

# --- clean guard: BOTH the clean marker AND a zero-entry ## Findings --------

if ! grep -qE '<!--[[:space:]]*merge-review-status:[[:space:]]*clean[[:space:]]*-->' "$artifact"; then
  die "artifact has no '<!-- merge-review-status: clean -->' marker — NOT clean; refusing to approve" 1
fi

if ! grep -qE '^## Findings[[:space:]]*$' "$artifact"; then
  die "artifact has no '## Findings' section — malformed; refusing to approve" 1
fi

# Count finding records inside the ## Findings section (a record is a JSON line
# carrying a stable F-<hash> id). `next` on `## ` lines keeps the heading itself
# out of the count and flips the in-section flag on section boundaries.
finding_count="$(awk '
  /^## / { inF = ($0 ~ /^## Findings[[:space:]]*$/) ? 1 : 0; next }
  inF && /"id"[[:space:]]*:[[:space:]]*"F-/ { c++ }
  END { print c+0 }
' "$artifact")"

if [ "${finding_count:-0}" -ne 0 ]; then
  die "artifact has ${finding_count} staged finding(s) — NOT clean; refusing to approve (post the findings instead)" 1
fi

# --- approve + post the exact note -----------------------------------------

if [ "$forge" = "github" ]; then
  command -v gh >/dev/null 2>&1 || die "gh is required for a github forge but not installed"
  if ! err="$(gh pr review "$id" --approve 2>&1 >/dev/null)"; then
    die "failed to approve PR $id: $err (already approved, or your role can't approve it?)" 1
  fi
  if ! err="$(gh pr comment "$id" --body "$message" 2>&1 >/dev/null)"; then
    die "approved PR $id, but failed to post the \"$message\" comment: $err" 1
  fi
else
  command -v glab >/dev/null 2>&1 || die "glab is required for a gitlab forge but not installed"
  if [ -n "${GITLAB_REPO:-}" ]; then proj="${GITLAB_REPO//\//%2F}"; else proj=":id"; fi
  if ! err="$(glab mr approve "$id" 2>&1 >/dev/null)"; then
    die "failed to approve MR $id: $err (already approved, or your role can't approve it?)" 1
  fi
  if ! err="$(glab api "projects/$proj/merge_requests/$id/notes" --method POST -f "body=$message" 2>&1 >/dev/null)"; then
    die "approved MR $id, but failed to post the \"$message\" note: $err" 1
  fi
fi

printf 'APPROVED=1\n'
printf 'NOTE=%s\n' "$message"
