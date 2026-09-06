#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  ACTION_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # shellcheck source-path=SCRIPTDIR source=../lib/common.sh
  . "$ACTION_DIR/lib/common.sh"
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out"
  : > "$GITHUB_OUTPUT"
}

@test "fingerprint is six lowercase hex characters" {
  run fingerprint "src/A.java" "Correctness" "Loop never terminates."
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9a-f]{6}$ ]] || { echo "got: $output"; false; }
}

@test "fingerprint ignores whitespace and case in the description" {
  a=$(fingerprint "src/A.java" "Correctness" "Loop  never   terminates.")
  b=$(fingerprint "src/A.java" "Correctness" "LOOP NEVER TERMINATES.")
  [ "$a" = "$b" ]
}

@test "fingerprint distinguishes file and category" {
  base=$(fingerprint "src/A.java" "Correctness" "x")
  [ "$base" != "$(fingerprint "src/B.java" "Correctness" "x")" ]
  [ "$base" != "$(fingerprint "src/A.java" "Security" "x")" ]
}

@test "fingerprint is independent of the line number" {
  # Identity must survive code moving between commits, which is the whole
  # reason the line is not part of the input.
  a=$(fingerprint "src/A.java" "Correctness" "Loop never terminates.")
  b=$(fingerprint "src/A.java" "Correctness" "Loop never terminates.")
  [ "$a" = "$b" ]
}

@test "log writes to stderr so stdout stays parseable" {
  run --separate-stderr bash -c ". '$ACTION_DIR/lib/common.sh'; log hello"
  [ -z "$output" ]
  [[ "$stderr" == *hello* ]]
}

@test "die exits non-zero with its message on stderr" {
  run --separate-stderr bash -c ". '$ACTION_DIR/lib/common.sh'; die 'boom'; echo unreachable"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *boom* ]]
}

@test "set_output appends key=value to GITHUB_OUTPUT" {
  set_output proceed true
  set_output pr-number 2087
  grep -qx 'proceed=true' "$GITHUB_OUTPUT"
  grep -qx 'pr-number=2087' "$GITHUB_OUTPUT"
}

@test "the gh stub matches whole invocations, not substrings" {
  export GH_FIXTURE_DIR="$BATS_TEST_TMPDIR/fx"
  mkdir -p "$GH_FIXTURE_DIR"
  echo '{"ok":true}' > "$GH_FIXTURE_DIR/hit.json"
  tab=$'\t'
  printf '%s\n' "api repos/x/y/pulls/7${tab}hit.json" > "$GH_FIXTURE_DIR/map.txt"
  export PATH="$BATS_TEST_DIRNAME/stubs:$PATH"

  run gh api repos/x/y/pulls/7
  [ "$status" -eq 0 ]
  [[ "$output" == *'"ok":true'* ]]

  run gh api repos/x/y/pulls/999
  [ "$status" -ne 0 ]

  # Substring matching used to let pulls/7 answer these too, so fixtures would
  # shadow each other as soon as a sub-endpoint appeared.
  run gh api repos/x/y/pulls/70
  [ "$status" -ne 0 ]
  run gh api repos/x/y/pulls/7/comments
  [ "$status" -ne 0 ]
}
