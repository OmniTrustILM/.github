#!/usr/bin/env bash
# Live test: runs fetch.sh and asserts the cache. Requires gh with the
# read:project (or project) scope; SKIPs cleanly otherwise so the offline
# suite still passes.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL="$(cd "$HERE/.." && pwd)"
CACHE="$SKILL/cache"

if ! gh auth status >/dev/null 2>&1; then echo "SKIP test_fetch: gh not authenticated"; exit 0; fi
if ! gh auth status 2>&1 | grep -qE "'(project|read:project)'"; then
  echo "SKIP test_fetch: token lacks project/read:project scope (run: gh auth refresh -s project)"; exit 0
fi

if ! bash "$SKILL/fetch.sh"; then echo "FAIL: fetch.sh exited non-zero"; exit 1; fi

for f in project-fields.json repos.json issue-types.json labels.json development-process.md fetched-at.txt; do
  [ -s "$CACHE/$f" ] || { echo "FAIL: cache/$f missing or empty"; exit 1; }
done
jq -e '.fields.Complexity.id and .fields.Estimate.dataType == "NUMBER"' "$CACHE/project-fields.json" >/dev/null \
  || { echo "FAIL: project schema unexpected"; exit 1; }
jq -e '.Epic and .Feature and .Task and .Bug' "$CACHE/issue-types.json" >/dev/null \
  || { echo "FAIL: issue types incomplete"; exit 1; }
grep -q "Module" "$CACHE/development-process.md" || { echo "FAIL: methodics not cached"; exit 1; }
echo "PASS"
