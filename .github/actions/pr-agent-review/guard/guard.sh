#!/usr/bin/env bash
# Decide whether a review run should proceed, and resolve what it will review.
#
# This runs before the App token is minted, so nothing here can depend on one.
# That ordering is the point: fork rejection, authorization and command
# validation must not be protected by a credential they precede, and a run that
# is going to stop should stop before minting tokens and cloning repositories.
#
# It does need a *read* token for the issue_comment path, where the pull request
# has to be fetched - that is the workflow's own GITHUB_TOKEN, supplied by
# action.yml, never the App token.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# Quoted array, not a bare string: `renovate[bot]` is a valid glob, so an
# unquoted expansion silently becomes a filename when one happens to match and
# the skip fails open.
SKIP_AUTHORS=("renovate[bot]" "dependabot[bot]")
ALLOWED_ASSOCIATIONS=("OWNER" "MEMBER" "COLLABORATOR")
DEFAULT_EFFORT="standard"

stop() { log "skipping: $*"; set_output proceed false; exit 0; }

[ -r "${GITHUB_EVENT_PATH:-}" ] || die "no readable event payload at GITHUB_EVENT_PATH"

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

    # Automatic reviews of dependency PRs are not worth their cost. This gates
    # the automatic path only - an explicit /ilm-review is a deliberate
    # request and overrides it, the same way it overrides the draft check.
    for bot in "${SKIP_AUTHORS[@]}"; do
      [ "$author" = "$bot" ] && stop "author is on the skip list: $author"
    done
    ;;

  issue_comment)
    # issue_comment fires for plain issues too, where there is no pull request
    # to fetch. Checking the payload is free; letting the API 404 would abort
    # under set -e with no proceed output at all, turning a comment anyone can
    # write into a red run.
    jq -e '.issue.pull_request' "$GITHUB_EVENT_PATH" >/dev/null 2>&1 \
      || stop "comment is not on a pull request"

    # Authorization. The workflow `if:` filters on this too, but so did the
    # fork check, and it is duplicated here for the same reason: this is the
    # gate that decides whether a privileged run starts, and on a public repo
    # any account can comment. Read from the payload, so it still costs no
    # credential.
    assoc=$(jq -r '.comment.author_association // ""' "$GITHUB_EVENT_PATH")
    allowed=false
    for a in "${ALLOWED_ASSOCIATIONS[@]}"; do
      [ "$assoc" = "$a" ] && allowed=true
    done
    [ "$allowed" = true ] || stop "commenter association '${assoc:-none}' may not start a review"

    # Only the first line is the command. [[:space:]] matches newlines, so
    # without this a word on the second line of a comment that opens with the
    # command would be read as the effort, and a browser-submitted comment
    # carries a trailing CR.
    body=$(jq -r '.comment.body' "$GITHUB_EVENT_PATH")
    body=${body%%$'\n'*}
    body=${body%$'\r'}

    [[ "$body" =~ ^/ilm-review([[:space:]]+([A-Za-z]+))?([[:space:]]+full)?[[:space:]]*$ ]] \
      || stop "comment is not the review command"

    requested="${BASH_REMATCH[2]:-}"
    full_token="${BASH_REMATCH[3]:-}"
    [ -n "$full_token" ] && full=true

    if [ -n "$requested" ]; then
      # `/review full` puts full in the effort slot; `/review full full` would
      # then set it twice, which is not the grammar and should not spend a run.
      if [ "${requested,,}" = full ]; then
        [ -n "$full_token" ] && stop "malformed command: 'full' given twice"
        full=true
      else
        # An unrecognised effort is a typo; running `standard` silently would
        # review at a different depth than was asked for. Matched
        # case-insensitively so `/ilm-review Deep` lands here, not on the
        # vaguer "not the review command".
        case "${requested,,}" in
          light|standard|deep) effort="${requested,,}" ;;
          *) stop "unknown effort '${requested}' - use light, standard or deep" ;;
        esac
      fi
    fi

    pr=$(jq -r '.issue.number' "$GITHUB_EVENT_PATH")
    meta=$(gh api "repos/${GITHUB_REPOSITORY}/pulls/${pr}") \
      || stop "could not resolve pull request #${pr}"
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
# full set - so this belongs on both paths, not just the obvious one.
[ "$head_repo" = "$GITHUB_REPOSITORY" ] || stop "head is a fork: $head_repo"

set_output proceed true
set_output pr-number "$pr"
set_output head-sha "$head_sha"
set_output base-ref "$base_ref"
set_output effort "$effort"
set_output full "$full"
log "proceeding: PR #${pr} at ${head_sha:0:7}, effort=${effort}, full=${full}"
