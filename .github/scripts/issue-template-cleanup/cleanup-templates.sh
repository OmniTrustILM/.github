#!/usr/bin/env bash
# Delete the per-repo .github/ISSUE_TEMPLATE/ directory so the target
# repo inherits the org templates from OmniTrustILM/.github instead.
#
# GitHub issue-template inheritance is all-or-nothing: a repo that has
# ANY file in .github/ISSUE_TEMPLATE/ uses only those and ignores the
# org repo's templates. This script removes the per-repo directory so
# the org templates take effect.
#
# Expects the caller to have checked out:
#   target/   — the target repo (where the PR will be opened)
#
# Reads: GH_TOKEN, REPO (owner/name), REPO_NAME, DRY_RUN (true|false)
# Writes: notices + markdown summary to $GITHUB_STEP_SUMMARY
#
# Idempotency: stable branch `chore/cleanup-legacy-issue-templates`.
# Maintainer opt-out: closed-unmerged PR on that branch → skip.
set -euo pipefail

cd target

template_dir=".github/ISSUE_TEMPLATE"

# Short-circuit: nothing to clean up.
if [ ! -d "$template_dir" ]; then
  {
    echo "### $REPO_NAME: already clean (no $template_dir)"
  } >> "$GITHUB_STEP_SUMMARY"
  exit 0
fi

# List the files we would remove (for summary + dry-run).
files=$(find "$template_dir" -type f | sort)
file_count=$(printf '%s\n' "$files" | grep -c . || :)

if [ "$DRY_RUN" = "true" ]; then
  {
    echo "### $REPO_NAME: $file_count files would be deleted (dry run)"
    echo ""
    echo '```'
    printf '%s\n' "$files"
    echo '```'
  } >> "$GITHUB_STEP_SUMMARY"
  exit 0
fi

# Real run — commit + push + PR.
git config user.name "ilm-project-bot[bot]"
git config user.email "ilm-project-bot[bot]@users.noreply.github.com"

branch="chore/cleanup-legacy-issue-templates"
base=$(gh repo view "$REPO" --json defaultBranchRef --jq .defaultBranchRef.name)

# If the bot opened a PR from this branch and a maintainer closed it
# without merging, don't reopen — that's the per-repo opt-out signal
# (maintainer has intentional custom templates to preserve).
closed_unmerged=$(gh pr list --repo "$REPO" --head "$branch" --state closed --limit 100 --json number,mergedAt \
  --jq '[.[] | select(.mergedAt == null)] | length')
if [ "$closed_unmerged" -gt 0 ]; then
  echo "::notice::$REPO has a closed-unmerged cleanup PR on $branch — skipping (maintainer opted out)"
  echo "### $REPO_NAME: SKIPPED (closed-unmerged PR — maintainer opted out)" >> "$GITHUB_STEP_SUMMARY"
  exit 0
fi

git fetch origin "$base"
# Fetch the sync branch if it exists — required for --force-with-lease.
git fetch origin "$branch" 2>/dev/null || true
git checkout -B "$branch" "origin/$base"

git rm -r "$template_dir"

if git diff --cached --quiet; then
  # Shouldn't happen given the existence check at the top, but be safe.
  echo "No changes after deletion — skipping $REPO"
  echo "### $REPO_NAME: no changes" >> "$GITHUB_STEP_SUMMARY"
  exit 0
fi

git commit -m "chore: remove legacy .github/ISSUE_TEMPLATE/ to inherit org templates"
git push --force-with-lease origin "$branch"

existing=$(gh pr list --repo "$REPO" --head "$branch" --state open --json number --jq '.[0].number // empty')
if [ -n "$existing" ]; then
  echo "::notice::Updated existing PR #$existing on $REPO"
  echo "### $REPO_NAME: UPDATED PR #$existing ($file_count files removed)" >> "$GITHUB_STEP_SUMMARY"
  exit 0
fi

body_file=$(mktemp)
{
  echo "This PR removes the per-repo issue templates under \`.github/ISSUE_TEMPLATE/\` so this repository inherits the canonical templates from \`OmniTrustILM/.github\`."
  echo ""
  echo "### Why"
  echo ""
  echo "GitHub issue-template inheritance is all-or-nothing: a repo that keeps any file in \`.github/ISSUE_TEMPLATE/\` uses only those files and ignores the org templates entirely. Removing the directory here lets the org's canonical template set (Bug, Feature, Epic, Task, QA, Documentation, Vulnerability, Release, plus \`config.yml\` for the chooser) take effect in this repo."
  echo ""
  echo "### Files removed ($file_count)"
  echo ""
  echo '```'
  printf '%s\n' "$files"
  echo '```'
  echo ""
  echo "### Opting out"
  echo ""
  echo "If this repo has an intentional custom template worth preserving, **close this PR without merging** — the cleanup workflow will respect that decision on future runs. Note that keeping any per-repo template means **none** of the org templates will be offered in this repo's New Issue picker."
  echo ""
  echo "Source workflow: [Issue Template Cleanup](https://github.com/OmniTrustILM/.github/actions/workflows/issue-template-cleanup.yml)"
} > "$body_file"

url=$(gh pr create --repo "$REPO" \
  --head "$branch" \
  --base "$base" \
  --title "Remove legacy issue templates to inherit from org" \
  --body-file "$body_file")

echo "::notice::Opened $url"
echo "### $REPO_NAME: OPENED $url ($file_count files removed)" >> "$GITHUB_STEP_SUMMARY"
