#!/usr/bin/env bash
# Tests enrich-epic.sh's idempotent body-merge via the --merge-test hook.
# No network, no cache.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ENRICH="$HERE/../enrich-epic.sh"
START="<!-- epic-breakdown:enriched -->"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

printf '## User Story\n\nAs a user...\n' > "$TMP/old.md"
printf '## Acceptance Criteria\n\n- [ ] done\n' > "$TMP/enriched.md"

# 1) First enrichment: markers added once, original preserved.
out=$(bash "$ENRICH" --merge-test "$TMP/old.md" "$TMP/enriched.md")
count=$(printf '%s\n' "$out" | grep -cF "$START")
[ "$count" -eq 1 ] || { echo "FAIL: expected 1 start marker, got $count"; exit 1; }
printf '%s\n' "$out" | grep -q "As a user" || { echo "FAIL: original lost"; exit 1; }
printf '%s\n' "$out" | grep -q "Acceptance Criteria" || { echo "FAIL: enriched missing"; exit 1; }

# 2) Re-enrichment (idempotent): feed the merged body back; still exactly one block.
printf '%s\n' "$out" > "$TMP/old2.md"
printf '## Acceptance Criteria\n\n- [ ] updated\n' > "$TMP/enriched2.md"
out2=$(bash "$ENRICH" --merge-test "$TMP/old2.md" "$TMP/enriched2.md")
count2=$(printf '%s\n' "$out2" | grep -cF "$START")
[ "$count2" -eq 1 ] || { echo "FAIL: re-run produced $count2 markers (not idempotent)"; exit 1; }
printf '%s\n' "$out2" | grep -q "updated" || { echo "FAIL: re-run did not replace block"; exit 1; }
printf '%s\n' "$out2" | grep -q "As a user" || { echo "FAIL: re-run lost original"; exit 1; }
printf '%s\n' "$out2" | grep -q "\- \[ \] done" && { echo "FAIL: stale enriched content survived"; exit 1; }

echo "PASS"
