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
# Local-LLM mock-stack opt-in (fn-3) — OFF by default:
#   --local-llm                    install the opt-in local LLM mock stack. On its
#                                  own it REQUIRES --local-llm-model. When set the
#                                  engine: (a) lays down templates/_optional/local-llm/
#                                  -> the project's etc/local-llm/ (the ONLY thing
#                                  that materializes the stack — it is NOT in the
#                                  default copy), and (b) jq-mutates the GENERATED
#                                  config.json: repoints claude-api/openai-api base
#                                  URLs at the local LiteLLM gateway + sets dummy
#                                  keys, and adds localLlm.model (+ embeddingModel).
#   --local-llm-model <model>      the chosen chat model (single source of truth — no
#                                  hardcoded default). Validated against the Ollama
#                                  model-name grammar. Requires --local-llm.
#   --local-llm-embed-model <m>    the optional embedding model -> localLlm.embeddingModel.
#                                  Requires --local-llm (and a chat model). Same grammar.
# The opt-in path uses `jq` on the HOST — preflighted ONLY when --local-llm is set
# (the non-opt-in scaffold stays jq-free). A non-opt-in scaffold has ZERO etc/local-llm/
# files and no localLlm config block; base URLs stay real-provider defaults.
#
# Strix opt-in (AI pentest agent) — OFF by default:
#   --strix   lay down templates/_optional/strix/ -> the project's etc/strix/ (the
#             opt-in AI-pentest-agent doc + install marker). The Strix CLI itself is
#             installed IN THE DEV CONTAINER by .devcontainer/setup.sh, gated on the
#             presence of etc/strix/. There is NO config.json mutation (so --strix needs
#             no jq and never trips the config-drift gate), and a non-opt-in --update
#             prunes a prior opt-in's etc/strix/ files (opt-in is NOT sticky).
#
# Exit codes: 64 usage/validation error, 65 target/collision error, 0 success.

set -euo pipefail

readonly MANIFEST=".init-project-manifest.json"
readonly TOKEN_RE='__SCAFFOLD_[A-Z0-9_]+__'
# Ollama model-name grammar (R4/R12) — same as build-config's v_modelname. Rejects
# whitespace, shell metacharacters, and YAML-sensitive chars so a hostile model name
# can't corrupt config.json or the later stamped litellm config.yaml / exported LLM_MODEL.
readonly MODEL_RE='^[A-Za-z0-9._/-]+(:[A-Za-z0-9._-]+)?$'
# Local LiteLLM gateway values written into config.json on opt-in (see fn-3 spec R6).
readonly LLM_CLAUDE_BASE_URL="http://127.0.0.1:4000"      # Anthropic SDK root
readonly LLM_OPENAI_BASE_URL="http://127.0.0.1:4000/v1"   # OpenAI surface
readonly LLM_DUMMY_KEY="sk-local-mock"                    # SDKs reject empty keys
# Real-provider defaults — the non-opt-in config.json values (also the committed
# template's values). Used to RESET a previously-opted-in config on a non-opt-in
# `--update` so opt-in is NOT sticky (absent --local-llm => no stack, no localLlm,
# real-provider URLs — fn-3 R5).
readonly REAL_CLAUDE_BASE_URL="https://api.anthropic.com"
readonly REAL_OPENAI_BASE_URL="https://api.openai.com/v1"
readonly REAL_API_KEY="REPLACE_ME"

die() { echo "ERROR: $*" >&2; exit "${2:-64}"; }
usage() { echo "usage: scaffold.sh <project-name> <description> [--force|--update] [--replace-config] [--dry-run] [--strix] [--local-llm --local-llm-model <model> [--local-llm-embed-model <model>]]" >&2; exit 64; }

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

# Map a template-relative path to its scaffolded path:
#   _CLAUDE.md                      -> CLAUDE.md   (rename at stamp time)
#   _optional/local-llm/<rest>      -> etc/local-llm/<rest>   (opt-in subtree; the
#                                      `_optional/` prefix keeps it OUT of the
#                                      default wholesale copy — only --local-llm
#                                      appends these files, here remapped under etc/)
target_rel() {
  case "$1" in
    _CLAUDE.md)               echo "CLAUDE.md" ;;
    */_CLAUDE.md)             echo "${1%/_CLAUDE.md}/CLAUDE.md" ;;
    _optional/local-llm/*)    echo "etc/local-llm/${1#_optional/local-llm/}" ;;
    _optional/strix/*)        echo "etc/strix/${1#_optional/strix/}" ;;
    *)                        echo "$1" ;;
  esac
}

# True if manifest file $1 lists path $2.
manifest_has() { [[ -f "$1" ]] && grep -qF "\"path\": \"$2\"" "$1"; }

main() {
  local name="" desc="" mode="strict" replace_config=0 dry_run=0
  local local_llm=0 llm_model="" llm_embed_model="" strix=0
  local positionals=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force)          mode="force" ;;
      --update)         mode="update" ;;
      --replace-config) replace_config=1 ;;
      --dry-run)        dry_run=1 ;;
      --strix)          strix=1 ;;
      --local-llm)      local_llm=1 ;;
      --local-llm-model)
                        [[ $# -ge 2 && -n "$2" ]] || die "--local-llm-model requires a non-empty value"
                        llm_model="$2"; shift ;;
      --local-llm-model=*)
                        llm_model="${1#*=}"
                        [[ -n "$llm_model" ]] || die "--local-llm-model requires a non-empty value" ;;
      --local-llm-embed-model)
                        [[ $# -ge 2 && -n "$2" ]] || die "--local-llm-embed-model requires a non-empty value"
                        llm_embed_model="$2"; shift ;;
      --local-llm-embed-model=*)
                        llm_embed_model="${1#*=}"
                        [[ -n "$llm_embed_model" ]] || die "--local-llm-embed-model requires a non-empty value" ;;
      --*)              die "unknown flag '$1'" ;;
      *)                positionals+=("$1") ;;
    esac
    shift
  done
  [[ ${#positionals[@]} -eq 2 ]] || usage
  name="${positionals[0]}"; desc="${positionals[1]}"
  [[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "invalid project name '$name' (must match ^[a-z0-9][a-z0-9-]*\$)"

  # --- Local-LLM opt-in validation (fn-3 R4/R12) — all usage errors (exit 64) ---
  # The model flags are meaningless without the opt-in toggle; reject them up front so
  # `--local-llm-model X` (no --local-llm) can't silently no-op.
  if [[ "$local_llm" -eq 0 ]]; then
    [[ -n "$llm_model" ]]       && die "--local-llm-model requires --local-llm"
    [[ -n "$llm_embed_model" ]] && die "--local-llm-embed-model requires --local-llm"
  else
    # --local-llm REQUIRES a chat model — the model is the source of truth, there is
    # NO hardcoded default.
    [[ -n "$llm_model" ]] || die "--local-llm requires --local-llm-model <model>"
    # Validate the user-supplied model name(s) against the Ollama grammar BEFORE any
    # write — a hostile value must never reach config.json / the stamped config.yaml.
    [[ "$llm_model" =~ $MODEL_RE ]] \
      || die "invalid --local-llm-model '$llm_model' (must match $MODEL_RE)"
    [[ -z "$llm_embed_model" || "$llm_embed_model" =~ $MODEL_RE ]] \
      || die "invalid --local-llm-embed-model '$llm_embed_model' (must match $MODEL_RE)"
    # The opt-in path mutates config.json with `jq` ON THE HOST (scaffolding may run
    # outside the devcontainer, so fn-2's in-project jq guarantee doesn't apply).
    # Preflight it ONLY here — the non-opt-in scaffold needs no jq.
    command -v jq >/dev/null 2>&1 \
      || die "the --local-llm option requires \`jq\` on the host (install jq, or scaffold without --local-llm)"
  fi
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
  # PRUNE the `_optional/` subtree from the default copy: its `_`-prefix marks it as
  # opt-in (mirrors fn-2's `_`-private convention), so it must NEVER land in a default
  # scaffold. The opt-in subtree (currently only local-llm) is appended below, behind
  # its flag, remapped to its destination by target_rel.
  local files=()
  while IFS= read -r -d '' f; do f="${f#./}"; files+=("$f"); done \
    < <(cd "$templates" && find . -path './_optional' -prune -o -type f -print0)
  [[ ${#files[@]} -gt 0 ]] || die "no template files under $templates"

  # Opt-in: append the local-llm subtree so it flows through the SAME copy +
  # token-substitution + manifest + leftover-token gate as every other file. The
  # config.json jq mutation (base URLs, keys, localLlm.*) is applied in the loop.
  if [[ "$local_llm" -eq 1 ]]; then
    local llm_dir="$templates/_optional/local-llm"
    [[ -d "$llm_dir" ]] || die "templates/_optional/local-llm/ not found (cannot install --local-llm)" 65
    local lf
    while IFS= read -r -d '' lf; do lf="${lf#./}"; files+=("_optional/local-llm/$lf"); done \
      < <(cd "$llm_dir" && find . -type f -print0)
  fi

  # Opt-in: same treatment for the Strix subtree -> etc/strix/ (opt-in AI pentest
  # agent doc + install marker). Unlike --local-llm this performs NO config.json
  # mutation, so --strix needs no jq and never trips the config-drift gate; the CLI
  # itself is installed in the dev container by setup.sh, gated on etc/strix/.
  if [[ "$strix" -eq 1 ]]; then
    local sx_dir="$templates/_optional/strix"
    [[ -d "$sx_dir" ]] || die "templates/_optional/strix/ not found (cannot install --strix)" 65
    local sxf
    while IFS= read -r -d '' sxf; do sxf="${sxf#./}"; files+=("_optional/strix/$sxf"); done \
      < <(cd "$sx_dir" && find . -type f -print0)
  fi

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

  # Non-opt-in --update: capture the prior manifest's etc/local-llm/ files (from a
  # previous opt-in) so they can be removed after the rebuild — otherwise they linger
  # orphaned on disk + drop silently out of the new manifest (fn-3 R5 removability).
  # Captured BEFORE the loop rewrites the manifest. (Opt-in --update re-lays them, so
  # only the non-opt-in case prunes.)
  local prior_llm_files=()
  if [[ "$local_llm" -eq 0 && "$mode" == "update" && -f "$existing_manifest" ]] && command -v jq >/dev/null 2>&1; then
    local plf
    while IFS= read -r plf; do [[ -n "$plf" ]] && prior_llm_files+=("$plf"); done \
      < <(jq -r '.files[].path | select(startswith("etc/local-llm/"))' "$existing_manifest" 2>/dev/null)
  fi

  # Same for a prior Strix opt-in (etc/strix/): a non-opt-in --update removes the
  # orphaned files so opt-in is NOT sticky. Strix has no config block, so this file
  # prune is the ONLY reset it needs (mirrors the local-llm prune above).
  local prior_strix_files=()
  if [[ "$strix" -eq 0 && "$mode" == "update" && -f "$existing_manifest" ]] && command -v jq >/dev/null 2>&1; then
    local psf
    while IFS= read -r psf; do [[ -n "$psf" ]] && prior_strix_files+=("$psf"); done \
      < <(jq -r '.files[].path | select(startswith("etc/strix/"))' "$existing_manifest" 2>/dev/null)
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

    # Local-LLM opt-in: deterministic, bounded `jq` mutation of the GENERATED
    # config.json (NOT the committed template) — a sanctioned extension of the
    # "copy + substitute" rule, touching only named keys (fn-3 R5/R6, decision
    # context). Repoint the always-present claude-api/openai-api services at the
    # local LiteLLM gateway + set dummy keys, and add localLlm.model (+ the optional
    # embeddingModel — omitted entirely when no embed model was chosen). Runs AFTER
    # the (fresh-stamp OR update-merge) write so it applies in both modes; the model
    # name was already grammar-validated above. Applied last so it wins over any
    # merged-in real-provider values on --update opt-in.
    if [[ "$local_llm" -eq 1 && "$out" == "config.json" ]]; then
      if ! jq \
        --arg claude_url "$LLM_CLAUDE_BASE_URL" --arg openai_url "$LLM_OPENAI_BASE_URL" \
        --arg key "$LLM_DUMMY_KEY" --arg model "$llm_model" --arg embed "$llm_embed_model" '
          .services["claude-api"].base_url = $claude_url
          | .services["claude-api"].api_key = $key
          | .services["openai-api"].base_url = $openai_url
          | .services["openai-api"].api_key = $key
          | .localLlm = ({ model: $model } + (if $embed == "" then {} else { embeddingModel: $embed } end))
        ' "$dst" > "$dst.tmp"; then
        rm -f "$dst.tmp"
        die "failed to apply --local-llm config.json mutation (jq error)" 65
      fi
      mv "$dst.tmp" "$dst"
    fi

    # Non-opt-in --update RESET (opt-in is NOT sticky — fn-3 R5): a PRIOR opted-in
    # config.json carries repointed base URLs + sk-local-mock keys + a localLlm block;
    # the "existing wins" merge would silently preserve them. So when --update runs
    # WITHOUT --local-llm OVER A PRIOR OPT-IN, reset the local-LLM-managed keys back to
    # real-provider defaults and DROP localLlm — restoring the documented non-opt-in
    # contract. Only the named local-LLM keys are touched; operator edits + secrets the
    # merge kept are untouched. (Orphaned etc/local-llm/ files are removed after the loop.)
    #
    # CRITICALLY gated on prior-opt-in EVIDENCE (the prior manifest listing
    # etc/local-llm/ files — only the opt-in path ever writes those). A project that
    # was NEVER opted in (real-provider URLs + operator-customized api_key) must NOT be
    # reset: a plain --update preserves its config per the existing "existing wins"
    # contract. `prior_llm_files` is populated pre-loop only in this exact case.
    if [[ "$local_llm" -eq 0 && "$mode" == "update" && "$out" == "config.json" && ${#prior_llm_files[@]} -gt 0 ]]; then
      if ! jq \
        --arg claude_url "$REAL_CLAUDE_BASE_URL" --arg openai_url "$REAL_OPENAI_BASE_URL" \
        --arg key "$REAL_API_KEY" '
          .services["claude-api"].base_url = $claude_url
          | .services["claude-api"].api_key = $key
          | .services["openai-api"].base_url = $openai_url
          | .services["openai-api"].api_key = $key
          | del(.localLlm)
        ' "$dst" > "$dst.tmp"; then
        rm -f "$dst.tmp"
        die "failed to reset local-LLM config.json on non-opt-in --update (jq error)" 65
      fi
      mv "$dst.tmp" "$dst"
    fi

    hash="$(shasum -a 256 "$dst" | cut -d' ' -f1)"
    manifest_lines+=("    {\"path\": \"$out\", \"sha256\": \"$hash\"}")
  done

  # Ownership manifest (normalized relative paths — no ../absolute).
  { echo "{"; echo "  \"generated_by\": \"init-project/scaffold.sh\","; echo "  \"files\": ["
    local n=${#manifest_lines[@]} j
    for ((j=0; j<n; j++)); do printf '%s' "${manifest_lines[$j]}"; [[ $j -lt $((n-1)) ]] && echo "," || echo ""; done
    echo "  ]"; echo "}"; } > "$existing_manifest"

  # Non-opt-in --update: remove the prior opt-in's now-orphaned etc/local-llm/ files
  # (captured pre-loop), then prune emptied dirs. Only manifest-owned local-LLM paths
  # are touched (never operator files). The new manifest already omits them.
  if [[ ${#prior_llm_files[@]} -gt 0 ]]; then
    local of
    for of in "${prior_llm_files[@]}"; do rm -f "$target/$of"; done
    # Remove the etc/local-llm/ tree if it's now empty (rmdir -p ignores non-empty).
    [[ -d "$target/etc/local-llm" ]] && find "$target/etc/local-llm" -type d -empty -delete 2>/dev/null || true
  fi

  # Same prune for a prior Strix opt-in's now-orphaned etc/strix/ files.
  if [[ ${#prior_strix_files[@]} -gt 0 ]]; then
    local sof
    for sof in "${prior_strix_files[@]}"; do rm -f "$target/$sof"; done
    [[ -d "$target/etc/strix" ]] && find "$target/etc/strix" -type d -empty -delete 2>/dev/null || true
  fi

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
