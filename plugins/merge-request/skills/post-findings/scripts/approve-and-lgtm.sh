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
# The note is exactly `Looks good.` — hardcoded, NOT overridable. Since every
# approval write goes through this one script, the exact wording is an invariant
# enforced here, not a convention callers must remember.
#
# Failure-safety (no approval ever lands without its note):
#   * GitHub — approval and note are ONE atomic call: `gh pr review --approve
#     --body "Looks good."`. The note IS the approving review's body, so there is
#     no window where the PR is approved but the note is missing.
#   * GitLab — approval and the note are two separate API calls (glab has no
#     atomic form). We post the note FIRST, then approve. So a failure can at
#     worst leave a stray `Looks good.` note on an already-clean MR (harmless and
#     accurate) — it can NEVER leave a formal approval without the note.
#
# Usage:
#   approve-and-lgtm.sh --forge <github|gitlab> --id <ID> --artifact <path>
#
# Machine-readable stdout:
#   APPROVED=1
#   NOTE=Looks good.
#
# Exit codes:
#   0  approved and the note posted.
#   2  usage / bad arguments (nothing was changed).
#   1  NOT clean (guard refused), or an operational failure (missing CLI, forge
#      rejected the approval/note). On any failure the MR/PR is NOT left formally
#      approved (GitHub: atomic; GitLab: note precedes approval).
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
# The clean-path note wording is an invariant, not a caller choice.
readonly MESSAGE="Looks good."

while [ $# -gt 0 ]; do
  case "$1" in
    --forge)    forge="${2:-}"; shift 2 || die "usage: --forge needs a value" 2 ;;
    --id)       id="${2:-}"; shift 2 || die "usage: --id needs a value" 2 ;;
    --artifact) artifact="${2:-}"; shift 2 || die "usage: --artifact needs a value" 2 ;;
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

# --- clean guard: BOTH the clean marker AND a zero-entry ## Findings --------

if ! grep -qE '<!--[[:space:]]*merge-review-status:[[:space:]]*clean[[:space:]]*-->' "$artifact"; then
  die "artifact has no '<!-- merge-review-status: clean -->' marker — NOT clean; refusing to approve" 1
fi

if ! grep -qE '^## Findings[[:space:]]*$' "$artifact"; then
  die "artifact has no '## Findings' section — malformed; refusing to approve" 1
fi

# Count "records" inside the ## Findings section. "Zero entries" means the
# section carries NO record content — so the count is fence-aware and strict:
#   * inside the fenced ```jsonl block, ANY non-blank line is a record (a
#     well-formed `F-` record, a malformed `not-json` line, or a truncated
#     fragment) — the spec: a malformed artifact is NOT clean;
#   * outside a fence, any line opening a JSON object (`{...`) counts too.
# A clean section is empty, prose-only ("(none)"), or an EMPTY fenced block.
# `next` on `## ` lines keeps the heading out of the count and flips the
# in-section flag; the ``` fence markers toggle the fence and never count.
finding_count="$(awk '
  /^## / { inF = ($0 ~ /^## Findings[[:space:]]*$/) ? 1 : 0; next }
  {
    if (!inF) next
    if ($0 ~ /^[[:space:]]*```/) { fence = !fence; next }
    if (fence) { if ($0 ~ /[^[:space:]]/) c++ }
    else if ($0 ~ /^[[:space:]]*\{/) c++
  }
  END { print c+0 }
' "$artifact")"

if [ "${finding_count:-0}" -ne 0 ]; then
  die "artifact has ${finding_count} record line(s) in ## Findings — NOT clean; refusing to approve (post/triage them instead)" 1
fi

# --- approve + post the exact note -----------------------------------------

if [ "$forge" = "github" ]; then
  command -v gh >/dev/null 2>&1 || die "gh is required for a github forge but not installed"
  # Atomic: the approving review CARRIES the note as its body, so approval and
  # `Looks good.` land together or not at all — no partial state.
  if ! err="$(gh pr review "$id" --approve --body "$MESSAGE" 2>&1 >/dev/null)"; then
    die "failed to approve PR $id: $err (already approved, or your role can't approve it?)" 1
  fi
else
  command -v glab >/dev/null 2>&1 || die "glab is required for a gitlab forge but not installed"
  if [ -n "${GITLAB_REPO:-}" ]; then proj="${GITLAB_REPO//\//%2F}"; else proj=":id"; fi
  # glab has no atomic approve+note, so post the note FIRST: a failure here means
  # the MR is NOT approved. Only after the note lands do we cast the approval, so
  # an approval can never exist without its note (at worst a stray note remains).
  if ! err="$(glab api "projects/$proj/merge_requests/$id/notes" --method POST -f "body=$MESSAGE" 2>&1 >/dev/null)"; then
    die "failed to post the \"$MESSAGE\" note on MR $id: $err — MR was NOT approved" 1
  fi
  if ! err="$(glab mr approve "$id" 2>&1 >/dev/null)"; then
    die "posted the \"$MESSAGE\" note but FAILED to approve MR $id: $err (already approved, or your role can't approve it?)" 1
  fi
fi

printf 'APPROVED=1\n'
printf 'NOTE=%s\n' "$MESSAGE"
