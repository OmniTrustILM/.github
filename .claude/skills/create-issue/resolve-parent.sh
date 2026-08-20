#!/usr/bin/env bash
# Resolve the parent issue a new issue should be linked under.
#
# Modes (exactly one):
#   resolve-parent.sh --cycles
#       List the open `Bugs x.y.z` issues in OmniTrustILM/ilm, sorted
#       numerically per version component. JSON object on stdout.
#   resolve-parent.sh --issue NUMBER [--repo NAME]
#       Resolve one issue by number (default repo: ilm) to its node id and
#       title. key=value lines on stdout.
#
# Both modes report parent_writable and the parent's sub-issue capacity.
#
# Authorization: addSubIssue is a write on the *parent* issue — the REST
#   equivalent is POST /repos/{owner}/{repo}/issues/{n}/sub_issues, where the
#   repo in the path is the parent's. A cross-repo link therefore needs push on
#   the parent's repo, not on the repo the new issue lands in.
# Timing: checked here, before `gh issue create`, so the preview can warn while
#   the run is still cancellable.
# Constraint: GitHub requires parent and sub-issue to share a repository owner,
#   which holds for every org repo.
#
# Read-only. Creates nothing, links nothing; create.sh does the linking.
set -euo pipefail

ORG="OmniTrustILM"
DEFAULT_PARENT_REPO="ilm"
# GitHub caps a parent at 100 sub-issues. A cycle at the cap accepts no more,
# so addSubIssue would fail *after* the issue was already created.
SUB_ISSUE_LIMIT=100

log()  { echo "[parent] $*" >&2; }
fail() { echo "error: $*" >&2; exit 1; }

MODE="" ISSUE_NUMBER="" PARENT_REPO="$DEFAULT_PARENT_REPO"
while [ $# -gt 0 ]; do
  case "$1" in
    --cycles) MODE="cycles"; shift ;;
    --issue)  MODE="issue"; ISSUE_NUMBER="${2:-}"; shift 2 ;;
    --repo)   PARENT_REPO="${2:-}"; shift 2 ;;
    *)        fail "unknown arg: $1" ;;
  esac
done

[ -n "$MODE" ] || fail "nothing to do: pass --cycles or --issue NUMBER"
[ -n "$PARENT_REPO" ] || fail "--repo needs a value"

# Can the caller write to the parent's repo? Three states, because a token
# whose permissions the API does not report must not raise a false alarm:
# true / false / unknown. Only an explicit false is worth warning about, and it
# has to survive the mapping below rather than collapse into the null case.
#
# Triage maps to `unknown`, not `false`. GitHub does not document whether the
# triage role can add sub-issues, so neither answer is safe to assert: `true`
# would promise a link the API may still reject, `false` warns a user who can
# most likely link fine. `unknown` stays quiet and lets the API decide.
parent_writable() {
  local repo="$1" perms
  perms=$(gh api "repos/$ORG/$repo" \
    --jq '.permissions
          | if (.push // false)   then "true"
            elif (.triage // false) then "unknown"
            elif (.push | type) == "boolean" then "false"
            else "unknown" end' \
    2>/dev/null || echo "unknown")
  case "$perms" in
    true|false) printf '%s' "$perms" ;;
    *)          printf 'unknown' ;;
  esac
}

if [ "$MODE" = "cycles" ]; then
  log "listing open bug cycles in $ORG/$DEFAULT_PARENT_REPO"

  # Paginate: ilm carries well over 100 open issues, and a cycle that falls
  # outside the first page would silently reduce the candidate list — which the
  # caller reads as "exactly one open cycle" and takes without asking.
  CYCLES="[]"
  CURSOR=""
  PAGE_COUNT=0
  while :; do
    PAGE=$(gh api graphql -f query='
      query($owner: String!, $name: String!, $after: String) {
        repository(owner: $owner, name: $name) {
          issues(states: OPEN, first: 100, after: $after, orderBy: { field: CREATED_AT, direction: DESC }) {
            pageInfo { hasNextPage endCursor }
            nodes { number title id subIssues(first: 1) { totalCount } }
          }
        }
      }' -f owner="$ORG" -f name="$DEFAULT_PARENT_REPO" \
      ${CURSOR:+-f after="$CURSOR"}) \
      || fail "failed to list bug cycles in $ORG/$DEFAULT_PARENT_REPO"

    CYCLES=$(jq -n --argjson acc "$CYCLES" --argjson page "$PAGE" --argjson limit "$SUB_ISSUE_LIMIT" \
      '$acc + [ $page.data.repository.issues.nodes[]
                | select(.title | test("^Bugs [0-9]+\\.[0-9]+\\.[0-9]+$"))
                | { version: (.title | ltrimstr("Bugs ")), number, node_id: .id,
                    sub_issues: .subIssues.totalCount,
                    full: (.subIssues.totalCount >= $limit) } ]')

    PAGE_COUNT=$((PAGE_COUNT + 1))
    [ "$(printf '%s' "$PAGE" | jq -r '.data.repository.issues.pageInfo.hasNextPage')" = "true" ] || break
    # Guard against an unbounded loop if the cursor ever stops advancing.
    [ "$PAGE_COUNT" -lt 20 ] || { log "  warn: stopped after $PAGE_COUNT pages; cycle list may be incomplete"; break; }
    CURSOR=$(printf '%s' "$PAGE" | jq -r '.data.repository.issues.pageInfo.endCursor')
  done

  CYCLES=$(printf '%s' "$CYCLES" | jq 'sort_by(.version | split(".") | map(tonumber))')

  COUNT=$(printf '%s' "$CYCLES" | jq 'length')
  FULL_COUNT=$(printf '%s' "$CYCLES" | jq '[.[] | select(.full)] | length')
  log "  $COUNT open cycle(s), $FULL_COUNT at the $SUB_ISSUE_LIMIT sub-issue limit"

  jq -n --arg repo "$DEFAULT_PARENT_REPO" \
        --arg writable "$(parent_writable "$DEFAULT_PARENT_REPO")" \
        --argjson limit "$SUB_ISSUE_LIMIT" \
        --argjson cycles "$CYCLES" \
        '{ parent_repo: $repo, parent_writable: $writable, sub_issue_limit: $limit, cycles: $cycles }'
  exit 0
fi

# --issue: resolve one issue by number.
printf '%s' "$ISSUE_NUMBER" | grep -qE '^[0-9]+$' || fail "--issue needs a number, got: ${ISSUE_NUMBER:-(empty)}"

log "resolving $ORG/$PARENT_REPO#$ISSUE_NUMBER"
ERR_FILE=$(mktemp)
trap 'rm -f "$ERR_FILE"' EXIT

# A missing issue is a GraphQL error, not a null node, so separate the two:
# "does not exist" tells the caller to ask for another number, while any other
# failure is a real problem worth surfacing verbatim.
if ! RESOLVED=$(gh api graphql -f query='
  query($owner: String!, $name: String!, $number: Int!) {
    repository(owner: $owner, name: $name) {
      issue(number: $number) { id title state subIssues(first: 1) { totalCount } }
    }
  }' -f owner="$ORG" -f name="$PARENT_REPO" -F number="$ISSUE_NUMBER" \
  --jq '.data.repository.issue // empty' 2>"$ERR_FILE"); then
  if grep -qi "Could not resolve to an Issue" "$ERR_FILE"; then
    fail "issue $ORG/$PARENT_REPO#$ISSUE_NUMBER does not exist"
  fi
  cat "$ERR_FILE" >&2
  fail "failed to query $ORG/$PARENT_REPO#$ISSUE_NUMBER"
fi
[ -n "$RESOLVED" ] || fail "issue $ORG/$PARENT_REPO#$ISSUE_NUMBER does not exist"

echo "parent_repo=$PARENT_REPO"
echo "parent_number=$ISSUE_NUMBER"
echo "parent_node_id=$(printf '%s' "$RESOLVED" | jq -r '.id')"
echo "parent_title=$(printf '%s' "$RESOLVED" | jq -r '.title')"
echo "parent_state=$(printf '%s' "$RESOLVED" | jq -r '.state')"
echo "parent_sub_issues=$(printf '%s' "$RESOLVED" | jq -r '.subIssues.totalCount')"
echo "parent_full=$(printf '%s' "$RESOLVED" | jq -r --argjson limit "$SUB_ISSUE_LIMIT" \
  'if .subIssues.totalCount >= $limit then "true" else "false" end')"
echo "parent_writable=$(parent_writable "$PARENT_REPO")"
