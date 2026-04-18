#!/usr/bin/env bash
# When a new issue is created, check if it has a parent issue and
# copy Version and Module from parent to child — but only if the
# child's fields are empty. Never overrides existing values.
#
# Creation-time only: if the parent's fields change later, children
# are NOT auto-updated. The /project-triage skill catches drift.
#
# Reads: GH_TOKEN, ISSUE_URL, PROJECT_ID
set -euo pipefail

echo "Issue: $ISSUE_URL"

# Check the parent relationship first (doesn't depend on project membership).
PARENT_URL=$(gh api graphql -f query='
  query($url: URI!) {
    resource(url: $url) {
      ... on Issue {
        parent { url }
      }
    }
  }' -f url="$ISSUE_URL" \
  --jq '.data.resource.parent.url // empty')

if [ -z "$PARENT_URL" ]; then
  echo "No parent issue — nothing to propagate."
  exit 0
fi

echo "Parent: $PARENT_URL"

# Fetch project item data (id + field values) for a given issue URL.
get_project_item() {
  local url=$1
  local json
  json=$(gh api graphql -f query='
    query($url: URI!) {
      resource(url: $url) {
        ... on Issue {
          projectItems(first: 10) {
            nodes {
              id
              project { id }
              fieldValues(first: 20) {
                nodes {
                  ... on ProjectV2ItemFieldSingleSelectValue {
                    field { ... on ProjectV2SingleSelectField { name } }
                    name
                    optionId
                  }
                }
              }
            }
          }
        }
      }
    }' -f url="$url")
  printf '%s' "$json" | jq --arg pid "$PROJECT_ID" \
    '.data.resource.projectItems.nodes[] | select(.project.id == $pid)'
}

# The parent issue is pre-existing and should already be in the project.
PARENT_ITEM=$(get_project_item "$PARENT_URL")

# The child was just created; poll until auto-add-to-project (running
# in a separate workflow run) has added it to the project. 10s
# ceiling (5 × 2s) accommodates scheduling lag.
CHILD_ITEM=""
CHILD_ITEM_ID=""
for i in {1..5}; do
  CHILD_ITEM=$(get_project_item "$ISSUE_URL")
  CHILD_ITEM_ID=$(printf '%s' "$CHILD_ITEM" | jq -r '.id // empty')
  if [ -n "$CHILD_ITEM_ID" ]; then
    break
  fi
  [ "$i" -lt 5 ] && sleep 2
done

if [ -z "$CHILD_ITEM_ID" ]; then
  echo "::warning::Child issue not found in project after polling. It may not have been added yet."
  exit 0
fi

if [ -z "$PARENT_ITEM" ]; then
  echo "::warning::Parent issue not found in project."
  exit 0
fi

for field_name in "Version" "Module"; do
  parent_option_id=$(printf '%s' "$PARENT_ITEM" | jq -r \
    --arg fname "$field_name" \
    '.fieldValues.nodes[] | select(.field.name == $fname) | .optionId // empty')

  child_option_id=$(printf '%s' "$CHILD_ITEM" | jq -r \
    --arg fname "$field_name" \
    '.fieldValues.nodes[] | select(.field.name == $fname) | .optionId // empty')

  # Only copy if parent has a value and child doesn't.
  if [ -n "$parent_option_id" ] && [ -z "$child_option_id" ]; then
    field_id=$(gh api graphql -f query='
      query($field_name: String!) {
        organization(login: "OmnitrustILM") {
          projectV2(number: 5) {
            field(name: $field_name) {
              ... on ProjectV2SingleSelectField { id }
            }
          }
        }
      }' -f field_name="$field_name" \
      --jq '.data.organization.projectV2.field.id')

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
      -f itemId="$CHILD_ITEM_ID" \
      -f fieldId="$field_id" \
      -f optionId="$parent_option_id"

    parent_value=$(printf '%s' "$PARENT_ITEM" | jq -r \
      --arg fname "$field_name" \
      '.fieldValues.nodes[] | select(.field.name == $fname) | .name')
    echo "Propagated $field_name: '$parent_value' from parent to child"
  else
    echo "$field_name: parent empty or child already set — skipping"
  fi
done
