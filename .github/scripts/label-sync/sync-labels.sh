#!/usr/bin/env bash
# Sync labels from templates/labels.yml to every non-archived org repo.
#
# Uses --force flag: creates the label if missing, updates color/description
# if it already exists. Does NOT delete labels — additive only.
#
# Reads: GH_TOKEN
# Requires: yq, gh, jq on PATH
set -euo pipefail

FAILED=0
SYNCED=0

# Hard cap detection: gh silently truncates at --limit.
LIMIT=500
repos=$(gh repo list OmniTrustILM --no-archived --limit "$LIMIT" --json name --jq '.[].name')
repo_count=$(printf '%s\n' "$repos" | grep -c . || :)
if [ "$repo_count" -ge "$LIMIT" ]; then
  echo "::error::Reached --limit $LIMIT on gh repo list. Raise the limit."
  exit 1
fi

for repo in $repos; do
  echo "::group::Syncing labels to $repo"
  REPO_FAILED=0

  # Read each label entry as a compact JSON object (handles special chars)
  while IFS= read -r line; do
    name=$(printf '%s' "$line" | yq eval '.name' -)
    color=$(printf '%s' "$line" | yq eval '.color' -)
    description=$(printf '%s' "$line" | yq eval '.description' -)

    if gh label create "$name" \
      --repo "OmniTrustILM/$repo" \
      --color "$color" \
      --description "$description" \
      --force 2>&1; then
      SYNCED=$((SYNCED + 1))
    else
      echo "::warning::Failed to sync label '$name' to $repo"
      REPO_FAILED=$((REPO_FAILED + 1))
    fi
  done < <(yq eval '.[]' -o=json -I=0 templates/labels.yml)

  if [ "$REPO_FAILED" -gt 0 ]; then
    FAILED=$((FAILED + REPO_FAILED))
  fi
  echo "::endgroup::"
done

echo ""
echo "=== Label Sync Summary ==="
echo "Labels synced: $SYNCED"
echo "Failures: $FAILED"

if [ "$FAILED" -gt 0 ]; then
  echo "::warning::$FAILED label sync operations failed. Check logs above."
fi
