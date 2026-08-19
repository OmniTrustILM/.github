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

# Two ceilings, both derived from delivery capacity rather than picked.
#
# Epic: a release is a ~10-week development cycle (50 working days) and an Epic
# is staffed by at most 2 people, so 100 mandays is the largest estimate that
# can fit one release. Above it the Epic has to be split.
#
# Child: 4 mandays keeps a sub-issue deliverable inside one week with reserve.
# A child above it is usually an Epic wearing the wrong issue type - but not
# always, so it is allowed when the issue body says why it cannot be split
# (§3.5). That justification is enforced, not requested; see require_estimate_rationale.
ESTIMATE_MAX_EPIC=100
ESTIMATE_MAX_CHILD=4

# estimate_quarters MANDAYS — echo the value in whole quarter-day units.
# Everything downstream compares integers, so decimal boundaries (100 vs 100.25)
# cannot be got subtly wrong.
estimate_quarters() {
  [[ "$1" =~ ^(0|[1-9][0-9]*)(\.([0-9]{1,2}))?$ ]] || return 1
  local whole="${BASH_REMATCH[1]}" frac="${BASH_REMATCH[3]}" q
  case "${#frac}" in 0) frac=00 ;; 1) frac="${frac}0" ;; esac
  case "$frac" in 00) q=0 ;; 25) q=1 ;; 50) q=2 ;; 75) q=3 ;; *) return 1 ;; esac
  printf '%d' $(( whole * 4 + q ))
}

# estimate_is_valid MANDAYS MAX_MANDAYS — quarter-day steps only (§3.5).
# 0.25 is both the minimum and the increment: 0.25, 0.5, 0.75, 1, 1.25 … There
# is no finer granularity. Anything between the steps is false precision on a
# number that already carries a review buffer, and 0 is not an estimate - it
# would clear the §3.2 required-field gate while saying nothing.
estimate_is_valid() {
  local q max="${2:-$ESTIMATE_MAX_EPIC}"
  q=$(estimate_quarters "$1") || return 1
  [ "$q" -gt 0 ] || return 1
  [ "$q" -le $(( max * 4 )) ] || return 1
}

estimate_rule_msg() {
  printf 'estimate must be a positive multiple of 0.25 mandays (0.25, 0.5, 0.75, 1, 1.25 ...), at most %s' "$1"
}

# require_estimate_rationale ITEM_ID MANDAYS
# A child over ESTIMATE_MAX_CHILD is allowed only when its issue body explains
# why it cannot be split. Read that from the body rather than taking it as a
# flag: the body is what a reviewer reads six months later, and a flag would let
# the two drift. Silence here means the child should have been decomposed.
# estimate_rationale_ok BODY — 0 when the body carries a usable reason.
# Exit 1 = no '### Estimate' section, 2 = section present but empty or too short
# to be a reason. Pure so it can be tested without touching a live issue.
estimate_rationale_ok() {
  local body="$1" rationale
  printf '%s' "$body" | grep -qiE '^#{2,4}[[:space:]]*Estimate[[:space:]]*$' || return 1
  rationale=$(printf '%s' "$body" \
    | sed -n '/^#\{2,4\}[[:space:]]*[Ee]stimate[[:space:]]*$/,$p' \
    | sed '1d' | sed -n '/^#\{2,4\}[[:space:]]/q;p' | tr -d '[:space:]')
  [ "${#rationale}" -ge 20 ] || return 2
}

require_estimate_rationale() {
  local item="$1" mandays="$2" body rc=0
  body=$(gh api graphql -f id="$item" -f query='
    query($id:ID!){ node(id:$id){ ... on ProjectV2Item {
      content { ... on Issue { body } } } } }' \
    -q '.data.node.content.body // ""' 2>/dev/null) \
    || fail "could not read the issue body for item $item to check the estimate rationale"

  estimate_rationale_ok "$body" || rc=$?
  case "$rc" in
    0) ;;
    1) fail "child estimate ${mandays} exceeds ${ESTIMATE_MAX_CHILD} mandays: split it, or add an '### Estimate' section to the issue body saying why it cannot be split (§3.5)" ;;
    2) fail "the '### Estimate' section is empty or too short to be a reason; state why ${mandays} mandays cannot be split (§3.5)" ;;
  esac
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
    estimate_is_valid "$number" "$ESTIMATE_MAX" \
      || { log "  warn: $(estimate_rule_msg "$ESTIMATE_MAX"), got '$number'"; return 1; }
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
