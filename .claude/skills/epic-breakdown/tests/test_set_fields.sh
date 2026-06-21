#!/usr/bin/env bash
# Tests set-epic-fields.sh dry-run + estimate validation. Requires a warm cache.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../set-epic-fields.sh"
CACHE="$HERE/../cache"

if [ ! -f "$CACHE/project-fields.json" ]; then
  echo "SKIP test_set_fields: no cache (run fetch.sh or tests/run.sh)"; exit 0
fi

# 1) Dry-run prints both planned writes.
out=$(bash "$SCRIPT" --item-id ITEM1 --complexity High --estimate 5 --dry-run 2>&1)
echo "$out" | grep -qi "Complexity=High" || { echo "FAIL: complexity not planned"; exit 1; }
echo "$out" | grep -qi "Estimate=5" || { echo "FAIL: estimate not planned"; exit 1; }

# 2) Non-integer estimate is rejected (even in dry-run).
if bash "$SCRIPT" --item-id ITEM1 --estimate 3.5 --dry-run >/dev/null 2>&1; then
  echo "FAIL: fractional estimate accepted"; exit 1
fi
if bash "$SCRIPT" --item-id ITEM1 --estimate abc --dry-run >/dev/null 2>&1; then
  echo "FAIL: non-numeric estimate accepted"; exit 1
fi

# 3) Missing item-id is rejected.
if bash "$SCRIPT" --complexity Low --dry-run >/dev/null 2>&1; then
  echo "FAIL: missing item-id accepted"; exit 1
fi

# 4) Nothing to set is rejected.
if bash "$SCRIPT" --item-id ITEM1 --dry-run >/dev/null 2>&1; then
  echo "FAIL: empty field set accepted"; exit 1
fi

echo "PASS"
