#!/usr/bin/env bash
# Description: Copy the init-project templates into ./<name>/ and substitute scaffold tokens.
#
# The init-project scaffold engine. It is DETERMINISTIC: it copies the
# pre-authored templates/ tree verbatim and applies only:
#   - __SCAFFOLD_PROJECT_NAME__         -> the project name
#   - __SCAFFOLD_PROJECT_DESCRIPTION__  -> the project description
#   - __SCAFFOLD_GEN_URLSAFE__          -> a FRESH URL-safe secret PER OCCURRENCE
#   - _CLAUDE.md                        -> CLAUDE.md   (file rename at stamp time)
# It never authors or generates prose content. After stamping it fails if any
# __SCAFFOLD_*__ token remains (the leftover-token gate). Files WITHOUT tokens
# are copied byte-verbatim (safe for future binary assets); tokenized text
# files are byte-preserving-substituted (trailing newlines retained).
#
# Modes (refuse-by-default on a non-empty target):
#   --force            first-time scaffold into a non-empty dir; proceeds only
#                      when no template path collides with an existing UNMANAGED
#                      file (a file not listed in the manifest).
#   --update           re-scaffold over a prior init-project output; per planned
#                      path: overwrite only if manifest-owned, create if absent,
#                      REFUSE if an existing path is unmanaged. config.json is
#                      structured-merged (existing secrets/edits retained).
#   --replace-config   with --update, overwrite config.json wholesale (rotate).
#   --dry-run          print the planned tree; write nothing.
#
# Exit codes: 64 usage/validation error, 65 target/collision error, 0 success.

set -euo pipefail

readonly MANIFEST=".init-project-manifest.json"
readonly TOKEN_RE='__SCAFFOLD_[A-Z0-9_]+__'

die() { echo "ERROR: $*" >&2; exit "${2:-64}"; }
usage() { echo "usage: scaffold.sh <project-name> <description> [--force|--update] [--replace-config] [--dry-run]" >&2; exit 64; }

# Generate a URL-safe secret matching [A-Za-z0-9_-]+ (no =, /, +).
gen_urlsafe() { openssl rand -base64 32 | tr -d '=\n' | tr '/+' '_-'; }

# Stamp a template file to stdout, byte-preserving. Substitutes name/description
# via bash parameter expansion (NOT sed — no injection from the description),
# and replaces each __SCAFFOLD_GEN_URLSAFE__ occurrence with an INDEPENDENT value.
stamp_file() {
  local path="$1" name="$2" desc="$3" c
  c="$(cat "$path"; printf 'X')"; c="${c%X}"   # protect trailing newlines from $() stripping
  c="${c//__SCAFFOLD_PROJECT_NAME__/$name}"
  c="${c//__SCAFFOLD_PROJECT_DESCRIPTION__/$desc}"
  while [[ "$c" == *"__SCAFFOLD_GEN_URLSAFE__"* ]]; do
    c="${c/__SCAFFOLD_GEN_URLSAFE__/$(gen_urlsafe)}"   # single-slash = first match -> distinct per occurrence
  done
  printf '%s' "$c"
}

# Map a template-relative path to its scaffolded path (_CLAUDE.md -> CLAUDE.md).
target_rel() {
  case "$1" in
    _CLAUDE.md)   echo "CLAUDE.md" ;;
    */_CLAUDE.md) echo "${1%/_CLAUDE.md}/CLAUDE.md" ;;
    *)            echo "$1" ;;
  esac
}

# True if manifest file $1 lists path $2.
manifest_has() { [[ -f "$1" ]] && grep -qF "\"path\": \"$2\"" "$1"; }

main() {
  local name="" desc="" mode="strict" replace_config=0 dry_run=0
  local positionals=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force)          mode="force" ;;
      --update)         mode="update" ;;
      --replace-config) replace_config=1 ;;
      --dry-run)        dry_run=1 ;;
      --*)              die "unknown flag '$1'" ;;
      *)                positionals+=("$1") ;;
    esac
    shift
  done
  [[ ${#positionals[@]} -eq 2 ]] || usage
  name="${positionals[0]}"; desc="${positionals[1]}"
  [[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "invalid project name '$name' (must match ^[a-z0-9][a-z0-9-]*\$)"
  # User input must never be interpreted as scaffold control tokens (name regex
  # already excludes them; the description is free-form so check it explicitly).
  [[ "$desc" == *"__SCAFFOLD_"* ]] && die "description must not contain reserved __SCAFFOLD_*__ tokens" 64

  local script_dir templates target existing_manifest
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  templates="$script_dir/templates"
  target="./$name"
  existing_manifest="$target/$MANIFEST"
  [[ -d "$templates" ]] || die "templates dir not found at $templates"

  # Enumerate template files (relative; strip leading ./ in bash — macOS sed lacks -z).
  local files=()
  while IFS= read -r -d '' f; do f="${f#./}"; files+=("$f"); done \
    < <(cd "$templates" && find . -type f -print0)
  [[ ${#files[@]} -gt 0 ]] || die "no template files under $templates"

  # Planned target paths.
  local planned=() rel
  for rel in "${files[@]}"; do planned+=("$(target_rel "$rel")"); done

  # Target-state gate.
  if [[ -e "$target" && -n "$(ls -A "$target" 2>/dev/null)" ]]; then
    case "$mode" in
      strict) die "target '$target' is non-empty; pass --force (first scaffold) or --update" 65 ;;
      force)
        # --force is ONLY for a first scaffold into a non-empty dir. A target that
        # already has a manifest is a prior init-project output -> require --update
        # (so config.json secrets are never rotated by a stray --force).
        [[ -f "$existing_manifest" ]] && die "'$target' already has $MANIFEST (prior scaffold) — use --update, not --force" 65
        local p
        for p in "${planned[@]}"; do
          [[ -e "$target/$p" ]] && die "--force refused: '$p' already exists (unmanaged)" 65
        done ;;
      update)
        [[ -f "$existing_manifest" ]] || die "--update needs a prior $MANIFEST in '$target'" 65 ;;
    esac
  fi

  # --update requires a prior init-project output (manifest) — even if the target
  # is missing/empty. Otherwise --update would silently behave like a fresh scaffold.
  [[ "$mode" != "update" || -f "$existing_manifest" ]] \
    || die "--update requires a prior $MANIFEST in '$target' (no prior init-project output)" 65

  if [[ "$dry_run" -eq 1 ]]; then
    echo "Would scaffold '$name' into $target/:"
    printf '  %s\n' "${planned[@]}" | sort
    return 0
  fi

  mkdir -p "$target"
  local manifest_lines=()
  local i out dst hash stamped
  for i in "${!files[@]}"; do
    rel="${files[$i]}"; out="${planned[$i]}"; dst="$target/$out"

    # --update per-file ownership gate: never overwrite an unmanaged existing file.
    if [[ "$mode" == "update" && -e "$dst" ]] && ! manifest_has "$existing_manifest" "$out"; then
      die "--update refused: '$out' exists and is not manifest-owned" 65
    fi

    mkdir -p "$(dirname "$dst")"
    if [[ "$out" == "config.json" && "$mode" == "update" && "$replace_config" -eq 0 && -f "$dst" ]]; then
      # Structured merge (existing values win — retain secrets + operator edits;
      # template adds NEW non-secret keys + NEW systems[] entries). systems[] is
      # merged BY NAME (jq '*' would otherwise replace the array wholesale and drop
      # new template systems/fields): index both by .name, deep-merge with the
      # stamped template as base + existing overlaid on top, rebuild the array.
      stamped="$(mktemp)"
      stamp_file "$templates/$rel" "$name" "$desc" > "$stamped"
      # Explicit failure branch — `jq ... && mv` would be set -e-exempt (jq isn't the
      # final command of the && list), silently leaving the old file + reporting success.
      if ! jq -s '
        .[0] as $t | .[1] as $e
        | ($t * $e)
        | .systems = [ ( ($t.systems // [] | INDEX(.name)) * ($e.systems // [] | INDEX(.name)) )[] ]
      ' "$stamped" "$dst" > "$dst.tmp"; then
        rm -f "$dst.tmp" "$stamped"
        die "failed to merge config.json (invalid existing config or jq error)" 65
      fi
      mv "$dst.tmp" "$dst"
      rm -f "$stamped"
    elif grep -qE "$TOKEN_RE" "$templates/$rel"; then
      stamp_file "$templates/$rel" "$name" "$desc" > "$dst"
    else
      cp "$templates/$rel" "$dst"   # byte-verbatim (no tokens)
    fi
    hash="$(shasum -a 256 "$dst" | cut -d' ' -f1)"
    manifest_lines+=("    {\"path\": \"$out\", \"sha256\": \"$hash\"}")
  done

  # Ownership manifest (normalized relative paths — no ../absolute).
  { echo "{"; echo "  \"generated_by\": \"init-project/scaffold.sh\","; echo "  \"files\": ["
    local n=${#manifest_lines[@]} j
    for ((j=0; j<n; j++)); do printf '%s' "${manifest_lines[$j]}"; [[ $j -lt $((n-1)) ]] && echo "," || echo ""; done
    echo "  ]"; echo "}"; } > "$existing_manifest"

  # Leftover-token gate — scan ONLY the scaffold-managed outputs (not unmanaged
  # pre-existing files a --force target may legitimately contain).
  local p3
  for p3 in "${planned[@]}"; do
    if [[ -f "$target/$p3" ]] && grep -Eq "$TOKEN_RE" "$target/$p3"; then
      die "leftover scaffold token ($TOKEN_RE) in $p3" 64
    fi
  done

  echo "Scaffolded '$name' into $target/ (${#planned[@]} files)."
}

# Source-guard so tests can source this file (and call gen_urlsafe/stamp_file/
# target_rel/manifest_has) without executing main.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
