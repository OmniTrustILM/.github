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
out=$(bash "$SCRIPT" --item-id ITEM1 --scope epic --complexity High --estimate 5 --dry-run 2>&1)
echo "$out" | grep -qi "Complexity=High" || { echo "FAIL: complexity not planned"; exit 1; }
echo "$out" | grep -qi "Estimate=5" || { echo "FAIL: estimate not planned"; exit 1; }

# 2) Quarter-day estimates are accepted, and the value survives to the preview.
#    0.25 is both the minimum and the increment; both decimal spellings of a
#    half day (0.5 and 0.50) are the same step and both pass.
for e in 0.25 0.5 0.50 0.75 1 1.25 2 3.75 100; do
  out=$(bash "$SCRIPT" --item-id ITEM1 --scope epic --estimate "$e" --dry-run 2>&1) \
    || { echo "FAIL: estimate '$e' rejected"; exit 1; }
  echo "$out" | grep -qi "Estimate=$e" || { echo "FAIL: estimate '$e' mangled in preview"; exit 1; }
done

# 3) Everything off the quarter-day grid is rejected by the validator, not by an
#    earlier guard. --complexity keeps the "nothing to set" guard from firing,
#    so these genuinely exercise estimate_is_valid.
#      0, 0.00  - not an estimate, but would clear the §3.2 gate
#      0.1, 1.4, 3.456, 0.333 - between the steps
#      100.25, 101 - above the release-capacity ceiling
#      abc, -1, 1e3, .5 - malformed
for e in 0 0.00 0.1 1.4 3.456 0.333 100.25 101 abc -1 1e3 .5; do
  out=$(bash "$SCRIPT" --item-id ITEM1 --scope epic --complexity Low --estimate "$e" --dry-run 2>&1)
  [ $? -ne 0 ] || { echo "FAIL: estimate '$e' accepted"; exit 1; }
  echo "$out" | grep -q "multiple of 0.25" \
    || { echo "FAIL: estimate '$e' rejected for the wrong reason: $out"; exit 1; }
  echo "$out" | grep -q "would: set" \
    && { echo "FAIL: preview printed a write for invalid estimate '$e'"; exit 1; }
done

# 4) An explicitly-passed empty estimate is its own error, distinct from
#    omitting the flag - breakdown passes --estimate for every child.
out=$(bash "$SCRIPT" --item-id ITEM1 --scope epic --complexity Low --estimate "" --dry-run 2>&1)
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

# 6b) --scope is mandatory when --estimate is given, so the ceiling is never
#     picked by omission (a child write missing the flag must not default to epic).
if bash "$SCRIPT" --item-id ITEM1 --estimate 40 --dry-run >/dev/null 2>&1; then
  echo "FAIL: --estimate without --scope accepted"; exit 1
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
  # shellcheck source-path=SCRIPTDIR source=../_common.sh
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


# 8) Scope selects the estimate ceiling (§3.5): epic 100, child 4 (agent-executed).
bash "$SCRIPT" --item-id ITEM1 --scope child --estimate 4 --dry-run >/dev/null 2>&1 \
  || { echo "FAIL: 4 rejected at child scope"; exit 1; }
bash "$SCRIPT" --item-id ITEM1 --scope epic --estimate 100 --dry-run >/dev/null 2>&1 \
  || { echo "FAIL: 100 rejected at epic scope"; exit 1; }
out=$(bash "$SCRIPT" --item-id ITEM1 --scope epic --estimate 101 --dry-run 2>&1)
[ $? -ne 0 ] || { echo "FAIL: 101 accepted at epic scope"; exit 1; }
out=$(bash "$SCRIPT" --item-id ITEM1 --scope banana --estimate 1 --dry-run 2>&1)
[ $? -ne 0 ] || { echo "FAIL: bogus scope accepted"; exit 1; }

# An over-cap child is allowed but must be flagged; an off-grid value must still
# fail on the grid rather than on the missing rationale.
out=$(bash "$SCRIPT" --item-id ITEM1 --scope child --estimate 6 --dry-run 2>&1) \
  || { echo "FAIL: over-cap child rejected outright in dry-run"; exit 1; }
echo "$out" | grep -q "exceeds the 4-manday child cap" \
  || { echo "FAIL: over-cap child not flagged: $out"; exit 1; }
out=$(bash "$SCRIPT" --item-id ITEM1 --scope child --estimate 5.3 --dry-run 2>&1)
echo "$out" | grep -q "multiple of 0.25" \
  || { echo "FAIL: off-grid child failed for the wrong reason: $out"; exit 1; }

# 8b) developer-built basis raises the child cap to 10: 8 is under cap (no flag),
#     11 is over cap (flagged against the 10-manday ceiling), bogus basis rejected.
bash "$SCRIPT" --item-id ITEM1 --scope child --basis developer-built --estimate 8 --dry-run >/dev/null 2>&1 \
  || { echo "FAIL: 8 rejected under developer-built child cap"; exit 1; }
out=$(bash "$SCRIPT" --item-id ITEM1 --scope child --basis developer-built --estimate 11 --dry-run 2>&1) \
  || { echo "FAIL: over-cap developer-built child rejected outright in dry-run"; exit 1; }
echo "$out" | grep -q "exceeds the 10-manday child cap" \
  || { echo "FAIL: developer-built over-cap not flagged against 10: $out"; exit 1; }
out=$(bash "$SCRIPT" --item-id ITEM1 --scope child --basis banana --estimate 1 --dry-run 2>&1)
[ $? -ne 0 ] || { echo "FAIL: bogus basis accepted"; exit 1; }

# 9) The over-cap rationale is read from the issue body, not taken on trust.
(
  SKILL_DIR="$HERE/.."
  SCRIPT_TAG="test"
  # shellcheck source-path=SCRIPTDIR source=../_common.sh
  . "$SKILL_DIR/_common.sh"

  estimate_rationale_ok "## Description
Some work.
### Estimate
Single Flyway migration that cannot be applied in halves without leaving the
schema inconsistent between steps."
  [ $? -eq 0 ] || { echo "FAIL: valid rationale rejected"; exit 1; }

  estimate_rationale_ok "## Description
No estimate section here at all."
  [ $? -eq 1 ] || { echo "FAIL: missing section not reported as missing"; exit 1; }

  estimate_rationale_ok "### Estimate

### Acceptance criteria
- [ ] x"
  [ $? -eq 2 ] || { echo "FAIL: empty section not reported as empty"; exit 1; }

  estimate_rationale_ok "### Estimate
too short"
  [ $? -eq 2 ] || { echo "FAIL: stub rationale accepted"; exit 1; }
) || exit 1
# 10) An integer part large enough to wrap 64-bit arithmetic must not land back
#     inside the cap. 4611686018427387905 * 4 is 4 in bash.
(
  SKILL_DIR="$HERE/.."
  SCRIPT_TAG="test"
  # shellcheck source-path=SCRIPTDIR source=../_common.sh
  . "$SKILL_DIR/_common.sh"
  for v in 4611686018427387905 9223372036854775807 1000000 100000; do
    if estimate_is_valid "$v" "$ESTIMATE_MAX_EPIC"; then
      echo "FAIL: oversized estimate '$v' accepted"; exit 1
    fi
  done
) || exit 1

# 11) set_number's guard is the hard Epic ceiling, not the caller's scope cap.
#     An over-cap child that cleared the rationale rule must still be writable;
#     re-applying the child cap here would make the escape hatch dead code.
(
  SKILL_DIR="$HERE/.."
  SCRIPT_TAG="test"
  # shellcheck source-path=SCRIPTDIR source=../_common.sh
  . "$SKILL_DIR/_common.sh"
  ESTIMATE_MAX=4   # what set-epic-fields.sh sets for --scope child (agent-executed)
  if estimate_is_valid 6 "$ESTIMATE_MAX"; then
    echo "FAIL: 6 is not over the child cap - test asserts nothing"; exit 1
  fi
  estimate_writable 6 || { echo "FAIL: approved over-cap child is not writable"; exit 1; }
  estimate_writable 100 || { echo "FAIL: 100 not writable"; exit 1; }
  if estimate_writable 101; then echo "FAIL: 101 writable"; exit 1; fi
  if estimate_writable 0; then echo "FAIL: 0 writable"; exit 1; fi
) || exit 1

echo "PASS"
