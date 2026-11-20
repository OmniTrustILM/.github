#!/usr/bin/env bash
# Gather live state (latest release, its window, Sprint iterations, Version
# options) and compute the release plan via plan.py.
#
# Usage:
#   plan.sh [--version X.Y.Z]        plan the next release after the latest 2.x
#   plan.sh --sprints-only X.Y.Z     plan sprints for an EXISTING release
#
# Writes cache/live.json and cache/plan.json; prints plan.json to stdout.
# Read-only: performs no mutations.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="$SKILL_DIR/cache"

log()  { echo "[plan] $*" >&2; }
fail() { echo "error: $*" >&2; exit 1; }

PYTHON="$(command -v python3 || command -v python || true)"
[ -n "$PYTHON" ] || fail "python3 (or python) not found on PATH"

for f in project-fields.json issue-types.json; do
  [ -f "$CACHE_DIR/$f" ] || fail "missing $CACHE_DIR/$f — run fetch.sh first"
done

VERSION="" SPRINTS_ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --version)      VERSION="$2"; shift 2 ;;
    --sprints-only) SPRINTS_ONLY="$2"; shift 2 ;;
    *)              fail "unknown arg: $1" ;;
  esac
done

# --- Live Sprint iterations (active + completed) and Version options ---
# Read live, not from cache: both change outside this skill and staleness
# here would produce wrong trims or a false "option missing" result.
SPRINT_FIELD_ID=$(jq -r '.fields["Sprint"].id' "$CACHE_DIR/project-fields.json")
VERSION_FIELD_ID=$(jq -r '.fields["Version"].id' "$CACHE_DIR/project-fields.json")

log "fetching live Sprint iterations and Version options"
LIVE_FIELDS=$(gh api graphql \
  -f query='query($sprintId: ID!, $versionId: ID!) {
    sprint: node(id: $sprintId) { ... on ProjectV2IterationField {
      configuration {
        iterations { title startDate duration }
        completedIterations { title startDate duration }
      }
    } }
    version: node(id: $versionId) { ... on ProjectV2SingleSelectField {
      options { id name }
    } }
  }' -f sprintId="$SPRINT_FIELD_ID" -f versionId="$VERSION_FIELD_ID") \
  || fail "failed to fetch live field state"

echo "$LIVE_FIELDS" | jq '{
  iterations: (.data.sprint.configuration | (.iterations + .completedIterations)),
  version_options: (.data.version.options | map({key: .name, value: .id}) | from_entries)
}' > "$CACHE_DIR/live.json"

# --- Release issues (open, type Release, semver title) in the ilm repo ---
# Search (not repository.issues): releases are old issues that fall outside
# any first-N-by-created-at page of a busy repo.
log "fetching open Release issues from OmniTrustILM/ilm"
RELEASES=$(gh api graphql \
  -f query='query {
    search(query: "repo:OmniTrustILM/ilm is:issue is:open type:Release", type: ISSUE, first: 50) {
      nodes {
        ... on Issue {
          number title issueType { name }
          projectItems(first: 5) { nodes {
            project { number }
            fieldValues(first: 20) { nodes {
              ... on ProjectV2ItemFieldDateValue {
                field { ... on ProjectV2FieldCommon { name } } date
              }
            } }
          } }
        }
      }
    }
  }' --jq '[.data.search.nodes[]
    | select(.issueType.name == "Release")
    | select(.title | test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))
    | {number, title,
       start: (first(.projectItems.nodes[] | select(.project.number == 5)) // {fieldValues: {nodes: []}}
               | .fieldValues.nodes | map(select(.field.name? == "Start Date")) | first | .date // null),
       end:   (first(.projectItems.nodes[] | select(.project.number == 5)) // {fieldValues: {nodes: []}}
               | .fieldValues.nodes | map(select(.field.name? == "End Date")) | first | .date // null)}]') \
  || fail "failed to fetch release issues"

PLAN_ARGS=(--iterations-json /dev/stdin)

if [ -n "$SPRINTS_ONLY" ]; then
  ROW=$(echo "$RELEASES" | jq --arg v "$SPRINTS_ONLY" '[.[] | select(.title == $v)] | first')
  [ "$ROW" != "null" ] || fail "no open Release issue titled '$SPRINTS_ONLY' found in ilm"
  START=$(echo "$ROW" | jq -r '.start // empty')
  END=$(echo "$ROW" | jq -r '.end // empty')
  [ -n "$START" ] && [ -n "$END" ] \
    || fail "release $SPRINTS_ONLY has no Start Date/End Date in Project #5 — set them first"
  log "existing release $SPRINTS_ONLY: $START .. $END"
  PLAN_ARGS+=(--version "$SPRINTS_ONLY" --start "$START" --end "$END")
else
  # Latest 2.x by semver. New releases stay in the 2.x line for now (PM,
  # 2026-09-08) — the unplanned 3.0.0 must not become the bump base.
  PREV=$(echo "$RELEASES" | jq '[.[] | select(.title | startswith("2."))]
    | sort_by(.title | split(".") | map(tonumber)) | last')
  [ "$PREV" != "null" ] || fail "no open 2.x Release issue found in ilm"
  PREV_VERSION=$(echo "$PREV" | jq -r '.title')
  PREV_END=$(echo "$PREV" | jq -r '.end // empty')
  [ -n "$PREV_END" ] || fail "latest release $PREV_VERSION has no End Date in Project #5 — set it first"
  log "previous release: $PREV_VERSION (ends $PREV_END)"
  PLAN_ARGS+=(--prev-version "$PREV_VERSION" --prev-end "$PREV_END")
  [ -n "$VERSION" ] && PLAN_ARGS+=(--version "$VERSION")
fi

jq '.iterations' "$CACHE_DIR/live.json" \
  | "$PYTHON" "$SKILL_DIR/plan.py" "${PLAN_ARGS[@]}" > "$CACHE_DIR/plan.json" \
  || fail "plan.py failed"

# Flag whether the Version option already exists (manual UI step if not).
PLAN_VERSION=$(jq -r '.version' "$CACHE_DIR/plan.json")
OPTION_EXISTS=$(jq --arg v "$PLAN_VERSION" '.version_options | has($v)' "$CACHE_DIR/live.json")
jq --argjson e "$OPTION_EXISTS" '. + {version_option_exists: $e}' "$CACHE_DIR/plan.json" \
  > "$CACHE_DIR/plan.json.new" && mv "$CACHE_DIR/plan.json.new" "$CACHE_DIR/plan.json"

log "plan written to $CACHE_DIR/plan.json"
cat "$CACHE_DIR/plan.json"
