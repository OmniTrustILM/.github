#!/usr/bin/env bash
# Set the initial Status for a newly-added project item.
#   - Bug → Analysis (needs immediate triage)
#   - Everything else → Planning (future work)
#
# The built-in project workflow "Item added → Planning" also fires;
# this script overrides Bugs to Analysis after the add.
#
# Reads: GH_TOKEN, ISSUE_URL, ISSUE_TYPE, PROJECT_ID
set -euo pipefail

if [ "$ISSUE_TYPE" = "Bug" ]; then
  STATUS="Analysis"
else
  STATUS="Planning"
fi

echo "Issue type: ${ISSUE_TYPE:-unknown}"
echo "Setting status to: $STATUS"

# Wait briefly for the actions/add-to-project step to complete.
sleep 3

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

if [ -z "$ITEM_ID" ] || [ "$ITEM_ID" = "null" ]; then
  echo "::warning::Issue not found in project. It may not have been added yet."
  exit 0
fi

STATUS_FIELD=$(gh api graphql -f query='
  { organization(login: "OmnitrustILM") {
    projectV2(number: 5) {
      field(name: "Status") {
        ... on ProjectV2SingleSelectField {
          id
          options { id name }
        }
      }
    }
  } }' --jq '.data.organization.projectV2.field')

FIELD_ID=$(printf '%s' "$STATUS_FIELD" | jq -r '.id')
OPTION_ID=$(printf '%s' "$STATUS_FIELD" | jq -r --arg name "$STATUS" '.options[] | select(.name == $name) | .id')

if [ -z "$OPTION_ID" ] || [ "$OPTION_ID" = "null" ]; then
  echo "::warning::Status option '$STATUS' not found in project field."
  exit 0
fi

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
  -f fieldId="$FIELD_ID" \
  -f optionId="$OPTION_ID"

echo "Status set to $STATUS for issue $ISSUE_URL"
