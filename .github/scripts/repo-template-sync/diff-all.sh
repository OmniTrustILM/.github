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

# CODEOWNERS is rendered (not a static template), so compute its drift
# separately by rendering the expected content and comparing.
co_tmp=$(mktemp)
set +e
bash source/.github/scripts/repo-template-sync/render-codeowners.sh \
  "$REPO_NAME" source/config/repo-domains.yml > "$co_tmp"
co_rc=$?
set -e
co_failed=0
if [ "$co_rc" -eq 3 ]; then
  co_state="SKIPPED (excluded)"
elif [ "$co_rc" -ne 0 ]; then
  co_state="ERROR (rc=$co_rc)"
  co_failed=1
  echo "::error::render-codeowners.sh failed for $REPO_NAME (rc=$co_rc) — dry-run will fail"
else
  # Mirror sync-all's guard: an existing CODEOWNERS not managed by sync (at
  # .github/, root, or docs/) is left untouched — report it as SKIPPED, not DIFFERS.
  existing_co=""
  for loc in .github/CODEOWNERS CODEOWNERS docs/CODEOWNERS; do
    if [ -f "target/$loc" ]; then existing_co="$loc"; break; fi
  done
  if [ -n "$existing_co" ] && ! head -n1 "target/$existing_co" | grep -qF "# Synced by repo-template-sync"; then
    co_state="SKIPPED (existing $existing_co not sync-managed)"
  elif [ ! -f target/.github/CODEOWNERS ]; then
    co_state="MISSING (would be created)"
  elif cmp -s "$co_tmp" target/.github/CODEOWNERS; then
    co_state="IDENTICAL"
  else
    co_state="DIFFERS (would be updated)"
  fi
fi
rm -f "$co_tmp"

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
  echo "| \`.github/CODEOWNERS\` | $co_state |"
} >> "$GITHUB_STEP_SUMMARY"

# A broken renderer must fail the dry-run, not just show an ERROR row in the table.
if [ "$co_failed" -eq 1 ]; then
  exit 1
fi
