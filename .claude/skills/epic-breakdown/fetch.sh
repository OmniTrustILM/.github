#!/usr/bin/env bash
# Populate cache/ with everything the epic-breakdown skill needs to plan and
# create sub-issues: issue templates, Project #5 field/option IDs, labels,
# repos, org issue-type IDs, and the methodics doc (authority for the Module
# taxonomy and the Complexity/Estimate heuristics).
#
# Idempotent. Atomic: writes to cache.tmp/, per-file renames on success.
# Aborts on any sub-step failure; a partial cache is never accepted.
#
# Dependencies: gh (scopes: repo, read:org, and read:project or project),
#               jq, python3 (or python) with PyYAML.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="$SKILL_DIR/cache"
TMP_DIR="$SKILL_DIR/cache.tmp"

# ORG, log, fail and resolve_python come from _common.sh.
SCRIPT_TAG="fetch"
# shellcheck source-path=SCRIPTDIR source=_common.sh
. "$SKILL_DIR/_common.sh"

# --- Auth + scope check ---
gh auth status >/dev/null 2>&1 || fail "gh not authenticated. Run: gh auth login"

SCOPES="$(gh auth status 2>&1 | grep -E 'Token scopes:' || true)"
have_scope() { printf '%s' "$SCOPES" | grep -qE "'$1'"; }
if [ -z "$SCOPES" ]; then
  log "warn: could not read token scopes (fine-grained or app token?); skipping scope check"
else
  MISSING=()
  have_scope 'repo'     || MISSING+=("repo")
  have_scope 'read:org' || MISSING+=("read:org")
  # 'project' (write) includes read; 'read:project' alone is enough to fetch.
  if ! have_scope 'project' && ! have_scope 'read:project'; then
    MISSING+=("project")
  fi
  if [ "${#MISSING[@]}" -gt 0 ]; then
    fail "token missing scope(s): ${MISSING[*]}. Run: gh auth refresh -s $(IFS=,; echo "${MISSING[*]}")
  (Creating/linking sub-issues and writing project fields needs the 'project' scope;
   'read:project' alone only supports the read-only preflight mode.)"
  fi
fi

command -v jq >/dev/null 2>&1 || fail "jq not found on PATH"
# PyYAML (not stdlib) is required to parse templates + labels.
resolve_python
"$PYTHON" -c 'import yaml' >/dev/null 2>&1 || fail "Python PyYAML is required to parse templates/labels. Run: $PYTHON -m pip install pyyaml"

# --- Prepare tmp dir (cleaned on any exit so an aborted run leaves no cache.tmp/) ---
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"
trap 'rm -rf "$TMP_DIR"' EXIT

# --- 1/6: Issue templates (Epic + child forms) ---
log "fetching issue templates"
TEMPLATE_REPO="$ORG/.github"
TEMPLATES_PATH=".github/ISSUE_TEMPLATE"
TEMPLATES_LIST=$(gh api "repos/$TEMPLATE_REPO/contents/$TEMPLATES_PATH" \
  --jq '[.[] | select(.type=="file" and (.name | endswith(".yml"))) | .name]')
echo "[]" > "$TMP_DIR/templates.json"
# Loop in the current shell (process substitution, not a pipe) so a failure in
# the body trips `set -e` immediately rather than being swallowed by a subshell.
while read -r tpl; do
  { [ -z "$tpl" ] || [ "$tpl" = "config.yml" ]; } && continue
  log "  - $tpl"
  RAW=$(gh api "repos/$TEMPLATE_REPO/contents/$TEMPLATES_PATH/$tpl" --jq '.content' | base64 -d)
  PARSED=$(printf '%s' "$RAW" | "$PYTHON" -c 'import sys, yaml, json; json.dump(yaml.safe_load(sys.stdin), sys.stdout)')
  jq --argjson new "$PARSED" --arg file "$tpl" '. + [($new + {_file: $file})]' \
    "$TMP_DIR/templates.json" > "$TMP_DIR/templates.json.new"
  mv "$TMP_DIR/templates.json.new" "$TMP_DIR/templates.json"
done < <(echo "$TEMPLATES_LIST" | jq -r '.[]' | tr -d '\r')
TEMPLATE_COUNT=$(jq 'length' "$TMP_DIR/templates.json")
log "  fetched $TEMPLATE_COUNT templates"
[ "$TEMPLATE_COUNT" -ge 8 ] || fail "expected at least 8 templates, got $TEMPLATE_COUNT"

# --- 2/6: Project #5 fields and option IDs ---
log "fetching project fields"
PROJECT_QUERY='query {
  organization(login: "'"$ORG"'") {
    projectV2(number: 5) {
      id title
      fields(first: 30) {
        nodes {
          ... on ProjectV2Field             { id name dataType }
          ... on ProjectV2SingleSelectField  { id name dataType options { id name } }
          ... on ProjectV2IterationField     { id name dataType }
        }
      }
    }
  }
}'
gh api graphql -f query="$PROJECT_QUERY" \
  --jq '.data.organization.projectV2 | {
    project_id: .id,
    project_title: .title,
    fields: (.fields.nodes | map(select(.id != null)) | map({
      key: .name, value: { id: .id, dataType: .dataType, options: ((.options // []) | map({ key: .name, value: .id }) | from_entries) }
    }) | from_entries)
  }' > "$TMP_DIR/project-fields.json"
PROJECT_ID=$(jq -r '.project_id' "$TMP_DIR/project-fields.json")
{ [ "$PROJECT_ID" != "null" ] && [ -n "$PROJECT_ID" ]; } || fail "failed to fetch project id (need read:project scope)"
FIELD_COUNT=$(jq '.fields | length' "$TMP_DIR/project-fields.json")
log "  project: $PROJECT_ID, fields: $FIELD_COUNT"
[ "$FIELD_COUNT" -ge 10 ] || fail "expected at least 10 fields, got $FIELD_COUNT"
# Assert the fields epic-breakdown writes are present and correctly typed.
jq -e '.fields.Complexity.options.Low and .fields.Estimate.dataType == "NUMBER" and .fields.Module.options.Core and .fields.Status.options.Planning' \
  "$TMP_DIR/project-fields.json" >/dev/null \
  || fail "project schema missing expected Complexity/Estimate/Module/Status fields"

# --- 3/6: Labels ---
log "fetching labels.yml"
gh api "repos/$ORG/.github/contents/templates/labels.yml" --jq '.content' | base64 -d \
  | "$PYTHON" -c 'import sys, yaml, json; json.dump([{"name": l["name"], "color": l.get("color"), "description": l.get("description")} for l in yaml.safe_load(sys.stdin)], sys.stdout)' \
  > "$TMP_DIR/labels.json"
LABEL_COUNT=$(jq 'length' "$TMP_DIR/labels.json")
log "  $LABEL_COUNT labels"
[ "$LABEL_COUNT" -ge 10 ] || fail "expected at least 10 labels, got $LABEL_COUNT"

# --- 4/6: Non-archived repos in the org (name + description) ---
log "fetching repo list"
# $endCursor is a GraphQL variable (resolved by gh --paginate), not a shell var,
# so the single-quoted query is intentional.
# shellcheck disable=SC2016
gh api graphql --paginate -f query='
  query($endCursor: String) {
    organization(login: "'"$ORG"'") {
      repositories(first: 100, after: $endCursor, isArchived: false) {
        nodes { name description }
        pageInfo { hasNextPage endCursor }
      }
    }
  }' --jq '.data.organization.repositories.nodes[]' \
  | jq -s '.' > "$TMP_DIR/repos.json"
REPO_COUNT=$(jq 'length' "$TMP_DIR/repos.json")
log "  $REPO_COUNT repos"
[ "$REPO_COUNT" -ge 30 ] || fail "expected at least 30 repos, got $REPO_COUNT"

# --- 5/6: Org issue types ---
log "fetching issue types"
gh api graphql -f query='query { organization(login: "'"$ORG"'") { issueTypes(first: 20) { nodes { id name } } } }' \
  --jq '.data.organization.issueTypes.nodes | map({key: .name, value: .id}) | from_entries' \
  > "$TMP_DIR/issue-types.json"
jq -e '.Epic and .Feature and .Task and .Bug' "$TMP_DIR/issue-types.json" >/dev/null \
  || fail "issue-types cache missing one of Epic/Feature/Task/Bug"
log "  $(jq 'length' "$TMP_DIR/issue-types.json") issue types"

# --- 6/6: Methodics (authority for Module taxonomy + Complexity/Estimate heuristics) ---
log "fetching methodics development-process.md"
METHODICS_REL="docs/development-process.md"
if REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) \
   && git -C "$REPO_ROOT" config --get remote.origin.url 2>/dev/null | grep -qiE "$ORG/\.github(\.git)?$" \
   && [ -f "$REPO_ROOT/$METHODICS_REL" ]; then
  log "  methodics: local clone"
  cp "$REPO_ROOT/$METHODICS_REL" "$TMP_DIR/development-process.md"
else
  log "  methodics: API"
  gh api "repos/$ORG/.github/contents/$METHODICS_REL" --jq '.content' | base64 -d > "$TMP_DIR/development-process.md"
fi
[ -s "$TMP_DIR/development-process.md" ] || fail "methodics fetch produced an empty file"

# --- Finalize: timestamp + per-file swap (Windows / Git-Bash safe) ---
date -u +"%Y-%m-%dT%H:%M:%SZ" > "$TMP_DIR/fetched-at.txt"
mkdir -p "$CACHE_DIR"
for f in "$TMP_DIR"/*.json "$TMP_DIR/development-process.md" "$TMP_DIR/fetched-at.txt"; do
  [ -f "$f" ] || continue
  mv -f "$f" "$CACHE_DIR/$(basename "$f")"
done
rm -rf "$TMP_DIR"
log "cache refreshed: $CACHE_DIR"
