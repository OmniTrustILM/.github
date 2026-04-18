#!/usr/bin/env bash
# Create or update a PR that syncs .github/release.yml in the target repo.
#
# Expects the caller to have checked out:
#   source/   — this .github repo (contains templates/release.yml)
#   target/   — the target repo (where the PR will be opened)
#
# Reads: GH_TOKEN, REPO (owner/name), REPO_NAME, STATUS (MISSING|WOULD_UPDATE)
# Writes: notices + markdown summary to $GITHUB_STEP_SUMMARY
#
# Idempotency: stable branch name `chore/sync-release-yml`. Uses
# --force-with-lease so concurrent reviewer commits on the same branch
# are not silently stomped.
# Per-repo opt-out: if a maintainer closes the bot's PR without merging,
# we skip on subsequent runs.
set -euo pipefail

cd target
git config user.name "ilm-project-bot[bot]"
git config user.email "ilm-project-bot[bot]@users.noreply.github.com"

branch="chore/sync-release-yml"
base=$(gh repo view "$REPO" --json defaultBranchRef --jq .defaultBranchRef.name)

# gh pr list doesn't expose a boolean `merged` field; use `mergedAt`
# which is null for PRs that were closed without merging.
closed_unmerged=$(gh pr list --repo "$REPO" --head "$branch" --state closed --limit 100 --json number,mergedAt \
  --jq '[.[] | select(.mergedAt == null)] | length')
if [ "$closed_unmerged" -gt 0 ]; then
  echo "::notice::$REPO has a closed-unmerged sync PR on branch $branch — skipping (respecting maintainer decision)"
  echo "### $REPO_NAME: SKIPPED (closed-unmerged PR exists)" >> "$GITHUB_STEP_SUMMARY"
  exit 0
fi

git fetch origin "$base"
git checkout -B "$branch" "origin/$base"

mkdir -p .github
cp ../source/templates/release.yml .github/release.yml

if git diff --quiet; then
  echo "No changes after copy — skipping $REPO"
  exit 0
fi

git add .github/release.yml
git commit -m "chore: sync .github/release.yml from org template"
git push --force-with-lease origin "$branch"

existing=$(gh pr list --repo "$REPO" --head "$branch" --state open --json number --jq '.[0].number // empty')
if [ -n "$existing" ]; then
  echo "::notice::Updated existing PR #$existing on $REPO"
  echo "### $REPO_NAME: UPDATED PR #$existing" >> "$GITHUB_STEP_SUMMARY"
  exit 0
fi

# Backticks in the body must be escaped so bash doesn't treat them as
# command substitution (we want them as literal markdown code fences).
# $STATUS is intentionally expanded.
body_file=$(mktemp)
cat > "$body_file" <<EOF
Automated sync of \`.github/release.yml\` from the org template in OmnitrustILM/.github.

Source workflow: [Release.yml Sync](https://github.com/OmnitrustILM/.github/actions/workflows/release-yml-sync.yml)
Previous state: \`$STATUS\`

Merge to adopt the shared release-notes categories. To opt out of future syncs, close this PR without merging — the workflow will respect that decision on subsequent runs.
EOF

url=$(gh pr create --repo "$REPO" \
  --head "$branch" \
  --base "$base" \
  --title "chore: sync .github/release.yml from org template" \
  --body-file "$body_file")
echo "::notice::Opened $url"
echo "### $REPO_NAME: OPENED $url" >> "$GITHUB_STEP_SUMMARY"
