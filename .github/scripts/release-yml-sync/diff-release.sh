#!/usr/bin/env bash
# Compare source release.yml template against target's .github/release.yml.
#
# Reads: REPO_NAME, GITHUB_OUTPUT, GITHUB_STEP_SUMMARY
# Writes: status=IDENTICAL|MISSING|WOULD_UPDATE to $GITHUB_OUTPUT
#
# Path asymmetry is intentional:
#   - In the .github repo, the org template lives at templates/release.yml.
#   - In every OTHER repo, release.yml lives under .github/ per the
#     standard GitHub convention for per-repo release-notes config.
set -euo pipefail

src=source/templates/release.yml
dst=target/.github/release.yml

if [ ! -f "$src" ]; then
  echo "::error::Source template missing at $src"
  exit 1
fi

if [ ! -f "$dst" ]; then
  echo "status=MISSING" >> "$GITHUB_OUTPUT"
  echo "### $REPO_NAME: MISSING" >> "$GITHUB_STEP_SUMMARY"
  exit 0
fi

if cmp -s "$src" "$dst"; then
  echo "status=IDENTICAL" >> "$GITHUB_OUTPUT"
  echo "### $REPO_NAME: IDENTICAL" >> "$GITHUB_STEP_SUMMARY"
  exit 0
fi

echo "status=WOULD_UPDATE" >> "$GITHUB_OUTPUT"
{
  echo "### $REPO_NAME: WOULD UPDATE"
  echo '```diff'
  diff -u "$dst" "$src" || :
  echo '```'
} >> "$GITHUB_STEP_SUMMARY"
