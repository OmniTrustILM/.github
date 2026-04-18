#!/usr/bin/env bash
# When a new issue is created, check if it has a parent issue and
# copy Version and Module from parent to child — but only if the
# child's fields are empty. Never overrides existing values.
#
# Creation-time only: if the parent's fields change later, children
# are NOT auto-updated. The /project-triage skill catches drift.
#
# Reads: GH_TOKEN, ISSUE_URL
set -euo pipefail

PROJECT_ID="PVT_kwDOB4ppKM4AlVOh"

echo "Issue: $ISSUE_URL"

# Wait for auto-add-to-project to add this issue to the project.
sleep 5

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
  gh api graphql -f query='
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
    }' -f url="$url" \
    --jq ".data.resource.projectItems.nodes[] | select(.project.id == \"$PROJECT_ID\")"
}

PARENT_ITEM=$(get_project_item "$PARENT_URL")
CHILD_ITEM=$(get_project_item "$ISSUE_URL")

CHILD_ITEM_ID=$(printf '%s' "$CHILD_ITEM" | jq -r '.id')

if [ -z "$CHILD_ITEM_ID" ] || [ "$CHILD_ITEM_ID" = "null" ]; then
  echo "::warning::Child issue not found in project. It may not have been added yet."
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
