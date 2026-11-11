#!/usr/bin/env bash
# Populate cache/ with Project #5 field IDs and org issue types.
#
# Idempotent. Atomic: writes to cache.tmp/, per-file rename on success.
# Aborts on any sub-step failure; partial cache is never accepted.
#
# Dependencies: gh (repo + read:project scope), jq.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="$SKILL_DIR/cache"
TMP_DIR="$SKILL_DIR/cache.tmp"

log() { echo "[fetch] $*" >&2; }

# --- Auth check ---
if ! gh auth status >/dev/null 2>&1; then
  echo "error: gh not authenticated. Run: gh auth login" >&2
  exit 1
fi
# Scope checks. An empty scopes line means a fine-grained PAT / GitHub App
# token whose scopes gh can't enumerate — skip and let the API enforce.
SCOPES_LINE=$(gh auth status 2>&1 | grep -E "Token scopes:" || true)
if [ -n "$SCOPES_LINE" ]; then
  if ! printf '%s' "$SCOPES_LINE" | grep -qE "'repo'"; then
    echo "error: token missing 'repo' scope. Run: gh auth refresh -s repo" >&2
    exit 1
  fi
  if ! printf '%s' "$SCOPES_LINE" | grep -qE "'(read:project|project)'"; then
    echo "error: token missing 'read:project' scope (needed to read Project #5 fields). Run: gh auth refresh -s read:project" >&2
    exit 1
  fi
fi

rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"
trap 'rm -rf "$TMP_DIR"' EXIT

# --- 1/2: Project #5 fields and option IDs ---
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
# The skill needs these fields to exist; fail loudly if the project changed.
for f in "Status" "Version" "Sprint" "Start Date" "End Date" "Prioritization"; do
  jq -e --arg f "$f" '.fields[$f].id' "$TMP_DIR/project-fields.json" >/dev/null \
    || { echo "error: Project #5 field '$f' not found" >&2; exit 1; }
done
log "  project: $PROJECT_ID"

# --- 2/2: Org issue types ---
log "fetching issue types"
gh api graphql -f query='query { organization(login: "OmniTrustILM") { issueTypes(first: 20) { nodes { id name } } } }' \
  --jq '.data.organization.issueTypes.nodes | map({key: .name, value: .id}) | from_entries' \
  > "$TMP_DIR/issue-types.json"
for t in "Release" "Epic"; do
  jq -e --arg t "$t" '.[$t]' "$TMP_DIR/issue-types.json" >/dev/null \
    || { echo "error: org issue type '$t' not found" >&2; exit 1; }
done

date -u +"%Y-%m-%dT%H:%M:%SZ" > "$TMP_DIR/fetched-at.txt"

# Per-file mv (atomic on one volume); the cache dir itself is never renamed.
mkdir -p "$CACHE_DIR"
for f in "$TMP_DIR"/*.json "$TMP_DIR/fetched-at.txt"; do
  [ -f "$f" ] || continue
  mv -f "$f" "$CACHE_DIR/$(basename "$f")"
done
rm -rf "$TMP_DIR"

log "cache refreshed: $CACHE_DIR"
