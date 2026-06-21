#!/usr/bin/env bash
# Link a sub-issue to its parent Epic (addSubIssue) or set a blocked-by
# dependency (addBlockedBy). For sub-issue linking it re-checks the child's
# current parent first, so reconcile re-runs are idempotent. On failure it
# prints a copy-paste manual fix and appends to cache/orphans.log.
#
# Usage (exactly one mode):
#   link.sh --parent-node-id <id> --child-node-id <id>       [--dry-run]
#   link.sh --issue-node-id  <id> --blocked-by-node-id <id>  [--dry-run]
#
# Node IDs are GitHub GraphQL issue node ids (the node_id= line from
# create-issue-generic.sh), not issue numbers.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="$SKILL_DIR/cache"
GRAPHQL_DOC="$SKILL_DIR/epic-breakdown.graphql"
SCRIPT_TAG="link"
# shellcheck source-path=SCRIPTDIR source=_common.sh
. "$SKILL_DIR/_common.sh"

PARENT="" CHILD="" ISSUE="" BLOCKER="" DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --parent-node-id)     PARENT="${2:-}"; shift 2 ;;
    --child-node-id)      CHILD="${2:-}"; shift 2 ;;
    --issue-node-id)      ISSUE="${2:-}"; shift 2 ;;
    --blocked-by-node-id) BLOCKER="${2:-}"; shift 2 ;;
    --dry-run)            DRY_RUN=1; shift ;;
    *)                    fail "unknown arg: $1" ;;
  esac
done

if [ -n "$PARENT" ] || [ -n "$CHILD" ]; then
  MODE="subissue"
  { [ -n "$PARENT" ] && [ -n "$CHILD" ]; } || fail "sub-issue mode needs --parent-node-id and --child-node-id"
  { [ -n "$ISSUE" ] || [ -n "$BLOCKER" ]; } && fail "cannot mix sub-issue and blocked-by args"
elif [ -n "$ISSUE" ] || [ -n "$BLOCKER" ]; then
  MODE="blockedby"
  { [ -n "$ISSUE" ] && [ -n "$BLOCKER" ]; } || fail "blocked-by mode needs --issue-node-id and --blocked-by-node-id"
else
  fail "nothing to do: pass a sub-issue pair or a blocked-by pair"
fi

if [ "$MODE" = "subissue" ]; then
  if [ "$DRY_RUN" -eq 1 ]; then log "DRY-RUN would: addSubIssue parent=$PARENT child=$CHILD"; exit 0; fi
  CUR_PARENT=$(gh api graphql -f query="$(gql_op IssueParent)" -f id="$CHILD" \
    --jq '.data.node.parent.id // ""' 2>/dev/null || echo "")
  if [ "$CUR_PARENT" = "$PARENT" ]; then log "already linked to this parent — skipping"; exit 0; fi
  if [ -n "$CUR_PARENT" ]; then log "warn: child already has a different parent ($CUR_PARENT); addSubIssue will reparent only if replaceParent is set — skipping to be safe"; exit 0; fi
  if ! gh api graphql -f query="$(gql_op AddSubIssue)" -f issueId="$PARENT" -f subIssueId="$CHILD" >/dev/null 2>&1; then
    printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$CHILD" "addSubIssue->$PARENT failed" >> "$CACHE_DIR/orphans.log"
    log "manual fix: gh api graphql -f query='mutation{addSubIssue(input:{issueId:\"$PARENT\",subIssueId:\"$CHILD\"}){issue{number}}}'"
    fail "addSubIssue failed; child created but not linked (logged to orphans.log)."
  fi
  log "linked child $CHILD under parent $PARENT"
else
  if [ "$DRY_RUN" -eq 1 ]; then log "DRY-RUN would: addBlockedBy issue=$ISSUE blockedBy=$BLOCKER"; exit 0; fi
  if ! ERR=$(gh api graphql -f query="$(gql_op AddBlockedBy)" -f issueId="$ISSUE" -f blockingIssueId="$BLOCKER" 2>&1); then
    # On reconcile re-runs the relationship may already exist — treat as a no-op.
    if printf '%s' "$ERR" | grep -qiE 'already|exist|duplicat'; then
      log "blocked-by already set — skipping"; exit 0
    fi
    printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$ISSUE" "addBlockedBy<-$BLOCKER failed" >> "$CACHE_DIR/orphans.log"
    log "manual fix: gh api graphql -f query='mutation{addBlockedBy(input:{issueId:\"$ISSUE\",blockingIssueId:\"$BLOCKER\"}){issue{number}}}'"
    fail "addBlockedBy failed (logged to orphans.log): $ERR"
  fi
  log "set $ISSUE blocked-by $BLOCKER"
fi
