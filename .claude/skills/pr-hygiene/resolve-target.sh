#!/usr/bin/env bash
# Resolve a /pr-hygiene target into the refs the scan needs and print them as
# key=value lines. The target is a PR URL, a bare PR number, a branch name, or
# empty (current branch).
#
# Output keys: is_pr, number, url, base, head_ref, head_oid, diff_from, diff_to
# On a branch-only target, number and url are empty and is_pr=false, but
# head_ref and head_oid are still resolved so the caller's apply gate has
# something to compare the working tree against.
#
# Refuses a PR whose repository is not this clone's origin: the metadata would
# come from one repo and the diff from another.
#
# Dependencies: gh (scope: repo), git, jq.
set -euo pipefail

TARGET="${1-}"

log()  { echo "[pr-hygiene] $*" >&2; }
fail() { echo "error: $*" >&2; exit 1; }

command -v gh  >/dev/null 2>&1 || fail "gh not found on PATH"
command -v jq  >/dev/null 2>&1 || fail "jq not found on PATH"
git rev-parse --git-dir >/dev/null 2>&1 || fail "not inside a git repository"

PR_FIELDS='number,url,baseRefName,headRefName,headRefOid,headRepository,headRepositoryOwner'

# origin's owner/repo, used to reject a PR from a different repository.
ORIGIN_NWO="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"

is_pr=false
number=""
url=""
base=""
head_ref=""
head_oid=""
head_repo_nwo=""

pr_json=""
if [ -z "$TARGET" ]; then
  pr_json="$(gh pr view --json "$PR_FIELDS" 2>/dev/null || true)"
elif printf '%s' "$TARGET" | grep -qE '^([0-9]+|https?://)'; then
  pr_json="$(gh pr view "$TARGET" --json "$PR_FIELDS" 2>/dev/null || true)"
  [ -n "$pr_json" ] || fail "no PR found for target '$TARGET'"
else
  # A branch name. gh pr list returns an ARRAY; an empty array means no PR.
  list_json="$(gh pr list --head "$TARGET" --json "$PR_FIELDS" 2>/dev/null || echo '[]')"
  if [ "$(printf '%s' "$list_json" | jq 'length')" -gt 0 ]; then
    pr_json="$(printf '%s' "$list_json" | jq '.[0]')"
  fi
fi

if [ -n "$pr_json" ]; then
  is_pr=true
  number="$(printf '%s' "$pr_json"  | jq -r '.number')"
  url="$(printf '%s' "$pr_json"     | jq -r '.url')"
  base="$(printf '%s' "$pr_json"    | jq -r '.baseRefName')"
  head_ref="$(printf '%s' "$pr_json"| jq -r '.headRefName')"
  head_oid="$(printf '%s' "$pr_json"| jq -r '.headRefOid')"
  head_repo_nwo="$(printf '%s' "$pr_json" | jq -r '"\(.headRepositoryOwner.login)/\(.headRepository.name)"')"

  pr_nwo="$(printf '%s' "$url" | sed -E 's#https?://[^/]+/([^/]+/[^/]+)/pull/.*#\1#')"
  if [ -n "$ORIGIN_NWO" ] && [ "$pr_nwo" != "$ORIGIN_NWO" ]; then
    fail "PR $url belongs to $pr_nwo but this clone's origin is $ORIGIN_NWO.
  The diff would come from the local checkout while the metadata came from another repo.
  Run pr-hygiene from a clone of $pr_nwo."
  fi
else
  # Branch-only: no PR. Resolve the branch itself so the apply gate still works.
  head_ref="${TARGET:-$(git rev-parse --abbrev-ref HEAD)}"
  base="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)"
  [ -n "$base" ] || base=main
  [ "$head_ref" != "$base" ] || fail "target branch '$head_ref' is the base branch; nothing to diff"
fi

git fetch origin "$base" --quiet || fail "cannot fetch origin/$base"

# Fetch the head. A fork PR's head is not on origin, so fetch from the head
# repository directly; FETCH_HEAD then names it regardless of local branches.
if [ "$is_pr" = true ] && [ -n "$head_repo_nwo" ] && [ "$head_repo_nwo" != "$ORIGIN_NWO" ]; then
  log "fork PR: fetching $head_ref from $head_repo_nwo"
  git fetch "https://github.com/$head_repo_nwo.git" "$head_ref" --quiet \
    || fail "cannot fetch $head_ref from $head_repo_nwo"
  diff_to="$(git rev-parse FETCH_HEAD)"
elif git fetch origin "$head_ref" --quiet 2>/dev/null; then
  diff_to="$(git rev-parse FETCH_HEAD)"
else
  # Never pushed: fall back to the local ref.
  git rev-parse --verify --quiet "$head_ref" >/dev/null \
    || fail "branch '$head_ref' not found locally or on origin"
  diff_to="$(git rev-parse "$head_ref")"
fi

[ -n "$head_oid" ] || head_oid="$diff_to"

diff_from="$(git merge-base "$diff_to" "origin/$base")" \
  || fail "no merge base between $head_ref and origin/$base"

if [ "$diff_from" = "$diff_to" ]; then
  log "warn: diff is empty ($head_ref has no commits beyond origin/$base)"
fi

cat <<EOF
is_pr=$is_pr
number=$number
url=$url
base=$base
head_ref=$head_ref
head_oid=$head_oid
diff_from=$diff_from
diff_to=$diff_to
EOF
