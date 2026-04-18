#!/usr/bin/env bash
# Generate a weekly project health report as a Markdown artifact.
#
# Evaluates open issues in Project #5 against triage rules:
# - Missing required fields (Severity, AC, etc.)
# - Staleness (issues stuck in a status past threshold)
# - Status and Version distribution
#
# Report only — does not auto-fix anything. The /project-triage skill
# provides the interactive version with auto-fix offers.
#
# Reads: GH_TOKEN
# Requires: yq, gh, jq on PATH. Run from repo root (reads
#           config/project-triage-rules.yml).
# Writes: report.md in the current directory.
set -euo pipefail

REPORT="report.md"
{
  echo "# Project Health Report — $(date -u +%Y-%m-%d)"
  echo ""
  echo "Generated at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo ""
} > "$REPORT"

# --- Fetch all project items (paginated) ---
echo "Fetching project items..."
ALL_ITEMS="[]"
HAS_NEXT=true
CURSOR=""

while [ "$HAS_NEXT" = "true" ]; do
  if [ -n "$CURSOR" ]; then
    RESULT=$(gh api graphql -F cursor="$CURSOR" -f query='
      query($cursor: String!) {
        organization(login: "OmnitrustILM") {
          projectV2(number: 5) {
            items(first: 100, after: $cursor) {
              nodes {
                content {
                  ... on Issue {
                    number title url state
                    repository { name }
                    createdAt
                    assignees(first: 3) { nodes { login } }
                    issueType { name }
                  }
                }
                fieldValues(first: 20) {
                  nodes {
                    ... on ProjectV2ItemFieldSingleSelectValue {
                      field { ... on ProjectV2SingleSelectField { name } }
                      name
                    }
                    ... on ProjectV2ItemFieldNumberValue {
                      field { ... on ProjectV2Field { name } }
                      number
                    }
                  }
                }
              }
              pageInfo { hasNextPage endCursor }
            }
          }
        }
      }')
  else
    RESULT=$(gh api graphql -f query='
      {
        organization(login: "OmnitrustILM") {
          projectV2(number: 5) {
            items(first: 100) {
              nodes {
                content {
                  ... on Issue {
                    number title url state
                    repository { name }
                    createdAt
                    assignees(first: 3) { nodes { login } }
                    issueType { name }
                  }
                }
                fieldValues(first: 20) {
                  nodes {
                    ... on ProjectV2ItemFieldSingleSelectValue {
                      field { ... on ProjectV2SingleSelectField { name } }
                      name
                    }
                    ... on ProjectV2ItemFieldNumberValue {
                      field { ... on ProjectV2Field { name } }
                      number
                    }
                  }
                }
              }
              pageInfo { hasNextPage endCursor }
            }
          }
        }
      }')
  fi

  PAGE_ITEMS=$(printf '%s' "$RESULT" | jq '.data.organization.projectV2.items.nodes')
  ALL_ITEMS=$(printf '%s %s' "$ALL_ITEMS" "$PAGE_ITEMS" | jq -s 'add')

  HAS_NEXT=$(printf '%s' "$RESULT" | jq -r '.data.organization.projectV2.items.pageInfo.hasNextPage')
  CURSOR=$(printf '%s' "$RESULT" | jq -r '.data.organization.projectV2.items.pageInfo.endCursor')
done

OPEN_ITEMS=$(printf '%s' "$ALL_ITEMS" | jq '[.[] | select(.content.state == "OPEN")]')
TOTAL=$(printf '%s' "$OPEN_ITEMS" | jq 'length')
echo "Total open issues: $TOTAL"

{
  echo "## Summary"
  echo ""
  echo "Total open issues in Project #5: **$TOTAL**"
  echo ""
  echo "## Status Distribution"
  echo ""
  echo "| Status | Count |"
  echo "|---|---|"
  printf '%s' "$OPEN_ITEMS" | jq -r '
    [.[] | .fieldValues.nodes[] | select(.field.name == "Status") | .name]
    | group_by(.) | map({status: .[0], count: length})
    | sort_by(.status)
    | .[] | "| \(.status) | \(.count) |"'
  echo ""
  echo "## Version Distribution"
  echo ""
  echo "| Version | Count |"
  echo "|---|---|"
  printf '%s' "$OPEN_ITEMS" | jq -r '
    [.[] | (.fieldValues.nodes[] | select(.field.name == "Version") | .name) // "Unversioned"]
    | group_by(.) | map({version: .[0], count: length})
    | sort_by(.version)
    | .[] | "| \(.version) | \(.count) |"'
  echo ""
  echo "## Missing Required Fields (Errors)"
  echo ""
} >> "$REPORT"

# Extract a single-select field value from an item JSON blob.
get_field() {
  printf '%s' "$1" | jq -r --arg name "$2" '.fieldValues.nodes[] | select(.field.name == $name) | .name // empty'
}

ERRORS=0
WARNINGS=0

while IFS= read -r item; do
  ISSUE_TYPE=$(printf '%s' "$item" | jq -r '.content.issueType.name // "unknown"')
  REPO=$(printf '%s' "$item" | jq -r '.content.repository.name // "?"')
  NUM=$(printf '%s' "$item" | jq -r '.content.number // "?"')
  TITLE=$(printf '%s' "$item" | jq -r '.content.title // "?" | .[0:60]')
  STATUS=$(get_field "$item" "Status")

  if [ "$ISSUE_TYPE" = "Bug" ]; then
    SEVERITY=$(get_field "$item" "Severity")
    if [ -z "$SEVERITY" ]; then
      echo "- **$REPO#$NUM** — Bug missing Severity — $TITLE" >> "$REPORT"
      ERRORS=$((ERRORS + 1))
    fi
  fi

  if [ "$ISSUE_TYPE" = "Release" ]; then
    VERSION=$(get_field "$item" "Version")
    if [ -z "$VERSION" ]; then
      echo "- **$REPO#$NUM** — Release missing Version — $TITLE" >> "$REPORT"
      ERRORS=$((ERRORS + 1))
    fi
  fi

  if [ "$ISSUE_TYPE" = "Epic" ] && [ "$STATUS" != "Planning" ]; then
    COMPLEXITY=$(get_field "$item" "Complexity")
    if [ -z "$COMPLEXITY" ]; then
      echo "- **$REPO#$NUM** — Epic past Planning missing Complexity — $TITLE" >> "$REPORT"
      ERRORS=$((ERRORS + 1))
    fi
  fi
done < <(printf '%s' "$OPEN_ITEMS" | jq -c '.[]')

{
  echo ""
  echo "## Staleness Warnings"
  echo ""
} >> "$REPORT"

# Default to 0 if a threshold key is missing — avoids bash -gt crash.
PLANNING_DAYS=$(yq eval '.staleness_thresholds.planning_days // 0' config/project-triage-rules.yml)
ANALYSIS_DAYS=$(yq eval '.staleness_thresholds.analysis_days // 0' config/project-triage-rules.yml)
OPEN_ASSIGNED_DAYS=$(yq eval '.staleness_thresholds.open_assigned_days // 0' config/project-triage-rules.yml)
OPEN_UNASSIGNED_DAYS=$(yq eval '.staleness_thresholds.open_unassigned_days // 0' config/project-triage-rules.yml)
IN_PROGRESS_DAYS=$(yq eval '.staleness_thresholds.in_progress_days // 0' config/project-triage-rules.yml)
REVIEW_DAYS=$(yq eval '.staleness_thresholds.review_days // 0' config/project-triage-rules.yml)
TESTING_DAYS=$(yq eval '.staleness_thresholds.testing_days // 0' config/project-triage-rules.yml)

NOW=$(date -u +%s)

while IFS= read -r item; do
  REPO=$(printf '%s' "$item" | jq -r '.content.repository.name // "?"')
  NUM=$(printf '%s' "$item" | jq -r '.content.number // "?"')
  TITLE=$(printf '%s' "$item" | jq -r '.content.title // "?" | .[0:60]')
  CREATED=$(printf '%s' "$item" | jq -r '.content.createdAt // empty')
  STATUS=$(get_field "$item" "Status")
  ASSIGNEES=$(printf '%s' "$item" | jq -r '.content.assignees.nodes[].login // empty' 2>/dev/null || :)

  if [ -z "$CREATED" ]; then
    continue
  fi

  CREATED_TS=$(date -u -d "$CREATED" +%s 2>/dev/null || echo "0")
  AGE_DAYS=$(( (NOW - CREATED_TS) / 86400 ))

  THRESHOLD=0
  case "$STATUS" in
    Planning) THRESHOLD=$PLANNING_DAYS ;;
    Analysis) THRESHOLD=$ANALYSIS_DAYS ;;
    Open)
      if [ -n "$ASSIGNEES" ]; then
        THRESHOLD=$OPEN_ASSIGNED_DAYS
      else
        THRESHOLD=$OPEN_UNASSIGNED_DAYS
      fi
      ;;
    "In Progress") THRESHOLD=$IN_PROGRESS_DAYS ;;
    Review) THRESHOLD=$REVIEW_DAYS ;;
    Testing) THRESHOLD=$TESTING_DAYS ;;
  esac

  if [ "$THRESHOLD" -gt 0 ] && [ "$AGE_DAYS" -gt "$THRESHOLD" ]; then
    echo "- **$REPO#$NUM** — In $STATUS for ~${AGE_DAYS}d (threshold: ${THRESHOLD}d) — $TITLE" >> "$REPORT"
    WARNINGS=$((WARNINGS + 1))
  fi
done < <(printf '%s' "$OPEN_ITEMS" | jq -c '.[]')

{
  echo ""
  echo "---"
  echo ""
  echo "*Report generated by project-health-report.yml*"
} >> "$REPORT"

echo "Report generated: $(wc -l < "$REPORT") lines. Errors: $ERRORS, warnings: $WARNINGS."
