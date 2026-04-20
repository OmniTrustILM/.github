#!/usr/bin/env bash
# Resolve the matrix of target repos for release.yml sync.
#
# Reads: GH_TOKEN, TARGET_INPUT, GITHUB_OUTPUT
# Writes: repos=<json array>, count=<int> to $GITHUB_OUTPUT
#
# Behavior:
#   - "all" → every non-archived OmniTrustILM repo
#   - comma-separated list → validates each name exists
#   - always drops the .github repo itself (self-reference)
set -euo pipefail

# Hard cap detection: gh silently truncates at --limit. If the org grows
# past LIMIT non-archived repos, raise this value.
LIMIT=500

# Filter out empty repos (zero commits — no default branch to check
# out, so actions/checkout@v4 would fail with "couldn't find remote
# ref refs/heads/<base>"). They're not meaningful sync targets until
# they have at least one commit.
all_repos=$(gh repo list OmniTrustILM --no-archived --limit "$LIMIT" --json name,isEmpty \
  --jq '.[] | select(.isEmpty == false) | .name')
repo_count=$(printf '%s\n' "$all_repos" | grep -c . || :)
if [ "$repo_count" -ge "$LIMIT" ]; then
  echo "::error::Reached --limit $LIMIT on gh repo list. Raise the limit."
  exit 1
fi

if [ "$TARGET_INPUT" = "all" ]; then
  candidates="$all_repos"
else
  candidates=$(printf '%s\n' "$TARGET_INPUT" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$' || :)
  for r in $candidates; do
    if ! printf '%s\n' "$all_repos" | grep -qx "$r"; then
      echo "::error::Repo '$r' not found in OmniTrustILM (or is archived)"
      exit 1
    fi
  done
fi

# Drop self — the .github repo is the source of truth for the template;
# syncing to itself would nest the file under .github/.github/.
# -F treats the pattern as a fixed string so the '.' is literal,
# not a regex metachar that would also match "xgithub" etc.
final=$(printf '%s\n' "$candidates" | grep -Fvx '.github' | grep -v '^$' || :)

count=$(printf '%s\n' "$final" | grep -c . || :)
if [ -z "$count" ] || [ "$count" -eq 0 ]; then
  echo "::error::No target repos after filtering"
  exit 1
fi

json=$(printf '%s\n' "$final" | jq -R . | jq -sc .)
{
  echo "repos=$json"
  echo "count=$count"
} >> "$GITHUB_OUTPUT"

echo "Resolved $count target repos"
printf '%s\n' "$final"
