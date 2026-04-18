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
# Reads: GH_TOKEN, RELEASE_TAG, REPO, PROJECT_ID, IS_PRERELEASE
set -euo pipefail

VERSION="${RELEASE_TAG#v}"
echo "Release version: $VERSION"
echo "Repository: $REPO"

# Skip prereleases. Tags like v2.19.0-rc1 or v2.19.0-beta.2 won't
# match a Version option in the project field, and stamping issues
# with a prerelease version would mis-attribute them to the final
# release later. Version-option stamping happens when the GA release
# fires this workflow.
if [ "$IS_PRERELEASE" = "true" ]; then
  echo "Skipping — $RELEASE_TAG is a prerelease."
  exit 0
fi

# Get the previous release's published_at as a lower bound. If there's
# no previous release (this is the first one), fall back to epoch-0
# so every closed issue in the repo is eligible. On API failure bail
# loudly rather than using a silent fallback that would mis-attribute
# old issues to this release.
if ! PREV_RELEASES=$(gh api "repos/$REPO/releases"); then
  echo "::error::Failed to list releases for $REPO"
  exit 1
fi
PREV_RELEASE_DATE=$(printf '%s' "$PREV_RELEASES" | jq -r '.[1].published_at // "1970-01-01T00:00:00Z"')
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
  ITEM_JSON=$(gh api graphql -f query='
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
    }' -f url="$issue_url")

  ITEM_DATA=$(printf '%s' "$ITEM_JSON" | jq --arg pid "$PROJECT_ID" \
    '.data.resource.projectItems.nodes[] | select(.project.id == $pid)')

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
      -f projectId="$PROJECT_ID" \
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
