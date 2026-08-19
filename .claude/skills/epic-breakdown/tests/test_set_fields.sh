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

# 2) Fractional estimates are accepted, and the value survives to the preview.
for e in 3.5 0.75 1.25 2 0.5; do
  out=$(bash "$SCRIPT" --item-id ITEM1 --estimate "$e" --dry-run 2>&1) \
    || { echo "FAIL: estimate '$e' rejected"; exit 1; }
  echo "$out" | grep -qi "Estimate=$e" || { echo "FAIL: estimate '$e' mangled in preview"; exit 1; }
done

# 3) Malformed estimates are rejected by the validator, not by an earlier guard.
#    --complexity keeps the "nothing to set" guard from firing first, so these
#    genuinely exercise estimate_is_valid.
for e in abc 3.456 -1 1e3 .5; do
  out=$(bash "$SCRIPT" --item-id ITEM1 --complexity Low --estimate "$e" --dry-run 2>&1)
  [ $? -ne 0 ] || { echo "FAIL: estimate '$e' accepted"; exit 1; }
  echo "$out" | grep -q "at most two decimals" \
    || { echo "FAIL: estimate '$e' rejected for the wrong reason: $out"; exit 1; }
  echo "$out" | grep -q "would: set" \
    && { echo "FAIL: preview printed a write for invalid estimate '$e'"; exit 1; }
done

# 4) An explicitly-passed empty estimate is its own error, distinct from
#    omitting the flag - breakdown passes --estimate for every child.
out=$(bash "$SCRIPT" --item-id ITEM1 --complexity Low --estimate "" --dry-run 2>&1)
[ $? -ne 0 ] || { echo "FAIL: empty --estimate accepted"; exit 1; }
echo "$out" | grep -q -- "--estimate requires a value" \
  || { echo "FAIL: empty --estimate gave the wrong error: $out"; exit 1; }

# 5) Missing item-id is rejected.
if bash "$SCRIPT" --complexity Low --dry-run >/dev/null 2>&1; then
  echo "FAIL: missing item-id accepted"; exit 1
fi

# 6) Nothing to set is rejected.
if bash "$SCRIPT" --item-id ITEM1 --dry-run >/dev/null 2>&1; then
  echo "FAIL: empty field set accepted"; exit 1
fi



# 7) The GraphQL payload carries `number` as a JSON number, not a string.
#    This is the transport the fractional change exists to fix; every other case
#    stops at --dry-run and never reaches it, so a regression to `gh -F` would
#    otherwise keep the suite green.
(
  SKILL_DIR="$HERE/.."
  CACHE_DIR="$SKILL_DIR/cache"
  GRAPHQL_DOC="$SKILL_DIR/epic-breakdown.graphql"
  SCRIPT_TAG="test"
  # shellcheck source=/dev/null
  . "$SKILL_DIR/_common.sh"
  PROJECT_ID=PROJ1 ITEM_ID=ITEM1
  for n in 5 0.5 1.25; do
    payload=$(number_payload FIELD1 "$n")
    [ "$(jq -r '.variables.number | type' <<<"$payload")" = "number" ] \
      || { echo "FAIL: payload number for '$n' is not a JSON number"; exit 1; }
    [ "$(jq -r '.variables.number' <<<"$payload")" = "$n" ] \
      || { echo "FAIL: payload number for '$n' did not round-trip"; exit 1; }
  done
  [ "$(jq -r '.variables.fieldId' <<<"$(number_payload FIELD1 1)")" = "FIELD1" ] \
    || { echo "FAIL: payload fieldId wrong"; exit 1; }
) || exit 1
echo "PASS"
