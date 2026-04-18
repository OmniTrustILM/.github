#!/usr/bin/env bash
# Dry-run companion to sync-all.sh. Reports per-task drift for a
# target repo without opening a PR.
#
# Expects `source/` (this .github repo) and `target/` (the target repo)
# to be checked out.
#
# Reads: REPO_NAME
# Writes: Markdown report to $GITHUB_STEP_SUMMARY
set -euo pipefail

FILES=(
  "templates/release.yml:.github/release.yml"
  "templates/caller-workflows/issue-automation.yml:.github/workflows/issue-automation.yml"
  "templates/caller-workflows/release-automation.yml:.github/workflows/release-automation.yml"
)

{
  echo "### $REPO_NAME"
  echo ""
  echo "| File | State |"
  echo "|---|---|"
  for pair in "${FILES[@]}"; do
    src_rel=${pair%%:*}
    dst_rel=${pair##*:}
    src="source/$src_rel"
    dst="target/$dst_rel"
    if [ ! -f "$dst" ]; then
      echo "| \`$dst_rel\` | MISSING (would be created) |"
    elif cmp -s "$src" "$dst"; then
      echo "| \`$dst_rel\` | IDENTICAL |"
    else
      echo "| \`$dst_rel\` | DIFFERS (would be updated) |"
    fi
  done
} >> "$GITHUB_STEP_SUMMARY"
