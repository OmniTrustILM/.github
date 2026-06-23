#!/usr/bin/env bash
# Set Complexity (single-select) and/or Estimate (NUMBER, whole mandays) on an
# Epic's or child's Project #5 item. epic-breakdown is the sanctioned writer of
# these per §3.1/§3.5 (Complexity auto-set; Epic Estimate PM-owned, written here
# behind the breakdown approval gate). Child Estimate is suggest-only and is NOT
# written by the skill — do not call this for a child's Estimate.
#
# Usage:
#   set-epic-fields.sh --item-id <projectItemId> [--complexity Low|Medium|High] [--estimate <int>] [--dry-run]
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="$SKILL_DIR/cache"
GRAPHQL_DOC="$SKILL_DIR/epic-breakdown.graphql"
SCRIPT_TAG="fields"
# shellcheck source-path=SCRIPTDIR source=_common.sh
. "$SKILL_DIR/_common.sh"

[ -f "$CACHE_DIR/project-fields.json" ] || fail "missing $CACHE_DIR/project-fields.json — run fetch.sh first"

ITEM_ID="" COMPLEXITY="" ESTIMATE="" DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --item-id)    ITEM_ID="${2:-}"; shift 2 ;;
    --complexity) COMPLEXITY="${2:-}"; shift 2 ;;
    --estimate)   ESTIMATE="${2:-}"; shift 2 ;;
    --dry-run)    DRY_RUN=1; shift ;;
    *)            fail "unknown arg: $1" ;;
  esac
done

[ -n "$ITEM_ID" ] || fail "--item-id is required"
{ [ -n "$COMPLEXITY" ] || [ -n "$ESTIMATE" ]; } || fail "nothing to set: pass --complexity and/or --estimate"

PROJECT_ID=$(jq -r '.project_id' "$CACHE_DIR/project-fields.json")

if [ "$DRY_RUN" -eq 1 ]; then
  log "DRY-RUN — no mutations"
  [ -n "$COMPLEXITY" ] && log "would: set Complexity=$COMPLEXITY on item $ITEM_ID"
  [ -n "$ESTIMATE" ]   && log "would: set Estimate=$ESTIMATE on item $ITEM_ID"
  # Validate the estimate is a whole number even in dry-run so the preview can't lie.
  if [ -n "$ESTIMATE" ] && ! [[ "$ESTIMATE" =~ ^[0-9]+$ ]]; then fail "estimate must be a whole number of mandays, got '$ESTIMATE'"; fi
  exit 0
fi

require_project_scope

RC=0
[ -n "$COMPLEXITY" ] && { set_single_select "Complexity" "$COMPLEXITY" || RC=1; }
[ -n "$ESTIMATE" ]   && { set_number "Estimate" "$ESTIMATE" || RC=1; }
exit "$RC"
