#!/usr/bin/env bash
#
# publish-nuget.sh — cut a ParleyAI NuGet release.
#
# The release path in .github/workflows/nuget.yml runs ONLY on a `nuget-v*` tag
# push, and its `pack` job HARD-ASSERTS that the tag version equals the
# `<LlmWrapperVersion>` pin in:
#
#     plugins/init-project/templates/Directory.Build.props
#
# So a release is two things that MUST agree: the pin and the tag. This script
# keeps them in lockstep — it makes the pin equal the target version, commits
# that (only if it changed), and tags the SAME version (`nuget-v<version>`),
# then pushes both. The tag therefore equals the pin BY CONSTRUCTION; CI's
# assertion can never fail because of this script. It reads the pin using the
# SAME extraction the workflow uses, so what this script sees is exactly what
# CI will assert against.
#
# VERSION SELECTION (the "auto-increment" rule):
#   Two constraints drive it — (1) tag == pin at the tagged commit [CI rule],
#   and (2) a version can't be published to nuget.org twice [nuget.org rule].
#   With no version argument the script:
#     * releases the CURRENT pin as-is if `nuget-v<pin>` was never tagged
#       (so the FIRST release ships the configured pin, e.g. 0.1.0 — not 0.1.1);
#     * otherwise the pin is already spent, so it auto-increments the PATCH
#       (0.1.0 -> 0.1.1 -> 0.1.2 ...) and releases that.
#   Pass patch|minor|major to force a bump from the pin, or X.Y.Z to set an
#   exact version. Either way the pin is rewritten to match before tagging.
#
# Pushing the tag triggers, in order:
#   pack -> (publish-oidc XOR publish-apikey) -> verify-package-restorable
#        -> verify-scaffold-restore
# i.e. it PUBLISHES ParleyAI <version> to nuget.org for real (effectively
# irreversible — you can unlist, not delete). This script confirms before the
# push unless --yes is given.
#
# Usage:
#   ./publish-nuget.sh                 # auto: release current pin, else PATCH-bump
#   ./publish-nuget.sh patch           # force PATCH bump from pin (0.1.0 -> 0.1.1)
#   ./publish-nuget.sh minor           # force MINOR bump        (0.1.0 -> 0.2.0)
#   ./publish-nuget.sh major           # force MAJOR bump        (0.1.0 -> 1.0.0)
#   ./publish-nuget.sh 1.4.2           # set an EXACT version
#
# Flags (any position):
#   --dry-run        Show what would happen; change nothing, push nothing.
#   --yes, -y        Skip the confirmation prompt before the (publishing) push.
#   --no-push        Commit the bump + create the tag locally, but do not push.
#   --allow-branch   Permit running on a branch other than main (default: refuse).
#   -h, --help       Show this help and exit.
#
set -euo pipefail

PROPS_REL="plugins/init-project/templates/Directory.Build.props"
RELEASE_BRANCH="main"

die()  { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }
note() { printf '\033[36m%s\033[0m\n' "$*" >&2; }
warn() { printf '\033[33mWarning:\033[0m %s\n' "$*" >&2; }

usage() { awk 'NR==1{next} /^set -euo pipefail/{exit} /^#/{sub(/^# ?/,""); print}' "$0"; }

read_pin() {  # extract <LlmWrapperVersion> from $1 — IDENTICAL logic to nuget.yml's pack job
  sed -n 's@.*<LlmWrapperVersion>[[:space:]]*\(.*\)[[:space:]]*</LlmWrapperVersion>.*@\1@p' "$1" | head -n1 | tr -d '[:space:]'
}

tag_exists() {  # true if tag $1 exists locally OR on origin (a released version)
  git rev-parse -q --verify "refs/tags/$1" >/dev/null 2>&1 && return 0
  git ls-remote --exit-code --tags origin "$1" >/dev/null 2>&1
}

# ---- parse args ------------------------------------------------------------
BUMP="auto"           # auto | patch | minor | major | explicit
EXPLICIT=""
DRY_RUN=0
ASSUME_YES=0
NO_PUSH=0
ALLOW_BRANCH=0

for arg in "$@"; do
  case "$arg" in
    --dry-run)      DRY_RUN=1 ;;
    --yes|-y)       ASSUME_YES=1 ;;
    --no-push)      NO_PUSH=1 ;;
    --allow-branch) ALLOW_BRANCH=1 ;;
    -h|--help)      usage; exit 0 ;;
    patch|minor|major) BUMP="$arg" ;;
    [0-9]*.[0-9]*.[0-9]*) BUMP="explicit"; EXPLICIT="$arg" ;;
    -*) die "unknown flag: $arg (try --help)" ;;
    *)  die "unrecognized argument: $arg (expected patch|minor|major|X.Y.Z, try --help)" ;;
  esac
done

# ---- locate repo + sanity checks -------------------------------------------
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
cd "$REPO_ROOT"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$BRANCH" != "$RELEASE_BRANCH" ] && [ "$ALLOW_BRANCH" -eq 0 ]; then
  die "on branch '$BRANCH', not '$RELEASE_BRANCH'. Releases are cut from $RELEASE_BRANCH. Use --allow-branch to override."
fi

if [ -n "$(git status --porcelain)" ]; then
  die "working tree is dirty. Commit or stash changes before releasing (the bump must be a clean, isolated commit)."
fi

PROPS="$REPO_ROOT/$PROPS_REL"
[ -f "$PROPS" ] || die "$PROPS_REL not found. Run this AFTER the ParleyAI PR is merged to $RELEASE_BRANCH — the version pin lives in that PR."

# Best-effort: warn if no publish auth is configured (CI will otherwise fail at publish).
if command -v gh >/dev/null 2>&1; then
  TP="$(gh variable list 2>/dev/null | grep -c '^NUGET_TRUSTED_PUBLISHING' || true)"
  KEY="$(gh secret  list 2>/dev/null | grep -c '^NUGET_API_KEY' || true)"
  if [ "${TP:-0}" -eq 0 ] && [ "${KEY:-0}" -eq 0 ]; then
    warn "Neither repo variable NUGET_TRUSTED_PUBLISHING nor secret NUGET_API_KEY is set —"
    warn "the publish job will FAIL. Configure one before pushing the tag (see README.md release section)."
  fi
fi

# ---- read the current pin (SAME extraction as nuget.yml's pack job) --------
CURRENT="$(read_pin "$PROPS")"
[ -n "$CURRENT" ] || die "could not read <LlmWrapperVersion> from $PROPS_REL"
case "$CURRENT" in
  [0-9]*.[0-9]*.[0-9]*) : ;;
  *) die "current pin '$CURRENT' is not a SemVer X.Y.Z — refusing to guess the next version." ;;
esac

# ---- compute the target version --------------------------------------------
case "$BUMP" in
  explicit) NEXT="$EXPLICIT"; LABEL="explicit" ;;
  patch|minor|major)
    IFS='.' read -r MA MI PA <<EOF
$CURRENT
EOF
    PA="${PA%%[-+]*}"   # strip any pre-release/build suffix before incrementing
    case "$BUMP" in
      major) MA=$((MA + 1)); MI=0; PA=0 ;;
      minor) MI=$((MI + 1)); PA=0 ;;
      patch) PA=$((PA + 1)) ;;
    esac
    NEXT="${MA}.${MI}.${PA}"; LABEL="$BUMP bump"
    ;;
  auto)
    if tag_exists "nuget-v${CURRENT}"; then
      # Pin already released — step the patch automatically.
      IFS='.' read -r MA MI PA <<EOF
$CURRENT
EOF
      PA="${PA%%[-+]*}"
      NEXT="${MA}.${MI}.$((PA + 1))"; LABEL="auto patch bump (pin already released)"
    else
      # First release of this pin — ship it as-is.
      NEXT="$CURRENT"; LABEL="release current pin (first release of $CURRENT)"
    fi
    ;;
esac

case "$NEXT" in
  [0-9]*.[0-9]*.[0-9]*) : ;;
  *) die "computed version '$NEXT' is not a SemVer X.Y.Z." ;;
esac

TAG="nuget-v${NEXT}"

# Refuse to clobber an already-released version.
if tag_exists "$TAG"; then
  die "tag $TAG already exists (local or origin) — that version was already released. Choose a higher version: patch|minor|major or an explicit X.Y.Z."
fi

# ---- plan ------------------------------------------------------------------
note "Release plan:"
note "  pin file : $PROPS_REL"
note "  version  : $CURRENT  ->  $NEXT   ($LABEL)"
note "  tag      : $TAG"
note "  branch   : $BRANCH"
note "  push     : $([ "$NO_PUSH" -eq 1 ] && echo 'NO (--no-push)' || echo "yes -> origin")"
note ""
note "Pushing the tag triggers nuget.yml: pack -> publish -> verify-package-restorable -> verify-scaffold-restore"
note "=> this PUBLISHES ParleyAI $NEXT to nuget.org (effectively irreversible)."

if [ "$DRY_RUN" -eq 1 ]; then
  note ""
  note "--dry-run: no files changed, nothing committed or pushed."
  exit 0
fi

if [ "$NO_PUSH" -eq 0 ] && [ "$ASSUME_YES" -eq 0 ]; then
  printf '\nProceed with the release and publish to nuget.org? [y/N] ' >&2
  read -r REPLY
  case "$REPLY" in y|Y|yes|YES) ;; *) die "aborted by user." ;; esac
fi

# ---- make the pin match the target (commit only if it changed) -------------
COMMITTED=0
if [ "$NEXT" != "$CURRENT" ]; then
  # Replace ONLY the value inside the element, preserving indentation/format.
  TMP="$(mktemp)"
  sed "s@\(<LlmWrapperVersion>[[:space:]]*\).*\([[:space:]]*</LlmWrapperVersion>\)@\1${NEXT}\2@" "$PROPS" > "$TMP"
  mv "$TMP" "$PROPS"
  VERIFY="$(read_pin "$PROPS")"
  [ "$VERIFY" = "$NEXT" ] || die "pin rewrite failed (read back '$VERIFY', expected '$NEXT'). Aborting before commit."
  git add "$PROPS_REL"
  git commit -m "chore(release): bump ParleyAI pin to ${NEXT} for ${TAG}" >/dev/null
  COMMITTED=1
  note "Bumped pin ${CURRENT} -> ${NEXT} and committed."
else
  note "Pin already at ${NEXT}; tagging current HEAD (no bump commit needed)."
fi

git tag -a "$TAG" -m "ParleyAI ${NEXT}"
note "Created tag $TAG."

# ---- push ------------------------------------------------------------------
if [ "$NO_PUSH" -eq 1 ]; then
  note "--no-push: leaving the commit + tag local."
  note "When ready:  $([ "$COMMITTED" -eq 1 ] && echo "git push origin $BRANCH && ")git push origin $TAG"
  exit 0
fi

[ "$COMMITTED" -eq 1 ] && git push origin "$BRANCH"
git push origin "$TAG"
note "Pushed${COMMITTED:+ $BRANCH and} $TAG."

if command -v gh >/dev/null 2>&1; then
  RUN_ID="$(gh run list --workflow=NuGet -L1 --json databaseId -q '.[0].databaseId' 2>/dev/null || true)"
  [ -n "$RUN_ID" ] && note "Watch the release run:  gh run watch --exit-status $RUN_ID"
else
  note "Watch the run in the repo's Actions tab (workflow: NuGet)."
fi
