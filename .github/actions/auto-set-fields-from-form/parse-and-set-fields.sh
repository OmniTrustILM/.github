#!/usr/bin/env bash
# Parse structured form data from Bug/Vulnerability/Release templates
# and set the corresponding project custom fields.
#
# Fields parsed:
#   - Severity (Bug, Vulnerability)
#   - Module (Bug, optional)
#   - Version Number (Release)
#
# Vulnerability defaults (when `vulnerability` label present):
#   - Severity → Critical (if reporter didn't set it)
#   - Priority → High (if empty)
#
# Defensive: if extraction fails, fields are left empty. The triage
# skill catches missing fields later.
#
# Reads: GH_TOKEN, ISSUE_BODY, ISSUE_URL, ISSUE_LABELS, PROJECT_ID
set -euo pipefail

# GitHub YAML forms render as: ### Field Label\n\n(blank)\nValue.
# grep -A2 captures heading + blank + value; tail -1 extracts the value.
# "_No response_" means user skipped an optional field.
SEVERITY=$(printf '%s\n' "$ISSUE_BODY" | grep -A2 '### Severity' | tail -1 | xargs 2>/dev/null || echo "")
MODULE=$(printf '%s\n' "$ISSUE_BODY" | grep -A2 '### Module' | tail -1 | xargs 2>/dev/null || echo "")
VERSION=$(printf '%s\n' "$ISSUE_BODY" | grep -A2 '### Version Number' | tail -1 | xargs 2>/dev/null || echo "")

[ "$SEVERITY" = "_No response_" ] && SEVERITY=""
[ "$MODULE" = "_No response_" ] && MODULE=""
[ "$VERSION" = "_No response_" ] && VERSION=""

# Vulnerability defaults.
# ISSUE_LABELS is comma-joined by the workflow; wrap the haystack and
# needle in commas to avoid matching labels like "not-a-vulnerability".
PRIORITY=""
if printf '%s' ",$ISSUE_LABELS," | grep -q ",vulnerability,"; then
  if [ -z "$SEVERITY" ]; then
    SEVERITY="Critical"
    echo "Vulnerability without Severity — defaulting to Critical"
  fi
  PRIORITY="High"
  echo "Vulnerability — defaulting Priority to High"
fi

echo "Parsed — Severity: ${SEVERITY:-empty}, Module: ${MODULE:-empty}, Version: ${VERSION:-empty}, Priority: ${PRIORITY:-empty}"

if [ -z "$SEVERITY" ] && [ -z "$MODULE" ] && [ -z "$PRIORITY" ] && [ -z "$VERSION" ]; then
  echo "No fields to set, exiting."
  exit 0
fi

# Poll for the project item. Races auto-add-to-project in a separate
# workflow run; 10s ceiling (5 × 2s) accommodates scheduling lag.
ITEM_ID=""
for i in {1..5}; do
  ITEMS_JSON=$(gh api graphql -f query='
    query($url: URI!) {
      resource(url: $url) {
        ... on Issue {
          projectItems(first: 10) {
            nodes {
              id
              project { id }
            }
          }
        }
      }
    }' -f url="$ISSUE_URL")

  ITEM_ID=$(printf '%s' "$ITEMS_JSON" | jq -r --arg pid "$PROJECT_ID" \
    '.data.resource.projectItems.nodes[] | select(.project.id == $pid) | .id')

  if [ -n "$ITEM_ID" ] && [ "$ITEM_ID" != "null" ]; then
    break
  fi
  [ "$i" -lt 5 ] && sleep 2
done

if [ -z "$ITEM_ID" ] || [ "$ITEM_ID" = "null" ]; then
  echo "::warning::Issue not yet in project after polling, skipping field set."
  exit 0
fi

set_field() {
  local field_name=$1
  local value=$2

  if [ -z "$value" ]; then
    return
  fi

  local field_data
  field_data=$(gh api graphql -f query='
    query($field_name: String!) {
      organization(login: "OmniTrustILM") {
        projectV2(number: 5) {
          field(name: $field_name) {
            ... on ProjectV2SingleSelectField {
              id
              options { id name }
            }
          }
        }
      }
    }' -f field_name="$field_name" \
    --jq '.data.organization.projectV2.field')

  local field_id
  field_id=$(printf '%s' "$field_data" | jq -r '.id')
  local option_id
  option_id=$(printf '%s' "$field_data" | jq -r --arg name "$value" '.options[] | select(.name == $name) | .id')

  if [ -n "$option_id" ] && [ "$option_id" != "null" ]; then
    gh api graphql -f query='
      mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $optionId: String!) {
        updateProjectV2ItemFieldValue(input: {
          projectId: $projectId
          itemId: $itemId
          fieldId: $fieldId
          value: { singleSelectOptionId: $optionId }
        }) {
          projectV2Item { id }
        }
      }' \
      -f projectId="$PROJECT_ID" \
      -f itemId="$ITEM_ID" \
      -f fieldId="$field_id" \
      -f optionId="$option_id"
    echo "Set $field_name to $value"
  else
    echo "::warning::Could not find option '$value' for field '$field_name' — skipping."
  fi
}

set_field "Severity" "$SEVERITY"
set_field "Module" "$MODULE"
set_field "Priority" "$PRIORITY"
set_field "Version" "$VERSION"
