#!/usr/bin/env bash
# Set Complexity (single-select) and/or Estimate (NUMBER, fractional mandays
# allowed) on an Epic's or child's Project #5 item. epic-breakdown is the
# sanctioned writer of these per §3.1/§3.5 (Complexity auto-set; Epic Estimate
# PM-owned, written here behind the breakdown approval gate). Child Estimate is
# written from the approved breakdown preview; see §3.5 for ownership and the
# reconcile-mode overwrite rule.
#
# Usage:
#   set-epic-fields.sh --item-id <projectItemId> [--complexity Low|Medium|High]
#                      [--estimate <mandays>] [--scope epic|child]
#                      [--basis agent-executed|developer-built] [--dry-run]
#
# --scope selects the estimate ceiling (epic 100; child 4 agent-executed, or 10
# developer-built - see §3.5). It is REQUIRED whenever --estimate is given, so
# the ceiling can never be picked by omission. --basis defaults to agent-executed
# and only affects the child ceiling. A child over its cap needs an '### Estimate'
# section in the issue body explaining why it cannot be split.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="$SKILL_DIR/cache"
GRAPHQL_DOC="$SKILL_DIR/epic-breakdown.graphql"
SCRIPT_TAG="fields"
# shellcheck source-path=SCRIPTDIR source=_common.sh
. "$SKILL_DIR/_common.sh"

[ -f "$CACHE_DIR/project-fields.json" ] || fail "missing $CACHE_DIR/project-fields.json — run fetch.sh first"

ITEM_ID="" COMPLEXITY="" ESTIMATE="" ESTIMATE_SET=0 SCOPE="" BASIS=agent-executed DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --item-id)    ITEM_ID="${2:-}"; shift 2 ;;
    --complexity) COMPLEXITY="${2:-}"; shift 2 ;;
    --estimate)   ESTIMATE="${2:-}"; ESTIMATE_SET=1; shift 2 ;;
    --scope)      SCOPE="${2:-}"; shift 2 ;;
    --basis)      BASIS="${2:-}"; shift 2 ;;
    --dry-run)    DRY_RUN=1; shift ;;
    *)            fail "unknown arg: $1" ;;
  esac
done

# --scope is mandatory when an estimate is written, so the ceiling is never
# picked by omission (a child write missing the flag would otherwise validate
# against the 100-manday Epic ceiling and skip the rationale check). Without an
# estimate it defaults to epic — the ceiling is unused in that case.
if [ "$ESTIMATE_SET" -eq 1 ] && [ -z "$SCOPE" ]; then
  fail "--scope is required when --estimate is given (epic or child)"
fi
[ -n "$SCOPE" ] || SCOPE=epic

case "$BASIS" in
  agent-executed|developer-built) ;;
  *) fail "--basis must be agent-executed or developer-built, got '$BASIS'" ;;
esac

case "$SCOPE" in
  epic)  ESTIMATE_MAX="$ESTIMATE_MAX_EPIC" ;;
  child)
    if [ "$BASIS" = developer-built ]; then
      ESTIMATE_MAX="$ESTIMATE_MAX_CHILD_DEVBUILT"
    else
      ESTIMATE_MAX="$ESTIMATE_MAX_CHILD"
    fi ;;
  *)     fail "--scope must be epic or child, got '$SCOPE'" ;;
esac

[ -n "$ITEM_ID" ] || fail "--item-id is required"
# Supplied-but-empty is a caller bug, not "no estimate requested". Breakdown
# passes --estimate for every child, so an unresolved value would otherwise
# skip the field silently and still report success.
[ "$ESTIMATE_SET" -eq 1 ] && [ -z "$ESTIMATE" ] && fail "--estimate requires a value"
{ [ -n "$COMPLEXITY" ] || [ -n "$ESTIMATE" ]; } || fail "nothing to set: pass --complexity and/or --estimate"

# Validate before anything is printed or written. Breakdown calls this once per
# child, so a late failure would abort the sequence with Complexity already set
# and Estimate missing. The dry-run preview must not print a write it is about
# to reject either.
#
# A child over its cap is not rejected outright: it is allowed when the issue
# body says why it cannot be split. Check the shape first, then the rationale,
# so an off-grid value fails on the grid rather than on a missing section.
if [ -n "$ESTIMATE" ]; then
  estimate_is_valid "$ESTIMATE" "$ESTIMATE_MAX_EPIC" \
    || fail "$(estimate_rule_msg "$ESTIMATE_MAX_EPIC"), got '$ESTIMATE'"
  if ! estimate_is_valid "$ESTIMATE" "$ESTIMATE_MAX"; then
    [ "$SCOPE" = child ] \
      || fail "$(estimate_rule_msg "$ESTIMATE_MAX"), got '$ESTIMATE'"
    if [ "$DRY_RUN" -eq 1 ]; then
      log "note: ${ESTIMATE} exceeds the ${ESTIMATE_MAX}-manday child cap; the live run requires an '### Estimate' section in the issue body"
    else
      require_estimate_rationale "$ITEM_ID" "$ESTIMATE" "$ESTIMATE_MAX"
      log "  note: ${ESTIMATE} exceeds the ${ESTIMATE_MAX}-manday child cap; accepted on the issue's stated rationale"
    fi
  fi
fi

PROJECT_ID=$(jq -r '.project_id' "$CACHE_DIR/project-fields.json")

if [ "$DRY_RUN" -eq 1 ]; then
  log "DRY-RUN — no mutations"
  [ -n "$COMPLEXITY" ] && log "would: set Complexity=$COMPLEXITY on item $ITEM_ID"
  [ -n "$ESTIMATE" ]   && log "would: set Estimate=$ESTIMATE on item $ITEM_ID"
  exit 0
fi

require_project_scope

RC=0
[ -n "$COMPLEXITY" ] && { set_single_select "Complexity" "$COMPLEXITY" || RC=1; }
[ -n "$ESTIMATE" ]   && { set_number "Estimate" "$ESTIMATE" || RC=1; }
exit "$RC"
