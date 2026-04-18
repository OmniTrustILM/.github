#!/usr/bin/env bash
# Stamp Version on closed Done issues that don't have a Version set,
# when a new GitHub Release is published.
#
# Safety net — Version should be set during sprint planning. This
# catches issues that slipped through without a Version tag.
#
# Only stamps issues closed AFTER the previous release of the same
# repo, so old unversioned issues don't get mis-attributed.
#
# Reads: GH_TOKEN, RELEASE_TAG, REPO
set -euo pipefail

VERSION="${RELEASE_TAG#v}"
echo "Release version: $VERSION"
echo "Repository: $REPO"

PREV_RELEASE_DATE=$(gh api "repos/$REPO/releases" \
  --jq '.[1].published_at // "2000-01-01T00:00:00Z"' 2>/dev/null)
echo "Previous release date: $PREV_RELEASE_DATE"

VERSION_FIELD=$(gh api graphql -f query='
  { organization(login: "OmnitrustILM") {
    projectV2(number: 5) {
      field(name: "Version") {
        ... on ProjectV2SingleSelectField {
          id
          options { id name }
        }
      }
    }
  } }' --jq '.data.organization.projectV2.field')

FIELD_ID=$(printf '%s' "$VERSION_FIELD" | jq -r '.id')
OPTION_ID=$(printf '%s' "$VERSION_FIELD" | jq -r --arg name "$VERSION" '.options[] | select(.name == $name) | .id')

if [ -z "$OPTION_ID" ] || [ "$OPTION_ID" = "null" ]; then
  echo "::warning::Version '$VERSION' not found in project field options. Add it to Project #5 settings first."
  exit 0
fi

ISSUES=$(gh issue list --repo "$REPO" --state closed \
  --json number,url,closedAt --limit 200 \
  --jq "[.[] | select(.closedAt > \"$PREV_RELEASE_DATE\")] | .[].url")

if [ -z "$ISSUES" ]; then
  echo "No closed issues found after previous release."
  exit 0
fi

STAMPED=0
SKIPPED=0

for issue_url in $ISSUES; do
  ITEM_DATA=$(gh api graphql -f query='
    query($url: URI!) {
      resource(url: $url) {
        ... on Issue {
          projectItems(first: 5) {
            nodes {
              id
              project { id }
              fieldValues(first: 20) {
                nodes {
                  ... on ProjectV2ItemFieldSingleSelectValue {
                    field { ... on ProjectV2SingleSelectField { name } }
                    name
                  }
                }
              }
            }
          }
        }
      }
    }' -f url="$issue_url" \
    --jq '.data.resource.projectItems.nodes[] | select(.project.id == "PVT_kwDOB4ppKM4AlVOh")')

  if [ -z "$ITEM_DATA" ]; then
    continue
  fi

  STATUS=$(printf '%s' "$ITEM_DATA" | jq -r '.fieldValues.nodes[] | select(.field.name == "Status") | .name')
  EXISTING_VERSION=$(printf '%s' "$ITEM_DATA" | jq -r '.fieldValues.nodes[] | select(.field.name == "Version") | .name')

  if [ "$STATUS" = "Done" ] && { [ -z "$EXISTING_VERSION" ] || [ "$EXISTING_VERSION" = "null" ]; }; then
    ITEM_ID=$(printf '%s' "$ITEM_DATA" | jq -r '.id')

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
      -f projectId="PVT_kwDOB4ppKM4AlVOh" \
      -f itemId="$ITEM_ID" \
      -f fieldId="$FIELD_ID" \
      -f optionId="$OPTION_ID"

    echo "Stamped $issue_url with Version $VERSION"
    STAMPED=$((STAMPED + 1))
  else
    SKIPPED=$((SKIPPED + 1))
  fi
done

echo ""
echo "=== Post-Release Stamping Summary ==="
echo "Version: $VERSION"
echo "Issues stamped: $STAMPED"
echo "Issues skipped (already versioned or not Done): $SKIPPED"
