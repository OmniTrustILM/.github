#!/usr/bin/env bash
# Decide whether a review run should proceed, and resolve what it will review.
#
# This runs BEFORE any App token is minted, so it must not need one. That
# ordering is the point: fork rejection and command validation cannot be
# protected by a credential they precede, and a run that is going to stop should
# stop before it mints tokens and clones two repositories.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

SKIP_AUTHORS="renovate[bot] dependabot[bot]"
DEFAULT_EFFORT="standard"

stop() { log "skipping: $*"; set_output proceed false; exit 0; }

effort="$DEFAULT_EFFORT"
full=false

case "${GITHUB_EVENT_NAME:-}" in
  pull_request)
    pr=$(jq -r '.pull_request.number'                    "$GITHUB_EVENT_PATH")
    draft=$(jq -r '.pull_request.draft'                  "$GITHUB_EVENT_PATH")
    author=$(jq -r '.pull_request.user.login'            "$GITHUB_EVENT_PATH")
    head_sha=$(jq -r '.pull_request.head.sha'            "$GITHUB_EVENT_PATH")
    head_repo=$(jq -r '.pull_request.head.repo.full_name' "$GITHUB_EVENT_PATH")
    base_ref=$(jq -r '.pull_request.base.ref'            "$GITHUB_EVENT_PATH")
    [ "$draft" = "false" ] || stop "pull request is a draft"
    ;;

  issue_comment)
    body=$(jq -r '.comment.body' "$GITHUB_EVENT_PATH")
    # The workflow `if:` can only test startsWith, so the grammar is enforced
    # here: "/reviewers please look" must not spend a review.
    [[ "$body" =~ ^/review([[:space:]]+([a-z]+))?([[:space:]]+full)?[[:space:]]*$ ]] \
      || stop "comment is not the review command"

    requested="${BASH_REMATCH[2]:-}"
    if [ -n "$requested" ] && [ "$requested" != full ]; then
      # An unrecognised effort is a typo, and silently running `standard`
      # would hide it. `/review deep` mistyped should say so, not quietly
      # review at a shallower setting than the author asked for.
      case "$requested" in
        light|standard|deep) effort="$requested" ;;
        *) stop "unknown effort '${requested}' - use light, standard or deep" ;;
      esac
    fi
    [[ "$body" =~ [[:space:]]full[[:space:]]*$ ]] && full=true

    pr=$(jq -r '.issue.number' "$GITHUB_EVENT_PATH")
    meta=$(gh api "repos/${GITHUB_REPOSITORY}/pulls/${pr}")
    state=$(jq -r '.state'                   <<<"$meta")
    author=$(jq -r '.user.login'             <<<"$meta")
    head_sha=$(jq -r '.head.sha'             <<<"$meta")
    head_repo=$(jq -r '.head.repo.full_name' <<<"$meta")
    base_ref=$(jq -r '.base.ref'             <<<"$meta")
    [ "$state" = "open" ] || stop "pull request is not open"
    ;;

  *) stop "unsupported event: ${GITHUB_EVENT_NAME:-none}" ;;
esac

# Fork content must never reach a job holding secrets. A fork `pull_request`
# gets no secrets at all, but `issue_comment` runs in base-repo context with the
# full set - so this check belongs on both paths, not just the obvious one.
[ "$head_repo" = "$GITHUB_REPOSITORY" ] || stop "head is a fork: $head_repo"

for bot in $SKIP_AUTHORS; do
  [ "$author" = "$bot" ] && stop "author is on the skip list: $author"
done

set_output proceed true
set_output pr-number "$pr"
set_output head-sha "$head_sha"
set_output base-ref "$base_ref"
set_output effort "$effort"
set_output full "$full"
log "proceeding: PR #${pr} at ${head_sha:0:7}, effort=${effort}, full=${full}"
