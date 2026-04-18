#!/usr/bin/env bash
# Post audit comment on a reopened issue and clear the Reopen Reason field.
#
# Fires on the GitHub `issues.reopened` event (post-merge reopen).
# Does NOT fire on pre-merge QA rejection (that's a status regression
# on a still-open issue — no reopen event).
#
# Reads: GH_TOKEN, ISSUE_URL, ISSUE_NUMBER, REPO, ACTOR, PROJECT_ID
set -euo pipefail

ASSIGNEES=$(gh issue view "$ISSUE_NUMBER" --repo "$REPO" \
  --json assignees --jq '.assignees | map(.login) | join(", ")')

REOPENED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

body_file=$(mktemp)
cat > "$body_file" <<EOF
**Issue reopened** by @${ACTOR}
Previously assigned to: ${ASSIGNEES:-none}
Reopened at: ${REOPENED_AT}

Please set the **Reopen Reason** field (Regression, Incomplete Implementation, Edge Case, Other).
EOF

gh issue comment "$ISSUE_NUMBER" --repo "$REPO" --body-file "$body_file"
echo "Posted reopen comment on $REPO#$ISSUE_NUMBER"

# Clear Reopen Reason on the project item so user must set a new one.
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
  echo "::warning::Issue not found in project — Reopen Reason not cleared."
  exit 0
fi

FIELD_ID=$(gh api graphql -f query='
  { organization(login: "OmnitrustILM") {
    projectV2(number: 5) {
      field(name: "Reopen Reason") {
        ... on ProjectV2SingleSelectField { id }
      }
    }
  } }' --jq '.data.organization.projectV2.field.id')

gh api graphql -f query='
  mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!) {
    clearProjectV2ItemFieldValue(input: {
      projectId: $projectId
      itemId: $itemId
      fieldId: $fieldId
    }) {
      projectV2Item { id }
    }
  }' \
  -f projectId="$PROJECT_ID" \
  -f itemId="$ITEM_ID" \
  -f fieldId="$FIELD_ID"

echo "Cleared Reopen Reason field"
