#!/usr/bin/env bash
# Execute the confirmed release plan from cache/plan.json:
#   1. create the Release issue in OmniTrustILM/ilm (type Release),
#   2. create the "Bugs <version>" tech-epic (type Epic) as its sub-issue,
#   3. add both to Project #5 and set Status / Start Date / End Date
#      (+ Prioritization on the epic; Version only if the option exists).
#
# Sprint iterations and the Version option are NOT touched here — see
# SKILL.md: rewriting those field configurations via the API orphans every
# existing assignment. verify.sh finishes the job after the manual UI step.
#
# Writes cache/state.json with created issue/item ids for verify.sh.
# Output: key=value lines (release_url, release_number, epic_url, epic_number).
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="$SKILL_DIR/cache"
REPO="OmniTrustILM/ilm"

log()  { echo "[apply] $*" >&2; }
fail() { echo "error: $*" >&2; exit 1; }

for f in plan.json live.json project-fields.json issue-types.json; do
  [ -f "$CACHE_DIR/$f" ] || fail "missing $CACHE_DIR/$f — run fetch.sh and plan.sh first"
done

VERSION=$(jq -r '.version' "$CACHE_DIR/plan.json")
START=$(jq -r '.start_date' "$CACHE_DIR/plan.json")
END=$(jq -r '.end_date' "$CACHE_DIR/plan.json")
TARGET=$(jq -r '.target_date' "$CACHE_DIR/plan.json")
[ -n "$VERSION" ] && [ "$VERSION" != "null" ] || fail "plan.json has no version"
jq -e '.conflicts == []' "$CACHE_DIR/plan.json" >/dev/null \
  || fail "plan.json has unresolved conflicts — re-run plan.sh after fixing them"

PROJECT_ID=$(jq -r '.project_id' "$CACHE_DIR/project-fields.json")

# Project writes need the 'project' scope; check BEFORE the irreversible
# issue creation. (Empty scopes line = fine-grained/app token; API enforces.)
SCOPES_LINE=$(gh auth status 2>&1 | grep -E "Token scopes:" || true)
if [ -n "$SCOPES_LINE" ] && ! printf '%s' "$SCOPES_LINE" | grep -qE "'project'"; then
  fail "token missing 'project' scope. Run: gh auth refresh -s project"
fi

# --- Idempotence guard: refuse to duplicate existing issues ---
for title in "$VERSION" "Bugs $VERSION"; do
  HIT=$(gh issue list -R "$REPO" --state all --search "in:title \"$title\"" \
        --json number,title \
        | jq -r --arg t "$title" '[.[] | select(.title == $t)] | first | .number // empty')
  [ -z "$HIT" ] || fail "issue titled '$title' already exists in $REPO (#$HIT)"
done

field_id()  { jq -r --arg f "$1" '.fields[$f].id // ""' "$CACHE_DIR/project-fields.json"; }
option_id() { jq -r --arg f "$1" --arg o "$2" '.fields[$f].options[$o] // ""' "$CACHE_DIR/project-fields.json"; }

set_option() {  # $1=item_id $2=field name $3=option name $4=option id
  gh api graphql -f query='mutation($p: ID!, $i: ID!, $f: ID!, $o: String!) {
      updateProjectV2ItemFieldValue(input: {projectId: $p, itemId: $i, fieldId: $f, value: {singleSelectOptionId: $o}}) { projectV2Item { id } }
    }' -f p="$PROJECT_ID" -f i="$1" -f f="$(field_id "$2")" -f o="$4" >/dev/null \
    && log "  set $2=$3" || log "  warn: failed to set $2=$3"
}

set_date() {  # $1=item_id $2=field name $3=date
  gh api graphql -f query='mutation($p: ID!, $i: ID!, $f: ID!, $d: Date!) {
      updateProjectV2ItemFieldValue(input: {projectId: $p, itemId: $i, fieldId: $f, value: {date: $d}}) { projectV2Item { id } }
    }' -f p="$PROJECT_ID" -f i="$1" -f f="$(field_id "$2")" -f d="$3" >/dev/null \
    && log "  set $2=$3" || log "  warn: failed to set $2=$3"
}

create_issue() {  # $1=title $2=body $3=issue type name $4...=extra gh flags
  local title="$1" body="$2" type_name="$3"; shift 3
  local url number node_id item_id type_id
  url=$(gh issue create --repo "$REPO" --title "$title" --body "$body" "$@") \
    || fail "gh issue create failed for '$title'"
  number=$(echo "$url" | grep -oE '[0-9]+$')
  node_id=$(gh api "repos/$REPO/issues/$number" --jq '.node_id')
  log "created $type_name '$title': $url"

  type_id=$(jq -r --arg t "$type_name" '.[$t] // ""' "$CACHE_DIR/issue-types.json")
  gh api graphql -f query='mutation($id: ID!, $t: ID!) {
      updateIssueIssueType(input: {issueId: $id, issueTypeId: $t}) { issue { id } }
    }' -f id="$node_id" -f t="$type_id" >/dev/null \
    && log "  set Issue Type=$type_name" || log "  warn: failed to set Issue Type=$type_name"

  item_id=$(gh api graphql -f query='mutation($p: ID!, $c: ID!) {
      addProjectV2ItemById(input: {projectId: $p, contentId: $c}) { item { id } }
    }' -f p="$PROJECT_ID" -f c="$node_id" --jq '.data.addProjectV2ItemById.item.id') \
    || fail "issue exists at $url but adding to Project #5 failed"
  log "  added to Project #5 ($item_id)"

  set_option "$item_id" "Status" "Planning" "$(option_id Status Planning)"
  set_date "$item_id" "Start Date" "$START"
  set_date "$item_id" "End Date" "$END"

  # Version is set only when the option already exists; otherwise verify.sh
  # sets it after the manual UI step. Never written via updateProjectV2Field.
  local vopt
  vopt=$(jq -r --arg v "$VERSION" '.version_options[$v] // ""' "$CACHE_DIR/live.json")
  if [ -n "$vopt" ]; then
    set_option "$item_id" "Version" "$VERSION" "$vopt"
  else
    log "  Version option '$VERSION' not present yet — deferred to verify.sh"
  fi

  printf '%s\n%s\n%s\n%s\n' "$url" "$number" "$node_id" "$item_id"
}

# --- 1. Release issue ---
RELEASE_BODY="### Version Number

$VERSION

### Target Date

$TARGET

### QA Sign-off Checklist

- [ ] Smoke tests passed
- [ ] Regression tests passed
- [ ] No open Blocker bugs
- [ ] Lead QA sign-off"

R_OUT=$(create_issue "$VERSION" "$RELEASE_BODY" "Release")
R_URL=$(sed -n 1p <<<"$R_OUT"); R_NUMBER=$(sed -n 2p <<<"$R_OUT")
R_NODE=$(sed -n 3p <<<"$R_OUT"); R_ITEM=$(sed -n 4p <<<"$R_OUT")

# --- 2. Bugs tech-epic ---
EPIC_BODY="### User Story

Other bugs not assigned to a specific development

### Testing Requirements

- [ ] Manual testing required
- [ ] E2E automation required
- [ ] Existing tests need updating"

E_OUT=$(create_issue "Bugs $VERSION" "$EPIC_BODY" "Epic" --label tech-epic)
E_URL=$(sed -n 1p <<<"$E_OUT"); E_NUMBER=$(sed -n 2p <<<"$E_OUT")
E_NODE=$(sed -n 3p <<<"$E_OUT"); E_ITEM=$(sed -n 4p <<<"$E_OUT")

set_option "$E_ITEM" "Prioritization" "Medium" "$(option_id Prioritization Medium)"

# --- 3. Link the epic under the release ---
gh api graphql -f query='mutation($p: ID!, $c: ID!) {
    addSubIssue(input: {issueId: $p, subIssueId: $c}) { issue { id } }
  }' -f p="$R_NODE" -f c="$E_NODE" >/dev/null \
  && log "linked Bugs $VERSION as sub-issue of $VERSION" \
  || log "warn: failed to link sub-issue — link #$E_NUMBER under #$R_NUMBER manually"

# --- 4. Persist state for verify.sh ---
jq -n --arg v "$VERSION" \
      --arg rurl "$R_URL" --arg rnum "$R_NUMBER" --arg ritem "$R_ITEM" \
      --arg eurl "$E_URL" --arg enum "$E_NUMBER" --arg eitem "$E_ITEM" \
      '{version: $v,
        release: {url: $rurl, number: ($rnum | tonumber), item_id: $ritem},
        epic:    {url: $eurl, number: ($enum | tonumber), item_id: $eitem}}' \
  > "$CACHE_DIR/state.json"

echo "release_url=$R_URL"
echo "release_number=$R_NUMBER"
echo "epic_url=$E_URL"
echo "epic_number=$E_NUMBER"
