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

# 2) Fractional estimates are accepted. The agent-executed basis (§3.5) routinely
#    produces sub-day numbers, and Estimate is a NUMBER field that stores floats.
for e in 3.5 0.75 1.25 2 0.5; do
  bash "$SCRIPT" --item-id ITEM1 --estimate "$e" --dry-run >/dev/null 2>&1 \
    || { echo "FAIL: estimate '$e' rejected"; exit 1; }
done

# 3) Malformed and out-of-range estimates are still rejected.
for e in abc 3.456 -1 "" 1e3 .5; do
  if bash "$SCRIPT" --item-id ITEM1 --estimate "$e" --dry-run >/dev/null 2>&1; then
    echo "FAIL: estimate '$e' accepted"; exit 1
  fi
done

# 4) Missing item-id is rejected.
if bash "$SCRIPT" --complexity Low --dry-run >/dev/null 2>&1; then
  echo "FAIL: missing item-id accepted"; exit 1
fi

# 5) Nothing to set is rejected.
if bash "$SCRIPT" --item-id ITEM1 --dry-run >/dev/null 2>&1; then
  echo "FAIL: empty field set accepted"; exit 1
fi

echo "PASS"
