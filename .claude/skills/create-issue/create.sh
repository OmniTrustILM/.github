#!/usr/bin/env bash
# Create one OmniTrustILM issue and set its project fields.
#
# Inputs (env or args):
#   --repo NAME         (required) target repo short name (no owner)
#   --type NAME         (required) issue type: bug|feature|task|documentation|qa
#   --title TEXT        (required) issue title
#   --body-file PATH    (required) path to file containing the form-shaped body
#   --severity NAME     (optional, Bug only) Minor|Major|Critical|Blocker
#   --module NAME       (optional) one of the 17 Module values
#   --label NAME        (optional, repeatable) extra labels beyond template defaults
#
# Output: prints created issue URL, project item id, and field-set summary.
#
# Reads cache/project-fields.json, cache/repos.json, cache/templates.json.
# Aborts if any required cache file is missing.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="$SKILL_DIR/cache"
GRAPHQL_DOC="$SKILL_DIR/create-fields.graphql"

log()  { echo "[create] $*" >&2; }
fail() { echo "error: $*" >&2; exit 1; }

# --- Required cache files ---
for f in project-fields.json repos.json templates.json; do
  [ -f "$CACHE_DIR/$f" ] || fail "missing $CACHE_DIR/$f — run fetch.sh first"
done

# --- Parse args ---
REPO="" TYPE="" TITLE="" BODY_FILE="" SEVERITY="" MODULE=""
LABELS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)       REPO="$2"; shift 2 ;;
    --type)       TYPE="$2"; shift 2 ;;
    --title)      TITLE="$2"; shift 2 ;;
    --body-file)  BODY_FILE="$2"; shift 2 ;;
    --severity)   SEVERITY="$2"; shift 2 ;;
    --module)     MODULE="$2"; shift 2 ;;
    --label)      LABELS+=("$2"); shift 2 ;;
    *)            fail "unknown arg: $1" ;;
  esac
done

[ -n "$REPO" ]      || fail "--repo is required"
[ -n "$TYPE" ]      || fail "--type is required"
[ -n "$TITLE" ]     || fail "--title is required"
[ -n "$BODY_FILE" ] || fail "--body-file is required"
# --body-file - reads body from stdin into a script-internal temp file.
# Avoids cross-tool tmp-path mismatch when SKILL.md (LLM) writes a temp
# file and then invokes this script in a separate tool call.
if [ "$BODY_FILE" = "-" ]; then
  TMP_BODY=$(mktemp)
  cat > "$TMP_BODY"
  BODY_FILE="$TMP_BODY"
  trap 'rm -f "$TMP_BODY"' EXIT
fi
[ -f "$BODY_FILE" ] || fail "body file not found: $BODY_FILE"

# --- Validate against cache ---
if ! jq -e --arg r "$REPO" '[.[] | .name] | contains([$r])' "$CACHE_DIR/repos.json" >/dev/null; then
  fail "repo '$REPO' not in cached org list. Run fetch.sh --refresh if it's recently created."
fi

# --- Subsequent steps populated in later tasks ---
# --- Diagnostic dump of resolved inputs (caller may pipe to a log) ---
log "inputs: repo=$REPO type=$TYPE severity=${SEVERITY:-(unset)} module=${MODULE:-(unset)} extra_labels=${LABELS[*]:-(none)} title=$TITLE"

# --- Resolve labels: type-template defaults + caller-supplied ---
TEMPLATE_LABELS=$(jq -r --arg t "$TYPE" \
  '[.[] | select((._file // "") | sub("\\.ya?ml$"; "") | ascii_downcase == ($t | ascii_downcase)) | (.labels // [])[]] | unique | .[]' \
  "$CACHE_DIR/templates.json")
LABEL_FLAGS=()
while IFS= read -r l; do [ -n "$l" ] && LABEL_FLAGS+=(--label "$l"); done <<<"$TEMPLATE_LABELS"
for l in "${LABELS[@]:-}"; do [ -n "$l" ] && LABEL_FLAGS+=(--label "$l"); done

# Loud warning when a typed template should have produced labels but didn't.
# Bug/Feature/Documentation/QA Issue/Vulnerability all carry default labels;
# Task is the only supported type without one. Surface state instead of
# letting an empty LABEL_FLAGS silently produce a label-less issue.
if [ ${#LABEL_FLAGS[@]} -eq 0 ]; then
  log "  no labels resolved for type=$TYPE (known label-less types: task)"
else
  log "  label flags: ${LABEL_FLAGS[*]}"
fi

# Project mutations below (add-to-project + set fields) need the 'project' write
# scope. Check BEFORE the irreversible `gh issue create`, so a missing scope
# fails cleanly instead of leaving an orphaned issue not in Project #5.
# (An empty scopes line means a fine-grained/app token — let the API enforce.)
SCOPES_LINE=$(gh auth status 2>&1 | grep -E "Token scopes:" || true)
if [ -n "$SCOPES_LINE" ] && ! printf '%s' "$SCOPES_LINE" | grep -qE "'project'"; then
  fail "token missing 'project' scope (needed to add the issue to Project #5 and set fields). Run: gh auth refresh -s project"
fi

# --- Create the issue ---
# Note: this gh version does not support --json on `gh issue create`,
# so we capture the URL on stdout and fetch the node_id via REST.
log "creating issue in OmniTrustILM/$REPO"
ISSUE_URL=$(gh issue create \
  --repo "OmniTrustILM/$REPO" \
  --title "$TITLE" \
  --body-file "$BODY_FILE" \
  ${LABEL_FLAGS[@]+"${LABEL_FLAGS[@]}"}) || fail "gh issue create failed (see stderr above)"
ISSUE_NUMBER=$(echo "$ISSUE_URL" | grep -oE '[0-9]+$')
[ -n "$ISSUE_NUMBER" ] || fail "could not extract issue number from URL: $ISSUE_URL"
ISSUE_NODE_ID=$(gh api "repos/OmniTrustILM/$REPO/issues/$ISSUE_NUMBER" --jq '.node_id')

log "created: $ISSUE_URL (node id: $ISSUE_NODE_ID)"

# --- Add to Project #5 ---
PROJECT_ID=$(jq -r '.project_id' "$CACHE_DIR/project-fields.json")
[ "$PROJECT_ID" != "null" ] && [ -n "$PROJECT_ID" ] || fail "project_id missing from cache"

log "adding to project $PROJECT_ID"
ITEM_RESP=$(gh api graphql \
  -f query="$(awk '/^mutation AddItem/,/^}$/' "$GRAPHQL_DOC")" \
  -f projectId="$PROJECT_ID" \
  -f contentId="$ISSUE_NODE_ID" 2>&1) || {
    echo "$ITEM_RESP" >&2
    # Fix #10: orphan log so the user has an audit trail
    printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$ISSUE_URL" "addProjectV2ItemById failed" \
      >> "$CACHE_DIR/orphans.log"
    fail "GraphQL addProjectV2ItemById failed; issue exists at $ISSUE_URL but is not in Project #5. Logged to $CACHE_DIR/orphans.log."
  }
ITEM_ID=$(echo "$ITEM_RESP" | jq -r '.data.addProjectV2ItemById.item.id')
[ "$ITEM_ID" != "null" ] && [ -n "$ITEM_ID" ] || fail "no item id returned; response: $ITEM_RESP"
log "  item id: $ITEM_ID"

# --- Set Issue Type ---
# gh issue create has no --type flag for org Issue Types. Look up the
# template's `type:` field, map to issueTypeId via cache/issue-types.json,
# then call updateIssueIssueType. Skipped silently if cache missing.
if [ -f "$CACHE_DIR/issue-types.json" ]; then
  TEMPLATE_TYPE=$(jq -r --arg t "$TYPE" \
    '[.[] | select((._file // "") | sub("\\.ya?ml$"; "") | ascii_downcase == ($t | ascii_downcase)) | (.type // empty)] | first // ""' \
    "$CACHE_DIR/templates.json")
  if [ -n "$TEMPLATE_TYPE" ]; then
    ITYPE_ID=$(jq -r --arg t "$TEMPLATE_TYPE" '.[$t] // ""' "$CACHE_DIR/issue-types.json")
    if [ -n "$ITYPE_ID" ]; then
      SET_TYPE_QUERY="$(awk '/^mutation SetIssueType/,/^}$/' "$GRAPHQL_DOC")"
      if gh api graphql -f query="$SET_TYPE_QUERY" \
          -f issueId="$ISSUE_NODE_ID" \
          -f issueTypeId="$ITYPE_ID" >/dev/null 2>&1; then
        log "  set Issue Type=$TEMPLATE_TYPE"
      else
        log "  warn: failed to set Issue Type=$TEMPLATE_TYPE"
      fi
    else
      log "  skip: Issue Type '$TEMPLATE_TYPE' not in cache (run --refresh)"
    fi
  fi
fi

# --- Set project fields ---
SET_FIELD_QUERY="$(awk '/^mutation SetSingleSelectValue/,/^}$/' "$GRAPHQL_DOC")"

set_single_select() {
  # $1=field name (cache key, exact case), $2=option name (case-insensitive)
  local field_name="$1" option_name="$2"
  local field_id option_id canonical_option

  field_id=$(jq -r --arg f "$field_name" '.fields[$f].id // ""' "$CACHE_DIR/project-fields.json")
  # Case-insensitive option lookup so --severity major matches "Major" in cache.
  # Returns option_id and canonical option name (for log clarity).
  read -r option_id canonical_option < <(jq -r --arg f "$field_name" --arg o "$option_name" '
    (.fields[$f].options // {}) | to_entries
    | map(select(.key | ascii_downcase == ($o | ascii_downcase)))
    | first
    | if . == null then "" else "\(.value) \(.key)" end
  ' "$CACHE_DIR/project-fields.json")

  [ -n "$field_id" ]  || { log "  skip: field '$field_name' not in cache"; return; }
  [ -n "$option_id" ] || { log "  skip: option '$option_name' not in field '$field_name'"; return; }
  option_name="$canonical_option"

  local err_file
  err_file=$(mktemp)
  if ! gh api graphql \
      -f query="$SET_FIELD_QUERY" \
      -f projectId="$PROJECT_ID" \
      -f itemId="$ITEM_ID" \
      -f fieldId="$field_id" \
      -f optionId="$option_id" >/dev/null 2>"$err_file"; then
    local err_msg
    err_msg=$(jq -r '.errors[0].message // .message // empty' "$err_file" 2>/dev/null)
    [ -z "$err_msg" ] && err_msg=$(head -c 200 "$err_file")
    log "  warn: failed to set $field_name=$option_name: $err_msg"
    # Fix #4: detect rotated option IDs and hint --refresh
    if echo "$err_msg" | grep -qiE 'invalid.*option|option.*not.*found|PROJECT_V2_FIELD_INVALID_OPTION'; then
      log "  hint: option ID may be stale; run with --refresh to update cache"
    fi
    rm -f "$err_file"
    return
  fi
  rm -f "$err_file"
  log "  set $field_name=$option_name"
}

if [ -n "$SEVERITY" ]; then set_single_select "Severity" "$SEVERITY"; fi
if [ -n "$MODULE" ];   then set_single_select "Module"   "$MODULE";   fi

# --- Final summary ---
log "done: $ISSUE_URL"
echo "url=$ISSUE_URL"
echo "number=$ISSUE_NUMBER"
echo "item_id=$ITEM_ID"
