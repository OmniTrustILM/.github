#!/usr/bin/env bash
# Behavioral tests for copilot-target.sh - the gate that keeps Copilot review
# instructions off every repo that has not opted in. Without it a routine
# `target_repos: all` dispatch for release.yml seeds them org-wide, so these
# assert the gate itself, not merely that an allowed repo passes.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
gate="$here/copilot-target.sh"

command -v yq >/dev/null 2>&1 || { echo "yq required for these tests" >&2; exit 1; }

cfg="$(mktemp)"; bad="$(mktemp)"; empty="$(mktemp)"; norepos="$(mktemp)"; scalar="$(mktemp)"
trap 'rm -f "$cfg" "$bad" "$empty" "$norepos" "$scalar"' EXIT

printf 'repos:
  - core
  - interfaces
' > "$cfg"
printf 'repos:
  - core
   bad indent: [
'  > "$bad"
printf 'repos:
'                               > "$empty"
printf 'other: 1
'                             > "$norepos"
printf 'repos: core
'                          > "$scalar"

fail=0
# check <name> <expected-rc> <repo> <config>
check() {
  local name="$1" exp="$2" repo="$3" conf="$4" rc
  set +e
  bash "$gate" "$repo" "$conf" >/dev/null 2>&1; rc=$?
  set -e
  if [ "$rc" -ne "$exp" ]; then
    echo "FAIL: $name - expected rc=$exp, got rc=$rc"
    fail=1
  else
    echo "ok: $name"
  fi
}

check "a listed repo is in scope"                 0 core       "$cfg"
check "the second listed repo is in scope"        0 interfaces "$cfg"
check "an unlisted repo is skipped"               3 go-sdk     "$cfg"
check "the .github repo is skipped"               3 .github    "$cfg"
# A listed name must match whole, not as a substring: `core` must not pull in
# `core-api`, and a prefix of a listed name must not match either.
check "a superstring of a listed repo is skipped" 3 core-api   "$cfg"
check "a substring of a listed repo is skipped"   3 cor        "$cfg"
# Config problems fail the run rather than reading as "not in scope"; a silent
# skip would stop the sync for every repo with no signal.
check "an unparseable config is an error"         2 core       "$bad"
check "a config with no repos key is an error"    2 core       "$norepos"
check "a scalar where a list belongs is an error" 2 core       "$scalar"
# An empty list is legitimate: everyone opted out.
check "an empty list skips rather than errors"    3 core       "$empty"

# The shipped config must still agree with the pilot. This is what fails if
# someone widens the allowlist without reading ilm#351.
live="$here/../../../config/copilot-repos.yml"
if [ -f "$live" ]; then
  check "shipped config: core is in scope"         0 core             "$live"
  check "shipped config: interfaces is in scope"   0 interfaces       "$live"
  check "shipped config: a non-pilot repo is not"  3 fe-administrator "$live"
fi

if [ "$fail" -eq 0 ]; then
  echo "copilot-target.sh: all checks passed"
fi
exit "$fail"
