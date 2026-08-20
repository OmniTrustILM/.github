setup_stub_gh() {
  export GH_FIXTURE_DIR="$BATS_TEST_DIRNAME/fixtures/$1"
  export PATH="$BATS_TEST_DIRNAME/stubs:$PATH"
}
