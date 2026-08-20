#!/usr/bin/env bash
# Create one OmniTrustILM issue (an Epic shell or a sub-issue) and set its
# project fields. Mirrors create-issue/create.sh; adds Epic-type support, a
# node_id on stdout (link.sh needs it), --dry-run, and a guard against form
# tokens in the body that would race the auto-set-fields-from-form automation.
#
# Inputs (args):
#   --repo NAME         (required) target repo short name (no owner)
#   --type NAME         (required) epic|feature|task|bug|qa|documentation
#   --title TEXT        (required)
#   --body-file PATH    (required) form-shaped body; "-" reads stdin
#   --module NAME       (optional) one of the 17 Module values
#   --severity NAME     (optional, Bug children) Minor|Major|Critical|Blocker
#   --label NAME        (optional, repeatable) extra labels beyond template defaults
#   --dry-run           print planned gh/GraphQL calls; create nothing
#
# Output (stdout, key=value): url= number= item_id= node_id=
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="$SKILL_DIR/cache"
GRAPHQL_DOC="$SKILL_DIR/epic-breakdown.graphql"
SCRIPT_TAG="create"
# shellcheck source-path=SCRIPTDIR source=_common.sh
. "$SKILL_DIR/_common.sh"

for f in project-fields.json repos.json templates.json issue-types.json; do
  [ -f "$CACHE_DIR/$f" ] || fail "missing $CACHE_DIR/$f — run fetch.sh first"
done

REPO="" TYPE="" TITLE="" BODY_FILE="" MODULE="" SEVERITY="" DRY_RUN=0
LABELS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)      REPO="${2:-}"; shift 2 ;;
    --type)      TYPE="${2:-}"; shift 2 ;;
    --title)     TITLE="${2:-}"; shift 2 ;;
    --body-file) BODY_FILE="${2:-}"; shift 2 ;;
    --module)    MODULE="${2:-}"; shift 2 ;;
    --severity)  SEVERITY="${2:-}"; shift 2 ;;
    --label)     LABELS+=("${2:-}"); shift 2 ;;
    --dry-run)   DRY_RUN=1; shift ;;
    *)           fail "unknown arg: $1" ;;
  esac
done

[ -n "$REPO" ]      || fail "--repo is required"
[ -n "$TYPE" ]      || fail "--type is required"
[ -n "$TITLE" ]     || fail "--title is required"
[ -n "$BODY_FILE" ] || fail "--body-file is required"

if [ "$BODY_FILE" = "-" ]; then
  TMP_BODY=$(mktemp)
  cat > "$TMP_BODY"
  BODY_FILE="$TMP_BODY"
  trap 'rm -f "$TMP_BODY"' EXIT
fi
[ -f "$BODY_FILE" ] || fail "body file not found: $BODY_FILE"

# Guard (hard fail): a child body carrying tokens parsed by
# auto-set-fields-from-form (Module / Severity / Version Number) would race the
# issues.opened automation against this script's own GraphQL field writes — a
# non-deterministic last-writer-wins on the field value. epic-breakdown builds
# bodies WITHOUT these sections and sets the fields here (pass --module/--severity),
# so its values are authoritative.
if grep -qiE '^###[[:space:]]+(Module|Severity|Version Number)[[:space:]]*$' "$BODY_FILE"; then
  fail "body contains a form token (### Module / Severity / Version Number) that would race auto-set-fields-from-form. Omit these sections; set fields via --module/--severity instead."
fi

# Validate repo against cache.
jq -e --arg r "$REPO" '[.[] | .name] | contains([$r])' "$CACHE_DIR/repos.json" >/dev/null \
  || fail "repo '$REPO' not in cached org list. Run fetch.sh if it was created recently."

# Resolve template (by --type matching the template filename stem) -> labels + issue type.
TEMPLATE_LABELS=$(jq -r --arg t "$TYPE" \
  '[.[] | select((._file // "") | sub("\\.ya?ml$"; "") | ascii_downcase == ($t | ascii_downcase)) | (.labels // [])[]] | unique | .[]' \
  "$CACHE_DIR/templates.json")
TEMPLATE_TYPE=$(jq -r --arg t "$TYPE" \
  '[.[] | select((._file // "") | sub("\\.ya?ml$"; "") | ascii_downcase == ($t | ascii_downcase)) | (.type // empty)] | first // ""' \
  "$CACHE_DIR/templates.json")
[ -n "$TEMPLATE_TYPE" ] || fail "no template matches type '$TYPE' (expected: epic, feature, task, bug, qa, documentation)"

LABEL_FLAGS=()
while IFS= read -r l; do [ -n "$l" ] && LABEL_FLAGS+=(--label "$l"); done <<<"$TEMPLATE_LABELS"
for l in "${LABELS[@]:-}"; do [ -n "$l" ] && LABEL_FLAGS+=(--label "$l"); done

PROJECT_ID=$(jq -r '.project_id' "$CACHE_DIR/project-fields.json")
ITYPE_ID=$(jq -r --arg t "$TEMPLATE_TYPE" '.[$t] // ""' "$CACHE_DIR/issue-types.json")

if [ "$DRY_RUN" -eq 1 ]; then
  log "DRY-RUN — no mutations will run"
  log "would: gh issue create --repo $ORG/$REPO --title \"$TITLE\" --body-file <body> ${LABEL_FLAGS[*]:-(no labels)}"
  log "would: addProjectV2ItemById projectId=$PROJECT_ID contentId=<new node id>"
  log "would: updateIssueIssueType issueTypeId=${ITYPE_ID:-(unknown)} (type $TEMPLATE_TYPE)"
  [ -n "$MODULE" ]   && log "would: set Module=$MODULE"
  [ -n "$SEVERITY" ] && log "would: set Severity=$SEVERITY"
  echo "url=(dry-run)"; echo "number=(dry-run)"; echo "item_id=(dry-run)"; echo "node_id=(dry-run)"
  exit 0
fi

require_project_scope

# --- Create the issue ---
log "creating $TEMPLATE_TYPE in $ORG/$REPO"
ISSUE_URL=$(gh issue create --repo "$ORG/$REPO" --title "$TITLE" --body-file "$BODY_FILE" ${LABEL_FLAGS[@]:+"${LABEL_FLAGS[@]}"}) \
  || fail "gh issue create failed (see stderr above)"
ISSUE_NUMBER=$(echo "$ISSUE_URL" | grep -oE '[0-9]+$')
[ -n "$ISSUE_NUMBER" ] || fail "could not extract issue number from URL: $ISSUE_URL"
ISSUE_NODE_ID=$(gh api "repos/$ORG/$REPO/issues/$ISSUE_NUMBER" --jq '.node_id')
log "created: $ISSUE_URL ($ISSUE_NODE_ID)"

# --- Add to Project #5 ---
ITEM_RESP=$(gh api graphql -f query="$(gql_op AddItem)" \
  -f projectId="$PROJECT_ID" -f contentId="$ISSUE_NODE_ID" 2>&1) || {
    printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$ISSUE_URL" "addProjectV2ItemById failed" \
      >> "$CACHE_DIR/orphans.log"
    echo "$ITEM_RESP" >&2
    fail "addProjectV2ItemById failed; issue exists at $ISSUE_URL but is not in Project #5 (logged to orphans.log)."
  }
ITEM_ID=$(echo "$ITEM_RESP" | jq -r '.data.addProjectV2ItemById.item.id')
{ [ -n "$ITEM_ID" ] && [ "$ITEM_ID" != "null" ]; } || fail "no project item id returned: $ITEM_RESP"
log "  project item: $ITEM_ID"

# --- Set Issue Type ---
if [ -n "$ITYPE_ID" ]; then
  if gh api graphql -f query="$(gql_op SetIssueType)" \
       -f issueId="$ISSUE_NODE_ID" -f issueTypeId="$ITYPE_ID" >/dev/null 2>&1; then
    log "  set Issue Type=$TEMPLATE_TYPE"
  else
    log "  warn: failed to set Issue Type=$TEMPLATE_TYPE"
  fi
else
  log "  skip: Issue Type '$TEMPLATE_TYPE' not in cache (run fetch.sh)"
fi

# --- Set Module + Severity (epic-breakdown is authoritative; body omits the tokens) ---
[ -n "$MODULE" ]   && { set_single_select "Module" "$MODULE" || true; }
[ -n "$SEVERITY" ] && { set_single_select "Severity" "$SEVERITY" || true; }

log "done: $ISSUE_URL"
echo "url=$ISSUE_URL"
echo "number=$ISSUE_NUMBER"
echo "item_id=$ITEM_ID"
echo "node_id=$ISSUE_NODE_ID"
