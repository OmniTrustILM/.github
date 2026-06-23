#!/usr/bin/env bash
# Populate cache/*.json with templates, project field IDs, labels, repos.
#
# Idempotent. Atomic: writes to cache.tmp/, renames on success.
# Aborts on any sub-step failure; partial cache is never accepted.
#
# Env (none required):
#   FORCE=1   bypass freshness check (currently unused; reserved)
#
# Dependencies: gh (repo + read:project scope), jq, python3 (or python) with PyYAML.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="$SKILL_DIR/cache"
TMP_DIR="$SKILL_DIR/cache.tmp"

log() { echo "[fetch] $*" >&2; }

# Resolve one Python interpreter (python3 preferred); PyYAML (not stdlib) is
# required to parse the issue-template and labels YAML below.
PYTHON="$(command -v python3 || command -v python || true)"
[ -n "$PYTHON" ] || { echo "error: python3 (or python) not found on PATH" >&2; exit 1; }
"$PYTHON" -c 'import yaml' >/dev/null 2>&1 || {
  echo "error: Python PyYAML is required to parse YAML. Run: $PYTHON -m pip install pyyaml" >&2
  exit 1
}

# --- Auth check ---
if ! gh auth status >/dev/null 2>&1; then
  echo "error: gh not authenticated. Run: gh auth login" >&2
  exit 1
fi
# Scope checks. Capture the scopes line once; an empty line means a fine-grained
# PAT / GitHub App token whose scopes gh can't enumerate — skip and let the API
# enforce, rather than false-reject a valid token.
SCOPES_LINE=$(gh auth status 2>&1 | grep -E "Token scopes:" || true)
if [ -n "$SCOPES_LINE" ]; then
  if ! printf '%s' "$SCOPES_LINE" | grep -qE "'repo'"; then
    echo "error: token missing 'repo' scope. Run: gh auth refresh -s repo" >&2
    echo "  (note: 'public_repo' alone is not enough — internal/private repos in the org need 'repo')" >&2
    exit 1
  fi
  # Reading Project #5 fields below requires read:project (or project); without it
  # the GraphQL field fetch fails with an opaque INSUFFICIENT_SCOPES error.
  if ! printf '%s' "$SCOPES_LINE" | grep -qE "'(read:project|project)'"; then
    echo "error: token missing 'read:project' scope (needed to read Project #5 fields). Run: gh auth refresh -s read:project" >&2
    exit 1
  fi
fi

# --- Prepare tmp dir (cleaned on any exit so an aborted run leaves no cache.tmp/) ---
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"
trap 'rm -rf "$TMP_DIR"' EXIT

# --- Sub-steps populate $TMP_DIR/*.json ---
# (added in subsequent tasks)

# --- 1/4: Issue templates ---
log "fetching templates from .github/ISSUE_TEMPLATE"
TEMPLATES_PATH=".github/ISSUE_TEMPLATE"
TEMPLATE_REPO="OmniTrustILM/.github"

# List the files in the template directory
TEMPLATES_LIST=$(gh api "repos/$TEMPLATE_REPO/contents/$TEMPLATES_PATH" \
  --jq '[.[] | select(.type=="file" and (.name | endswith(".yml"))) | .name]')

# Fetch each .yml file, parse to JSON, accumulate into one array
echo "[]" > "$TMP_DIR/templates.json"
# Loop in the current shell (process substitution, not a pipe) so a gh/jq/python
# failure inside the body trips `set -e` immediately instead of being swallowed
# by a subshell and only surfacing later as a misleading count assertion.
while read -r tpl; do
  if [ -z "$tpl" ] || [ "$tpl" = "config.yml" ]; then
    # config.yml is the issue template config (contact links), not a template
    continue
  fi
  log "  - $tpl"
  RAW=$(gh api "repos/$TEMPLATE_REPO/contents/$TEMPLATES_PATH/$tpl" --jq '.content' | base64 -d)
  PARSED=$(echo "$RAW" | "$PYTHON" -c 'import sys, yaml, json; json.dump(yaml.safe_load(sys.stdin), sys.stdout)')
  # Append parsed template to templates.json
  jq --argjson new "$PARSED" --arg file "$tpl" \
    '. + [($new + {_file: $file})]' "$TMP_DIR/templates.json" > "$TMP_DIR/templates.json.new"
  mv "$TMP_DIR/templates.json.new" "$TMP_DIR/templates.json"
done < <(echo "$TEMPLATES_LIST" | jq -r '.[]' | tr -d '\r')

TEMPLATE_COUNT=$(jq 'length' "$TMP_DIR/templates.json")
log "  fetched $TEMPLATE_COUNT templates"
[ "$TEMPLATE_COUNT" -ge 8 ] || { echo "error: expected at least 8 templates, got $TEMPLATE_COUNT" >&2; exit 1; }

# --- 2/4: Project #5 fields and option IDs ---
log "fetching project fields"
PROJECT_QUERY='query {
  organization(login: "OmniTrustILM") {
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
[ "$PROJECT_ID" != "null" ] && [ -n "$PROJECT_ID" ] || { echo "error: failed to fetch project id" >&2; exit 1; }
FIELD_COUNT=$(jq '.fields | length' "$TMP_DIR/project-fields.json")
log "  project: $PROJECT_ID, fields: $FIELD_COUNT"
[ "$FIELD_COUNT" -ge 10 ] || { echo "error: expected at least 10 fields, got $FIELD_COUNT" >&2; exit 1; }

# --- 3/4: Labels (from labels.yml in .github repo) ---
log "fetching labels.yml"
gh api "repos/OmniTrustILM/.github/contents/templates/labels.yml" --jq '.content' | base64 -d \
  | "$PYTHON" -c 'import sys, yaml, json; json.dump([{"name": l["name"], "color": l.get("color"), "description": l.get("description")} for l in yaml.safe_load(sys.stdin)], sys.stdout)' \
  > "$TMP_DIR/labels.json"
LABEL_COUNT=$(jq 'length' "$TMP_DIR/labels.json")
log "  $LABEL_COUNT labels"
[ "$LABEL_COUNT" -ge 10 ] || { echo "error: expected at least 10 labels, got $LABEL_COUNT" >&2; exit 1; }

# --- 4/4: Non-archived repos in the org ---
log "fetching repo list"
# Note: gh repo list defaults to public-only when --visibility is omitted.
# Fetch all visibilities (public, internal, private) and merge.
gh api graphql --paginate -f query='
  query($endCursor: String) {
    organization(login: "OmniTrustILM") {
      repositories(first: 100, after: $endCursor, isArchived: false) {
        nodes { name description }
        pageInfo { hasNextPage endCursor }
      }
    }
  }' --jq '.data.organization.repositories.nodes[]' \
  | jq -s '.' > "$TMP_DIR/repos.json"
REPO_COUNT=$(jq 'length' "$TMP_DIR/repos.json")
log "  $REPO_COUNT repos"
[ "$REPO_COUNT" -ge 30 ] || { echo "error: expected at least 30 repos, got $REPO_COUNT" >&2; exit 1; }

# --- 5/5: Org issue types ---
log "fetching issue types"
gh api graphql -f query='query { organization(login: "OmniTrustILM") { issueTypes(first: 20) { nodes { id name } } } }' \
  --jq '.data.organization.issueTypes.nodes | map({key: .name, value: .id}) | from_entries' \
  > "$TMP_DIR/issue-types.json"
ITYPE_COUNT=$(jq 'length' "$TMP_DIR/issue-types.json")
log "  $ITYPE_COUNT issue types"
[ "$ITYPE_COUNT" -ge 4 ] || { echo "error: expected at least 4 issue types, got $ITYPE_COUNT" >&2; exit 1; }

# --- Finalize: timestamp + per-file swap (Windows-compatible) ---
date -u +"%Y-%m-%dT%H:%M:%SZ" > "$TMP_DIR/fetched-at.txt"

# Per-file mv avoids `Device or resource busy` errors that fire on Windows /
# Git Bash when another process holds a handle on the cache directory (cwd
# of a parent shell, AV scanner, indexer). Each file is moved individually;
# mv on a single file inside the same volume is atomic. The cache dir
# itself is never renamed, so no whole-cache-loss kill window exists.
mkdir -p "$CACHE_DIR"
for f in "$TMP_DIR"/*.json "$TMP_DIR/fetched-at.txt"; do
  [ -f "$f" ] || continue
  mv -f "$f" "$CACHE_DIR/$(basename "$f")"
done
rm -rf "$TMP_DIR"

log "cache refreshed: $CACHE_DIR"
