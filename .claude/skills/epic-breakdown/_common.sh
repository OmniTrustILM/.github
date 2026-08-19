# shellcheck shell=bash
# Shared helpers for the epic-breakdown skill's scripts. SOURCE this; do not run.
# Callers must set, before sourcing or before calling the helpers that need them:
#   SCRIPT_TAG   short tag for log lines (e.g. "create", "link")
#   GRAPHQL_DOC  path to epic-breakdown.graphql
#   CACHE_DIR    path to the skill's cache/
# Field setters additionally require PROJECT_ID and ITEM_ID in scope.

# shellcheck disable=SC2034  # consumed by the scripts that source this file
ORG="OmniTrustILM"

log()  { echo "[${SCRIPT_TAG:-epic-breakdown}] $*" >&2; }
fail() { echo "error: $*" >&2; exit 1; }

# Resolve a Python 3 interpreter into $PYTHON and force UTF-8 stdio.
# `python` on PATH can still be Python 2, where the embedded snippets fail with
# confusing errors (`open(..., encoding=)`, f-strings), so the version is
# verified rather than assumed. UTF-8 stdio is mandatory: without it Python
# writes issue bodies in the console encoding (cp1252 on Windows) and every
# non-ASCII character becomes U+FFFD.
resolve_python() {
  PYTHON="$(command -v python3 || command -v python || true)"
  [ -n "$PYTHON" ] || fail "python3 not found on PATH"
  "$PYTHON" -c 'import sys; sys.exit(0 if sys.version_info[0] >= 3 else 1)' 2>/dev/null \
    || fail "python3 required, but $PYTHON is Python 2 — install python3 or put it first on PATH"
  export PYTHONIOENCODING=utf-8
}

# Extract one named GraphQL operation (mutation or query) from $GRAPHQL_DOC.
# The operation's closing brace is the only line that is exactly "}" at col 0.
# Fails loudly if the operation is not found, so a typo/stale file can't send an
# empty query that the API rejects with a confusing error.
gql_op() {
  local out
  out=$(awk -v op="$1" '
    $0 ~ "^(mutation|query) " op "[ (]" { f = 1 }
    f { print }
    f && /^}$/ { exit }
  ' "$GRAPHQL_DOC")
  [ -n "$out" ] || fail "gql_op: GraphQL operation '$1' not found in $GRAPHQL_DOC"
  printf '%s\n' "$out"
}

# Fail (unless the caller is in dry-run) if the token lacks the write 'project'
# scope. Empty scopes line = app/fine-grained token; let the API enforce instead.
require_project_scope() {
  local scopes
  scopes="$(gh auth status 2>&1 | grep -E 'Token scopes:' || true)"
  [ -z "$scopes" ] && return 0
  printf '%s' "$scopes" | grep -qE "'project'" \
    || fail "writing project items needs the 'project' scope. Run: gh auth refresh -s project"
}

# set_single_select FIELD_NAME OPTION_NAME  (uses PROJECT_ID, ITEM_ID, CACHE_DIR, GRAPHQL_DOC)
# Case-insensitive option lookup. Returns non-zero (and warns) on any miss.
set_single_select() {
  local field_name="$1" option_name="$2" field_id raw option_id canonical
  field_id=$(jq -r --arg f "$field_name" '.fields[$f].id // ""' "$CACHE_DIR/project-fields.json")
  # "<option_id> <option name>"; the option name may contain spaces, so split on
  # the FIRST space only (read -r would truncate multi-word names).
  raw=$(jq -r --arg f "$field_name" --arg o "$option_name" '
    (.fields[$f].options // {}) | to_entries
    | map(select(.key | ascii_downcase == ($o | ascii_downcase))) | first
    | if . == null then "" else "\(.value) \(.key)" end' "$CACHE_DIR/project-fields.json")
  [ -n "$field_id" ] || { log "  skip: field '$field_name' not in cache"; return 1; }
  [ -n "$raw" ]      || { log "  skip: option '$option_name' not valid for '$field_name'"; return 1; }
  option_id="${raw%% *}"; canonical="${raw#* }"
  if gh api graphql -f query="$(gql_op SetSingleSelectValue)" \
       -f projectId="$PROJECT_ID" -f itemId="$ITEM_ID" -f fieldId="$field_id" -f optionId="$option_id" >/dev/null 2>&1; then
    log "  set $field_name=$canonical"
  else
    log "  warn: failed to set $field_name=$canonical (option ID may be stale; re-run fetch.sh)"
    return 1
  fi
}

# Ceiling on a single item's estimate. Guards a fat-fingered 500 for 50; an
# item genuinely larger than this is an Epic that needs splitting, not a number.
ESTIMATE_MAX=365

# estimate_is_valid MANDAYS — quarter-day steps only (§3.5).
# 0.25 is both the minimum and the increment: 0.25, 0.5, 0.75, 1, 1.25 … There
# is no finer granularity. Anything between the steps is false precision on a
# number that already carries a review buffer, and 0 is not an estimate - it
# would clear the §3.2 required-field gate while saying nothing.
ESTIMATE_RULE_MSG="estimate must be a positive multiple of 0.25 mandays (0.25, 0.5, 0.75, 1, 1.25 ...), at most $ESTIMATE_MAX"
estimate_is_valid() {
  [[ "$1" =~ ^(0|[1-9][0-9]*)(\.([0-9]{1,2}))?$ ]] || return 1
  local whole="${BASH_REMATCH[1]}" frac="${BASH_REMATCH[3]}"
  case "${#frac}" in 0) frac=00 ;; 1) frac="${frac}0" ;; esac
  case "$frac" in 00|25|50|75) ;; *) return 1 ;; esac
  [ "$whole" = 0 ] && [ "$frac" = 00 ] && return 1
  [ "$whole" -le "$ESTIMATE_MAX" ] || return 1
}

# number_payload FIELD_ID NUMBER  (uses PROJECT_ID, ITEM_ID, GRAPHQL_DOC)
# Separated from the mutation so a test can assert the payload shape offline —
# specifically that `variables.number` leaves as a JSON number. `gh -F`
# type-infers and sends a non-integer as a string, which `Float!` rejects with
# the unhelpful "provided invalid value"; `--argjson` keeps the type.
number_payload() {
  jq -n --arg q "$(gql_op SetNumberValue)" --arg p "$PROJECT_ID" --arg i "$ITEM_ID" \
        --arg f "$1" --argjson n "$2" \
        '{query:$q, variables:{projectId:$p, itemId:$i, fieldId:$f, number:$n}}'
}

# set_number FIELD_NAME MANDAYS  (uses PROJECT_ID, ITEM_ID, CACHE_DIR, GRAPHQL_DOC)
set_number() {
  local field_name="$1" number="$2" field_id dtype
  field_id=$(jq -r --arg f "$field_name" '.fields[$f].id // ""' "$CACHE_DIR/project-fields.json")
  dtype=$(jq -r --arg f "$field_name" '.fields[$f].dataType // ""' "$CACHE_DIR/project-fields.json")
  [ -n "$field_id" ] || { log "  skip: field '$field_name' not in cache"; return 1; }
  [ "$dtype" = "NUMBER" ] || fail "field '$field_name' is '$dtype', not NUMBER"
  # `return 1` into the warn path, not `fail`: callers set several fields per
  # item, and aborting here would leave the item half-written mid-sequence.
  # set-epic-fields.sh validates up front, so reaching this is a caller bug.
  # The quarter-day rule is Estimate's, not every NUMBER field's - a second
  # numeric field must not silently inherit it.
  if [ "$field_name" = "Estimate" ]; then
    estimate_is_valid "$number" || { log "  warn: $ESTIMATE_RULE_MSG, got '$number'"; return 1; }
  else
    [[ "$number" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] \
      || { log "  warn: $field_name must be numeric, got '$number'"; return 1; }
  fi
  if err=$(number_payload "$field_id" "$number" | gh api graphql --input - 2>&1 >/dev/null); then
    log "  set $field_name=$number"
  else
    # Keep the API's reason. Without it every failure - stale ID, lost scope,
    # malformed payload - reads identically and has to be re-diagnosed by hand.
    err=$(printf '%s' "$err" | tr '\n' ' ' | cut -c1-200)
    log "  warn: failed to set $field_name=$number${err:+ ($err)}"
    return 1
  fi
}
