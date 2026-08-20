#!/usr/bin/env bash
# Self-contained test for resolve-target.sh. Exercises the branches that need
# no network - --worktree and the dependency guards - in throwaway repos, and
# pins the eight-key stdout contract callers parse.
#
# Run locally: bash .claude/skills/pr-hygiene/resolve-target.test.sh
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
resolve="$script_dir/resolve-target.sh"

# Ignore the developer's own git config: a global commit.gpgsign or
# init.templateDir would otherwise change what these repos look like.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

failures=0
workdirs=()

# assert_eq <description> <expected> <actual>
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "ok - $desc"
  else
    echo "FAIL - $desc (expected '$expected', got '$actual')"
    failures=$((failures + 1))
  fi
}

# assert_contains <description> <needle> <haystack>
assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*) echo "ok - $desc" ;;
    *) echo "FAIL - $desc (expected to find '$needle' in '$haystack')"
       failures=$((failures + 1)) ;;
  esac
}

# new_repo [seed] -> path to a fresh repo on branch main, optionally with a commit
new_repo() {
  local d
  d="$(mktemp -d)"
  workdirs+=("$d")
  git -C "$d" init --quiet
  git -C "$d" symbolic-ref HEAD refs/heads/main
  git -C "$d" config user.email test@example.com
  git -C "$d" config user.name "pr-hygiene tests"
  if [ "${1-}" = seed ]; then
    printf 'one\n' > "$d/tracked.txt"
    git -C "$d" add tracked.txt
    git -C "$d" commit --quiet -m "seed"
  fi
  printf '%s\n' "$d"
}

# expected_keys <head_oid> -> the eight key=value lines a --worktree run prints
expected_keys() {
  printf 'is_pr=false\nnumber=\nurl=\nbase=\nhead_ref=main\nhead_oid=%s\ndiff_from=%s\ndiff_to=WORKTREE' "$1" "$1"
}

err="$(mktemp)"

# ---------------------------------------------------------------------------
# Case 1: outside a git repository -> hard stop, stdout stays clean.
# ---------------------------------------------------------------------------
outside="$(mktemp -d)"
workdirs+=("$outside")
out="$(cd "$outside" && GIT_CEILING_DIRECTORIES="$(dirname "$outside")" \
  "$BASH" "$resolve" --worktree 2>"$err")"
rc=$?
assert_eq "outside a repo: exits 1" "1" "$rc"
assert_eq "outside a repo: stdout empty" "" "$out"
assert_contains "outside a repo: says why" "not inside a git repository" "$(cat "$err")"

# ---------------------------------------------------------------------------
# Case 2: --worktree with no commit on HEAD -> nothing to diff against.
# ---------------------------------------------------------------------------
repo="$(new_repo)"
out="$(cd "$repo" && "$BASH" "$resolve" --worktree 2>"$err")"
rc=$?
assert_eq "no commits: exits 1" "1" "$rc"
assert_eq "no commits: stdout empty" "" "$out"
assert_contains "no commits: says why" "no commits on HEAD" "$(cat "$err")"

# ---------------------------------------------------------------------------
# Case 3: --worktree with a modified tracked file -> full contract, no warning.
# ---------------------------------------------------------------------------
repo="$(new_repo seed)"
oid="$(git -C "$repo" rev-parse HEAD)"
printf 'two\n' >> "$repo/tracked.txt"
out="$(cd "$repo" && "$BASH" "$resolve" --worktree 2>"$err")"
rc=$?
assert_eq "tracked change: exits 0" "0" "$rc"
assert_eq "tracked change: eight-key contract" "$(expected_keys "$oid")" "$out"
assert_eq "tracked change: no clean-tree warning" "" "$(cat "$err")"

# The keys and their order are the caller's parsing contract.
assert_eq "tracked change: key names in order" \
  "is_pr number url base head_ref head_oid diff_from diff_to" \
  "$(printf '%s\n' "$out" | cut -d= -f1 | tr '\n' ' ' | sed 's/ $//')"

# ---------------------------------------------------------------------------
# Case 4: --worktree with only an untracked file -> still a dirty tree.
# ---------------------------------------------------------------------------
repo="$(new_repo seed)"
oid="$(git -C "$repo" rev-parse HEAD)"
printf 'new\n' > "$repo/untracked.txt"
out="$(cd "$repo" && "$BASH" "$resolve" --worktree 2>"$err")"
rc=$?
assert_eq "untracked only: exits 0" "0" "$rc"
assert_eq "untracked only: eight-key contract" "$(expected_keys "$oid")" "$out"
assert_eq "untracked only: no clean-tree warning" "" "$(cat "$err")"

# ---------------------------------------------------------------------------
# Case 5: --worktree on a clean tree -> warns on stderr but still resolves.
# ---------------------------------------------------------------------------
repo="$(new_repo seed)"
oid="$(git -C "$repo" rev-parse HEAD)"
out="$(cd "$repo" && "$BASH" "$resolve" --worktree 2>"$err")"
rc=$?
assert_eq "clean tree: exits 0" "0" "$rc"
assert_eq "clean tree: eight-key contract" "$(expected_keys "$oid")" "$out"
assert_contains "clean tree: warns on stderr" "working tree is clean" "$(cat "$err")"

# ---------------------------------------------------------------------------
# Cases 6-7: with gh and jq off PATH, --worktree still resolves but any other
# target stops at the dependency guard. This is the ordering the worktree
# branch exists to guarantee.
# ---------------------------------------------------------------------------
fakebin="$(mktemp -d)"
workdirs+=("$fakebin")
for tool in git cat sed grep; do
  real="$(command -v "$tool")" || continue
  ln -s "$real" "$fakebin/$tool"
done

repo="$(new_repo seed)"
oid="$(git -C "$repo" rev-parse HEAD)"
printf 'two\n' >> "$repo/tracked.txt"
out="$(cd "$repo" && PATH="$fakebin" "$BASH" "$resolve" --worktree 2>"$err")"
rc=$?
assert_eq "no gh/jq, --worktree: exits 0" "0" "$rc"
assert_eq "no gh/jq, --worktree: eight-key contract" "$(expected_keys "$oid")" "$out"

out="$(cd "$repo" && PATH="$fakebin" "$BASH" "$resolve" 2>"$err")"
rc=$?
assert_eq "no gh, default target: exits 1" "1" "$rc"
assert_eq "no gh, default target: stdout empty" "" "$out"
assert_contains "no gh, default target: says why" "gh not found on PATH" "$(cat "$err")"

# ---------------------------------------------------------------------------
rm -f "$err"
for d in "${workdirs[@]}"; do rm -rf "$d"; done

if [ "$failures" -ne 0 ]; then
  echo "$failures assertion(s) failed"
  exit 1
fi
echo "all assertions passed"
