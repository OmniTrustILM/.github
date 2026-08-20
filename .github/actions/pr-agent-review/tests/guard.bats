#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

load helper

setup() {
  ACTION_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out"
  : > "$GITHUB_OUTPUT"
  export GITHUB_REPOSITORY="OmniTrustILM/core"
  setup_stub_gh guard
}

out() { grep "^$1=" "$GITHUB_OUTPUT" | tail -1 | cut -d= -f2-; }

event() {
  export GITHUB_EVENT_NAME="$1"
  export GITHUB_EVENT_PATH="$BATS_TEST_DIRNAME/fixtures/guard/$2"
}

@test "a same-repo opened pull request proceeds at the default effort" {
  event pull_request pr_opened.json
  run "$ACTION_DIR/guard/guard.sh"
  [ "$status" -eq 0 ]
  [ "$(out proceed)" = "true" ]
  [ "$(out effort)" = "standard" ]
  [ "$(out pr-number)" = "2087" ]
  [ "$(out head-sha)" = "a3f9c21deadbeef" ]
  [ "$(out base-ref)" = "main" ]
  [ "$(out full)" = "false" ]
}

@test "a draft pull request does not proceed" {
  event pull_request pr_draft.json
  run "$ACTION_DIR/guard/guard.sh"
  [ "$status" -eq 0 ]
  [ "$(out proceed)" = "false" ]
}

@test "a fork head does not proceed" {
  event pull_request pr_fork.json
  run "$ACTION_DIR/guard/guard.sh"
  [ "$(out proceed)" = "false" ]
}

@test "a bot-authored pull request does not proceed" {
  event pull_request pr_renovate.json
  run "$ACTION_DIR/guard/guard.sh"
  [ "$(out proceed)" = "false" ]
}

@test "a comment on a fork pull request does not proceed" {
  # issue_comment runs in base-repo context WITH secrets, so the fork check
  # cannot live only on the pull_request path.
  event issue_comment comment_fork.json
  run "$ACTION_DIR/guard/guard.sh"
  [ "$(out proceed)" = "false" ]
}

@test "/review proceeds at the default effort" {
  event issue_comment comment_plain.json
  run "$ACTION_DIR/guard/guard.sh"
  [ "$(out proceed)" = "true" ]
  [ "$(out effort)" = "standard" ]
}

@test "/review deep overrides the effort" {
  event issue_comment comment_deep.json
  run "$ACTION_DIR/guard/guard.sh"
  [ "$(out proceed)" = "true" ]
  [ "$(out effort)" = "deep" ]
}

@test "/review full sets the full flag" {
  event issue_comment comment_full.json
  run "$ACTION_DIR/guard/guard.sh"
  [ "$(out proceed)" = "true" ]
  [ "$(out full)" = "true" ]
}

@test "/reviewers is not the review command" {
  # The workflow if: can only do startsWith, so the real grammar is enforced
  # here - otherwise "/reviewers please look" would spend credits.
  event issue_comment comment_reviewers.json
  run "$ACTION_DIR/guard/guard.sh"
  [ "$(out proceed)" = "false" ]
}

@test "a comment on a closed pull request does not proceed" {
  event issue_comment comment_closed.json
  run "$ACTION_DIR/guard/guard.sh"
  [ "$(out proceed)" = "false" ]
}

@test "an unknown effort is rejected rather than silently defaulted" {
  event issue_comment comment_badeffort.json
  run "$ACTION_DIR/guard/guard.sh"
  [ "$(out proceed)" = "false" ]
}

@test "the guard never mints or reads a token" {
  # Its whole purpose is to run before credentials exist.
  run grep -nE "create-github-app-token|APP_ID|PRIVATE_KEY" "$ACTION_DIR/guard/guard.sh"
  [ -z "$output" ] || { echo "guard touches credentials: $output"; false; }
}
