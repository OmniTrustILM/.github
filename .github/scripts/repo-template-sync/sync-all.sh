#!/usr/bin/env bash
# Sync a target repo to the org templates, one commit per task.
#
# Expects the caller to have checked out:
#   source/   — this .github repo (contains templates/)
#   target/   — the target repo (where the PR will be opened)
#
# Reads: GH_TOKEN, REPO (owner/name), REPO_NAME
# Writes: notices + markdown summary to $GITHUB_STEP_SUMMARY
#
# Each task checks for drift and commits only if needed. If no task
# produces a commit, no branch is pushed and no PR is opened.
#
# Idempotency: stable branch `chore/sync-to-org-template`.
# Maintainer opt-out: closed-unmerged PR on that branch → skip.
set -euo pipefail

cd target
git config user.name "ilm-project-bot[bot]"
git config user.email "ilm-project-bot[bot]@users.noreply.github.com"

branch="chore/sync-to-org-template"
base=$(gh repo view "$REPO" --json defaultBranchRef --jq .defaultBranchRef.name)

closed_unmerged=$(gh pr list --repo "$REPO" --head "$branch" --state closed --limit 100 --json number,mergedAt \
  --jq '[.[] | select(.mergedAt == null)] | length')
if [ "$closed_unmerged" -gt 0 ]; then
  echo "::notice::$REPO has a closed-unmerged sync PR on $branch — skipping"
  echo "### $REPO_NAME: SKIPPED (closed-unmerged PR exists)" >> "$GITHUB_STEP_SUMMARY"
  exit 0
fi

git fetch origin "$base"
git checkout -B "$branch" "origin/$base"

commits_made=0
task_summary=""

# ---------- Task 1: release.yml ----------
mkdir -p .github
cp ../source/templates/release.yml .github/release.yml
git add .github/release.yml
if ! git diff --cached --quiet; then
  git commit -m "chore: sync .github/release.yml from org template"
  commits_made=$((commits_made + 1))
  task_summary="${task_summary}- release.yml: synced%0A"
else
  task_summary="${task_summary}- release.yml: no change%0A"
fi

# ---------- Task 2: caller workflows ----------
mkdir -p .github/workflows
cp ../source/templates/caller-workflows/issue-automation.yml .github/workflows/
cp ../source/templates/caller-workflows/release-automation.yml .github/workflows/
git add .github/workflows/issue-automation.yml .github/workflows/release-automation.yml
if ! git diff --cached --quiet; then
  git commit -m "chore: sync issue/release-automation workflows from org template"
  commits_made=$((commits_made + 1))
  task_summary="${task_summary}- caller workflows: synced%0A"
else
  task_summary="${task_summary}- caller workflows: no change%0A"
fi

# ---------- Skip PR if no commits ----------
if [ "$commits_made" -eq 0 ]; then
  {
    echo "### $REPO_NAME: fully aligned (no PR)"
    echo "$task_summary" | tr '%0A' '\n'
  } >> "$GITHUB_STEP_SUMMARY"
  exit 0
fi

# Push the branch; force-with-lease so we don't stomp concurrent reviewer commits.
git push --force-with-lease origin "$branch"

# Open or update the PR.
existing=$(gh pr list --repo "$REPO" --head "$branch" --state open --json number --jq '.[0].number // empty')
if [ -n "$existing" ]; then
  echo "::notice::Updated existing PR #$existing on $REPO ($commits_made commits)"
  {
    echo "### $REPO_NAME: UPDATED PR #$existing ($commits_made commits)"
    echo "$task_summary" | tr '%0A' '\n'
  } >> "$GITHUB_STEP_SUMMARY"
  exit 0
fi

body_file=$(mktemp)
cat > "$body_file" <<EOF
Automated alignment of this repo with the org templates in OmnitrustILM/.github.

Tasks this PR addresses:
$(echo "$task_summary" | tr '%0A' '\n' | sed 's/^-/  -/')

Source workflow: [Repo Template Sync](https://github.com/OmnitrustILM/.github/actions/workflows/repo-template-sync.yml)

To opt out of future syncs, close this PR without merging — the
workflow will respect that decision on subsequent runs.
EOF

url=$(gh pr create --repo "$REPO" \
  --head "$branch" \
  --base "$base" \
  --title "chore: sync repo to org template" \
  --body-file "$body_file")

echo "::notice::Opened $url"
{
  echo "### $REPO_NAME: OPENED $url ($commits_made commits)"
  echo "$task_summary" | tr '%0A' '\n'
} >> "$GITHUB_STEP_SUMMARY"
