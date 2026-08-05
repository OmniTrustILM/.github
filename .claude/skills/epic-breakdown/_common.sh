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

# set_number FIELD_NAME INTEGER  (uses PROJECT_ID, ITEM_ID, CACHE_DIR, GRAPHQL_DOC)
# Estimate is whole mandays (§3.5 heuristics use integer ranges). If fractional
# mandays are ever needed, switch to a JSON variables payload — gh -F sends
# non-integers as strings, which a Float! argument would reject.
set_number() {
  local field_name="$1" number="$2" field_id dtype
  field_id=$(jq -r --arg f "$field_name" '.fields[$f].id // ""' "$CACHE_DIR/project-fields.json")
  dtype=$(jq -r --arg f "$field_name" '.fields[$f].dataType // ""' "$CACHE_DIR/project-fields.json")
  [ -n "$field_id" ] || { log "  skip: field '$field_name' not in cache"; return 1; }
  [ "$dtype" = "NUMBER" ] || fail "field '$field_name' is '$dtype', not NUMBER"
  [[ "$number" =~ ^[0-9]+$ ]] || fail "estimate must be a whole number of mandays, got '$number'"
  if gh api graphql -f query="$(gql_op SetNumberValue)" \
       -f projectId="$PROJECT_ID" -f itemId="$ITEM_ID" -f fieldId="$field_id" -F number="$number" >/dev/null 2>&1; then
    log "  set $field_name=$number"
  else
    log "  warn: failed to set $field_name=$number"
    return 1
  fi
}
