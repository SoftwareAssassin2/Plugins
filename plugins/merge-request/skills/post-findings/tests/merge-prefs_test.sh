#!/usr/bin/env bash
#
# merge-prefs_test.sh — tests for merge-prefs.sh, the deterministic half of
# /merge-request:post-findings's learned-preferences loop.
#
# Run: bash plugins/merge-request/skills/post-findings/tests/merge-prefs_test.sh
#
# No forge, no network — this script only touches local preference files and the
# staged `.data/merge/<ID>.md` artifact. Every fixture is a temp file; nothing
# outside $ROOT_TMP is read or written.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MP="$SCRIPT_DIR/../scripts/merge-prefs.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL - $1  (got: ${2:-})"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

ROOT_TMP="$(mktemp -d)"
trap 'rm -rf "$ROOT_TMP"' EXIT

# run <script args...>   → RC set, OUT captures stdout, ERR captures stderr.
# OUT/ERR are consumed inside the deferred `check` eval strings, which shellcheck
# cannot see through — hence the disable.
run() {
  # shellcheck disable=SC2034
  OUT="$( "$@" 2>"$ROOT_TMP/err" )"; RC=$?
  # shellcheck disable=SC2034
  ERR="$(cat "$ROOT_TMP/err")"
}

# A prefs file with one entry per keyed section.
mk_prefs() {  # <file> <dont-raise-line> <wording-line>
  cat > "$1" <<EOF
# Merge-request review — learned preferences

Intro prose that must be preserved.

## Don't raise

$2

## Wording

$3

## Confirmed valued

## Rubric weighting

- \`allow-large-diffs\` — user-set weighting, never inferred
EOF
}

# ===========================================================================
# merge — keyed merge model
# ===========================================================================
echo "== merge (keyed model) =="

GLOBAL="$ROOT_TMP/global.md"
PROJECT="$ROOT_TMP/project.md"

# Global: two Don't-raise (A,B) + one Wording (W1).
mk_prefs "$GLOBAL" \
  "- \`style/a\` (count: 3) — global A
- \`style/b\` (count: 1) — global B" \
  "- \`w1\` — global wording one"

# Project: same-key A (REPLACES global A, higher count) + new-key C (UNION);
#          Wording W1 same key (REPLACES) — leaves B and any unlisted alone.
mk_prefs "$PROJECT" \
  "- \`style/a\` (count: 9) — project A OVERRIDE
- \`style/c\` (count: 2) — project C" \
  "- \`w1\` — project wording one OVERRIDE"

run bash "$MP" merge --global "$GLOBAL" --project "$PROJECT"
check "merge: exit 0" "[ \"$RC\" = 0 ]" "$RC"
# same-key project REPLACES global (A shows the project's text + count).
check "merge: same-key A replaced by project" "printf '%s' \"\$OUT\" | grep -qF '\`style/a\` (count: 9) — project A OVERRIDE'"
check "merge: global A text gone"              "! printf '%s' \"\$OUT\" | grep -qF 'global A'"
# different keys UNION (B from global survives; C from project added).
check "merge: global-only B survives (union)"  "printf '%s' \"\$OUT\" | grep -qF '\`style/b\` (count: 1) — global B'"
check "merge: project-only C added (union)"     "printf '%s' \"\$OUT\" | grep -qF '\`style/c\` (count: 2) — project C'"
# Wording same-key replaced.
check "merge: wording W1 replaced by project"  "printf '%s' \"\$OUT\" | grep -qF '\`w1\` — project wording one OVERRIDE'"
# Rubric weighting is merge/preserve-only — it still merges through.
check "merge: rubric weighting preserved"      "printf '%s' \"\$OUT\" | grep -qF '\`allow-large-diffs\`'"
# A missing (optional) project file → global-only merge, no error.
run bash "$MP" merge --global "$GLOBAL" --project "$ROOT_TMP/nope.md"
check "merge: absent project file → exit 0"   "[ \"$RC\" = 0 ]" "$RC"
check "merge: global entries present w/o project" "printf '%s' \"\$OUT\" | grep -qF '\`style/b\`'"

# ===========================================================================
# upsert — propose-then-confirm, scoped write, count increment
# ===========================================================================
echo "== upsert (propose / confirm / scope / count) =="

# Propose (no --confirm) writes NOTHING but prints the PROPOSED entry.
NEWP="$ROOT_TMP/scoped-project.md"
NEWG="$ROOT_TMP/scoped-global.md"
run bash "$MP" upsert --scope project --file "$NEWP" \
  --section dont-raise --key "style/x" --text "don't raise x"
check "propose: exit 0"                 "[ \"$RC\" = 0 ]" "$RC"
check "propose: prints PROPOSED"        "printf '%s' \"\$OUT\" | grep -q '^PROPOSED=- .style/x. (count: 1) — don.t raise x'"
check "propose: names the scope"        "printf '%s' \"\$OUT\" | grep -q '^SCOPE=project$'"
check "propose: writes NOTHING"         "[ ! -e '$NEWP' ]"

# Confirmed write lands in the CHOSEN scope's file, and only that file.
: > "$NEWG"   # a pre-existing (empty) global to prove it stays untouched
run bash "$MP" upsert --scope project --file "$NEWP" \
  --section dont-raise --key "style/x" --text "don't raise x" --increment --confirm
check "confirm: exit 0"                 "[ \"$RC\" = 0 ]" "$RC"
check "confirm: WROTE=project"          "printf '%s' \"\$OUT\" | grep -q '^WROTE=project$'"
check "confirm: ACTION=appended"        "printf '%s' \"\$OUT\" | grep -q '^ACTION=appended$'"
check "confirm: entry landed in project" "grep -qF '\`style/x\` (count: 1) — don'\''t raise x' '$NEWP'"
check "confirm: chosen scope only — global untouched" "[ ! -s '$NEWG' ]"

# A repeated same-key skip INCREMENTS the count (confidence), keeping the text.
run bash "$MP" upsert --scope project --file "$NEWP" \
  --section dont-raise --key "style/x" --text "IGNORED on increment" --increment --confirm
check "increment: ACTION=incremented"   "printf '%s' \"\$OUT\" | grep -q '^ACTION=incremented$'"
check "increment: COUNT=2"              "printf '%s' \"\$OUT\" | grep -q '^COUNT=2$'"
check "increment: count bumped in file" "grep -qF '\`style/x\` (count: 2)' '$NEWP'"
check "increment: original text kept"   "grep -qF 'don'\''t raise x' '$NEWP'"
check "increment: no duplicate entry"   "[ \"\$(grep -cF '\`style/x\`' '$NEWP')\" = 1 ]"

# Propose on an existing key reflects the count the confirmed write WOULD land.
run bash "$MP" upsert --scope project --file "$NEWP" \
  --section dont-raise --key "style/x" --text "x" --increment
check "propose existing: reflects next count 3" "printf '%s' \"\$OUT\" | grep -q '^PROPOSED=- .style/x. (count: 3)'"
check "propose existing: still no write (count stays 2)" "grep -qF '(count: 2)' '$NEWP'"

# Scope the other way: write to GLOBAL, prove the project file is untouched.
# shellcheck disable=SC2034
BEFORE="$(cat "$NEWP")"
run bash "$MP" upsert --scope global --file "$NEWG" \
  --section wording --key "voice/suggestions" --text "frame as suggestions" --confirm
check "scope global: WROTE=global"      "printf '%s' \"\$OUT\" | grep -q '^WROTE=global$'"
check "scope global: entry in global"   "grep -qF '\`voice/suggestions\` — frame as suggestions' '$NEWG'"
check "scope global: project untouched" "[ \"\$(cat '$NEWP')\" = \"\$BEFORE\" ]"
# Wording entries carry NO count marker.
check "wording: no count marker"        "! grep -qF 'count:' '$NEWG'"

# --increment is a Don't-raise-only concept (only it carries a count). Applying
# it to Wording/Confirmed-valued would corrupt an entry into a counted one, so
# it is refused at validation and NOTHING is written.
INCW="$ROOT_TMP/increment-wording.md"
run bash "$MP" upsert --scope global --file "$INCW" \
  --section wording --key "voice/x" --text "y" --increment --confirm
check "increment on wording: refused exit 2" "[ \"$RC\" = 2 ]" "$RC"
check "increment on wording: says dont-raise only" "printf '%s' \"\$ERR\" | grep -qi 'dont-raise'"
check "increment on wording: nothing written" "[ ! -e '$INCW' ]"

# Confirmed valued is a keyed inferred section too.
run bash "$MP" upsert --scope global --file "$NEWG" \
  --section confirmed-valued --key "correctness/off-by-one" --text "keep surfacing" --confirm
check "confirmed-valued: entry written" "grep -qF '\`correctness/off-by-one\` — keep surfacing' '$NEWG'"

# rubric-weighting is merge/preserve-only — upsert REFUSES to write it.
run bash "$MP" upsert --scope global --file "$NEWG" \
  --section rubric-weighting --key "flag" --text "x" --confirm
check "rubric-weighting: refused exit 2" "[ \"$RC\" = 2 ]" "$RC"
check "rubric-weighting: says preserve-only" "printf '%s' \"\$ERR\" | grep -qi 'preserve-only'"
check "rubric-weighting: nothing written" "! grep -qF '\`flag\`' '$NEWG'"

# Other sections + header preserved byte-for-byte across a write (targeted edit).
mk_prefs "$ROOT_TMP/pre.md" "- \`k/a\` (count: 1) — A" "- \`w\` — W"
cp "$ROOT_TMP/pre.md" "$ROOT_TMP/pre.expected"
run bash "$MP" upsert --scope project --file "$ROOT_TMP/pre.md" \
  --section confirmed-valued --key "new/key" --text "added" --confirm
check "preserve: header/intro intact"   "grep -qF 'Intro prose that must be preserved.' '$ROOT_TMP/pre.md'"
check "preserve: Don't-raise untouched" "grep -qF '\`k/a\` (count: 1) — A' '$ROOT_TMP/pre.md'"
check "preserve: Wording untouched"     "grep -qF '\`w\` — W' '$ROOT_TMP/pre.md'"
check "preserve: rubric weighting untouched" "grep -qF '\`allow-large-diffs\`' '$ROOT_TMP/pre.md'"
check "preserve: new entry in its section" "grep -qF '\`new/key\` — added' '$ROOT_TMP/pre.md'"

# ===========================================================================
# declined-append — the shared ## Declined contract (ARTIFACT.md)
# ===========================================================================
echo "== declined-append (## Declined) =="

mk_artifact() {
  cat > "$1" <<'EOF'
# Merge review: 77

id: 77
forge: github
Reviewed at commit: abc123
<!-- merge-review-status: findings -->

## Intent

Wire the clients page to the API.

## Handled

- **thread#5** — implemented

## Declined

- **thread#9** — out of scope: not this MR's concern

## Findings

```jsonl
{"id":"F-aaa","prefix":"issue:","kind":"general","file":null,"body":"only finding"}
```

## Build

build/test: pass
EOF
}

ART="$ROOT_TMP/77.md"; mk_artifact "$ART"
run bash "$MP" declined-append --file "$ART" \
  --finding-id F-aaa --summary "reopens blank dialog on create error"
check "declined: exit 0"                "[ \"$RC\" = 0 ]" "$RC"
check "declined: DECLINED=F-aaa"        "printf '%s' \"\$OUT\" | grep -q '^DECLINED=F-aaa$'"
check "declined: bullet appended"       "grep -qF -- '- **F-aaa** — reopens blank dialog on create error — declined at post gate' '$ART'"
check "declined: prior declined kept"   "grep -qF -- '- **thread#9** — out of scope' '$ART'"
check "declined: bullet is IN ## Declined, before ## Findings" \
  "[ \"\$(grep -n 'F-aaa' '$ART' | head -1 | cut -d: -f1)\" -lt \"\$(grep -n '^## Findings' '$ART' | cut -d: -f1)\" ]"
# Every other section preserved byte-for-byte (Intent/Handled/Findings/Build).
check "declined: Intent preserved"      "grep -qF 'Wire the clients page to the API.' '$ART'"
check "declined: Handled preserved"     "grep -qF -- '- **thread#5** — implemented' '$ART'"
check "declined: Findings preserved"    "grep -qF '\"id\":\"F-aaa\"' '$ART'"
check "declined: Build preserved"       "grep -qF 'build/test: pass' '$ART'"

# Custom rationale is carried through.
run bash "$MP" declined-append --file "$ART" \
  --finding-id F-bbb --summary "nitpick on naming" --rationale "style preference, not a defect"
check "declined: custom rationale"      "grep -qF -- '- **F-bbb** — nitpick on naming — style preference, not a defect' '$ART'"

# Append-only creates the heading when it is absent.
NOHEAD="$ROOT_TMP/nohead.md"
cat > "$NOHEAD" <<'EOF'
# Merge review: 88

id: 88

## Findings

```jsonl
```

## Build

pass
EOF
run bash "$MP" declined-append --file "$NOHEAD" --finding-id F-zzz --summary "some finding"
check "declined: creates ## Declined when absent" "grep -q '^## Declined$' '$NOHEAD'"
check "declined: bullet under new heading"        "grep -qF -- '- **F-zzz** — some finding — declined at post gate' '$NOHEAD'"
check "declined: existing Findings still present" "grep -q '^## Findings$' '$NOHEAD'"

# Missing artifact → operational failure (exit 1), nothing created.
run bash "$MP" declined-append --file "$ROOT_TMP/gone.md" --finding-id F-x --summary "y"
check "declined: missing artifact → exit 1" "[ \"$RC\" = 1 ]" "$RC"

# ===========================================================================
# argument validation
# ===========================================================================
echo "== argument validation =="

run bash "$MP"
check "no subcommand → exit 2"          "[ \"$RC\" = 2 ]" "$RC"
run bash "$MP" bogus
check "unknown subcommand → exit 2"     "[ \"$RC\" = 2 ]" "$RC"
run bash "$MP" upsert --scope nope --file /x --section dont-raise --key k --text t
check "upsert: bad scope → exit 2"      "[ \"$RC\" = 2 ]" "$RC"
run bash "$MP" upsert --scope project --file /x --section bogus --key k --text t
check "upsert: bad section → exit 2"    "[ \"$RC\" = 2 ]" "$RC"
run bash "$MP" upsert --scope project --file /x --section dont-raise --key "has space" --text t
check "upsert: spaced key → exit 2"     "[ \"$RC\" = 2 ]" "$RC"
run bash "$MP" upsert --scope project --file /x --section dont-raise --key k
check "upsert: missing text → exit 2"   "[ \"$RC\" = 2 ]" "$RC"
run bash "$MP" merge
check "merge: no files → exit 2"        "[ \"$RC\" = 2 ]" "$RC"
run bash "$MP" declined-append --file /x --summary y
check "declined: missing finding-id → exit 2" "[ \"$RC\" = 2 ]" "$RC"
run bash "$MP" declined-append --file "$ART" --finding-id BADID --summary y
check "declined: non-F id → exit 2"     "[ \"$RC\" = 2 ]" "$RC"

echo
echo "== merge-prefs_test: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
