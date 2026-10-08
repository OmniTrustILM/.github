#!/usr/bin/env bash
# Verify the manual UI steps of the release plan and finish the field setup:
#   - re-reads live Sprint iterations and Version options,
#   - checks every planned sprint (and trim) against the live configuration,
#   - once the Version option exists, sets Version on the release and epic
#     items recorded in cache/state.json (skipped in sprints-only runs).
#
# Exit 0 when everything matches; exit 2 when steps are still missing
# (the report on stdout lists exactly which).
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="$SKILL_DIR/cache"

log()  { echo "[verify] $*" >&2; }
fail() { echo "error: $*" >&2; exit 1; }

for f in plan.json project-fields.json; do
  [ -f "$CACHE_DIR/$f" ] || fail "missing $CACHE_DIR/$f — run fetch.sh and plan.sh first"
done

VERSION=$(jq -r '.version' "$CACHE_DIR/plan.json")
PROJECT_ID=$(jq -r '.project_id' "$CACHE_DIR/project-fields.json")
SPRINT_FIELD_ID=$(jq -r '.fields["Sprint"].id' "$CACHE_DIR/project-fields.json")
VERSION_FIELD_ID=$(jq -r '.fields["Version"].id' "$CACHE_DIR/project-fields.json")

log "re-reading live Sprint iterations and Version options"
LIVE=$(gh api graphql \
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

ITERATIONS=$(echo "$LIVE" | jq '.data.sprint.configuration | (.iterations + .completedIterations)')
VERSION_OPT=$(echo "$LIVE" | jq -r --arg v "$VERSION" \
  '.data.version.options | map(select(.name == $v)) | first | .id // ""')

INCOMPLETE=0

# --- Version option + issue fields ---
if [ -n "$VERSION_OPT" ]; then
  echo "OK       Version option '$VERSION' exists"
  if [ -f "$CACHE_DIR/state.json" ] \
     && [ "$(jq -r '.version' "$CACHE_DIR/state.json")" = "$VERSION" ]; then
    for role in release epic; do
      ITEM=$(jq -r --arg r "$role" '.[$r].item_id' "$CACHE_DIR/state.json")
      NUM=$(jq -r --arg r "$role" '.[$r].number' "$CACHE_DIR/state.json")
      if gh api graphql -f query='mutation($p: ID!, $i: ID!, $f: ID!, $o: String!) {
            updateProjectV2ItemFieldValue(input: {projectId: $p, itemId: $i, fieldId: $f, value: {singleSelectOptionId: $o}}) { projectV2Item { id } }
          }' -f p="$PROJECT_ID" -f i="$ITEM" -f f="$VERSION_FIELD_ID" -f o="$VERSION_OPT" >/dev/null; then
        echo "OK       Version=$VERSION set on $role #$NUM"
      else
        echo "FAILED   could not set Version on $role #$NUM"
        INCOMPLETE=1
      fi
    done
  fi
else
  echo "MISSING  Version option '$VERSION' — add it to the Version field in the Project #5 UI"
  INCOMPLETE=1
fi

# --- Planned sprints ---
while IFS=$'\t' read -r title start dur end; do
  STATUS=$(echo "$ITERATIONS" | jq -r --arg t "$title" --arg s "$start" --argjson d "$dur" '
    map(select(.title == $t)) | first
    | if . == null then "MISSING"
      elif .startDate == $s and .duration == $d then "OK"
      else "MISMATCH \(.startDate) +\(.duration)d" end')
  case "$STATUS" in
    OK) echo "OK       $title  $start +${dur}d (ends $end)" ;;
    MISSING) echo "MISSING  $title  $start +${dur}d (ends $end)"; INCOMPLETE=1 ;;
    *) echo "MISMATCH $title  planned $start +${dur}d, live is ${STATUS#MISMATCH }"; INCOMPLETE=1 ;;
  esac
done < <(jq -r '.sprints[] | [.title, .start_date, (.duration | tostring), .end_date] | @tsv' "$CACHE_DIR/plan.json")

# --- Trims of overhanging iterations ---
while IFS=$'\t' read -r title start newdur newend; do
  STATUS=$(echo "$ITERATIONS" | jq -r --arg t "$title" --arg s "$start" --argjson d "$newdur" '
    map(select(.title == $t)) | first
    | if . == null then "GONE"
      elif .startDate == $s and .duration == $d then "OK"
      else "PENDING \(.startDate) +\(.duration)d" end')
  case "$STATUS" in
    OK) echo "OK       trim: $title now ends $newend" ;;
    GONE) echo "MISSING  trim: iteration '$title' no longer exists"; INCOMPLETE=1 ;;
    *) echo "PENDING  trim: $title should end $newend (set duration ${newdur}d); live is ${STATUS#PENDING }"; INCOMPLETE=1 ;;
  esac
done < <(jq -r '.trims[] | [.title, .start_date, (.new_duration | tostring), .new_end] | @tsv' "$CACHE_DIR/plan.json")

if [ "$INCOMPLETE" -eq 0 ]; then
  echo "result=complete"
  exit 0
else
  echo "result=incomplete"
  exit 2
fi
