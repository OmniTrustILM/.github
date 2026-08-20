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
  [ "$status" -eq 0 ]
  [ "$(out proceed)" = "false" ]
}

@test "a bot-authored pull request does not proceed" {
  event pull_request pr_renovate.json
  run "$ACTION_DIR/guard/guard.sh"
  [ "$status" -eq 0 ]
  [ "$(out proceed)" = "false" ]
}

@test "a comment on a fork pull request does not proceed" {
  # issue_comment runs in base-repo context WITH secrets, so the fork check
  # cannot live only on the pull_request path.
  event issue_comment comment_fork.json
  run "$ACTION_DIR/guard/guard.sh"
  [ "$status" -eq 0 ]
  [ "$(out proceed)" = "false" ]
}

@test "/ilm-review proceeds at the default effort" {
  event issue_comment comment_plain.json
  run "$ACTION_DIR/guard/guard.sh"
  [ "$(out proceed)" = "true" ]
  [ "$(out effort)" = "standard" ]
}

@test "/ilm-review deep overrides the effort and resolves every output" {
  # The issue_comment path derives these from the API response rather than the
  # event payload, so a jq typo here would otherwise pass the whole suite.
  event issue_comment comment_deep.json
  run "$ACTION_DIR/guard/guard.sh"
  [ "$(out proceed)" = "true" ]
  [ "$(out effort)" = "deep" ]
  [ "$(out pr-number)" = "2087" ]
  [ "$(out head-sha)" = "a3f9c21deadbeef" ]
  [ "$(out base-ref)" = "main" ]
}

@test "/ilm-review full sets the full flag without consuming the effort slot" {
  event issue_comment comment_full.json
  run "$ACTION_DIR/guard/guard.sh"
  [ "$(out proceed)" = "true" ]
  [ "$(out full)" = "true" ]
  [ "$(out effort)" = "standard" ]
}

@test "/ilm-review deep full sets both" {
  event issue_comment comment_deepfull.json
  run "$ACTION_DIR/guard/guard.sh"
  [ "$(out effort)" = "deep" ]
  [ "$(out full)" = "true" ]
}

@test "/ilm-review light parses the one effort the default never produces" {
  event issue_comment comment_light.json
  run "$ACTION_DIR/guard/guard.sh"
  [ "$(out effort)" = "light" ]
}

@test "/ilm-review full full is rejected as malformed" {
  event issue_comment comment_fullfull.json
  run "$ACTION_DIR/guard/guard.sh"
  [ "$status" -eq 0 ]
  [ "$(out proceed)" = "false" ]
}

@test "only the first line of a comment is the command" {
  # /review followed by an explanation should work, but [[:space:]] matches
  # newlines - so without trimming, a word on the second line would be read as
  # the effort. The fixture body is /review on line one, deep on line two.
  event issue_comment comment_multiline.json
  run "$ACTION_DIR/guard/guard.sh"
  [ "$status" -eq 0 ]
  [ "$(out proceed)" = "true" ]
  [ "$(out effort)" = "standard" ]
}

@test "a comment from outside the org does not start a review" {
  # The dangerous path: issue_comment runs with the full secret set, and on a
  # public repo anyone can comment.
  event issue_comment comment_outsider.json
  run "$ACTION_DIR/guard/guard.sh"
  [ "$status" -eq 0 ]
  [ "$(out proceed)" = "false" ]
}

@test "a comment on a plain issue skips cleanly rather than crashing" {
  event issue_comment comment_not_a_pr.json
  run "$ACTION_DIR/guard/guard.sh"
  [ "$status" -eq 0 ]
  [ "$(out proceed)" = "false" ]
}

@test "an explicit /ilm-review overrides the bot-author skip" {
  event issue_comment comment_botpr.json
  run "$ACTION_DIR/guard/guard.sh"
  [ "$(out proceed)" = "true" ]
}

@test "a near-miss on the command name does not trigger" {
  event issue_comment comment_reviewers.json
  run "$ACTION_DIR/guard/guard.sh"
  [ "$status" -eq 0 ]
  [ "$(out proceed)" = "false" ]
}

@test "a comment on a closed pull request does not proceed" {
  event issue_comment comment_closed.json
  run "$ACTION_DIR/guard/guard.sh"
  [ "$status" -eq 0 ]
  [ "$(out proceed)" = "false" ]
}

@test "an unknown effort is rejected rather than silently defaulted" {
  event issue_comment comment_badeffort.json
  run "$ACTION_DIR/guard/guard.sh"
  [ "$status" -eq 0 ]
  [ "$(out proceed)" = "false" ]
}

@test "the guard never mints an App token" {
  # It runs before the App token exists. It does read the workflow's own
  # GITHUB_TOKEN to resolve a pull request, which is a different credential.
  run grep -nE "create-github-app-token|APP_ID|PRIVATE_KEY" "$ACTION_DIR/guard/guard.sh"
  [ -z "$output" ] || { echo "guard touches credentials: $output"; false; }
}

@test "the generic /review does not trigger this reviewer" {
  # The command is namespaced so a bare /review - which other tooling and
  # people use conversationally - never reaches the guard's grammar, and the
  # workflow prefilter never starts a runner for it.
  event issue_comment comment_generic.json
  run "$ACTION_DIR/guard/guard.sh"
  [ "$status" -eq 0 ]
  [ "$(out proceed)" = "false" ]
}

@test "the bot skip survives a filename matching its glob" {
  # renovate[bot] is a valid glob pattern. Unquoted, it expands to a matching
  # filename in the working directory and the skip silently fails open.
  cd "$BATS_TEST_TMPDIR"
  touch renovateb
  event pull_request pr_renovate.json
  run "$ACTION_DIR/guard/guard.sh"
  [ "$status" -eq 0 ]
  [ "$(out proceed)" = "false" ]
}
