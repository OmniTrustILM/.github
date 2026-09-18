#!/usr/bin/env bash
# Behavioral tests for copilot-target.sh - the gate that keeps Copilot review
# instructions off every repo that has not opted in. These assert the gate
# itself, and that the two sync scripts still call it: the risk the design
# guards against lives as much in the wiring as in the gate.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
gate="$here/copilot-target.sh"

command -v yq >/dev/null 2>&1 || { echo "yq required for these tests" >&2; exit 1; }

cfg="$(mktemp)"; bad="$(mktemp)"; nullrepos="$(mktemp)"; emptyseq="$(mktemp)"
norepos="$(mktemp)"; scalar="$(mktemp)"; unknown="$(mktemp)"; mapentry="$(mktemp)"; blank="$(mktemp)"
trap 'rm -f "$cfg" "$bad" "$nullrepos" "$emptyseq" "$norepos" "$scalar" "$unknown" "$mapentry" "$blank"' EXIT

printf 'repos:
  - core
  - interfaces
'   > "$cfg"
printf 'repos:
  - core
   bad indent: [
' > "$bad"
printf 'repos:
'                              > "$nullrepos"
printf 'repos: []
'                           > "$emptyseq"
printf 'other: 1
'                            > "$norepos"
printf 'repos: core
'                         > "$scalar"
printf 'repos:
  - core
exclude:
  - core
' > "$unknown"
printf 'repos:
  - name: core
'             > "$mapentry"
printf 'repos:
  - ""
'                     > "$blank"

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

# --- membership ---
check "a listed repo is in scope"                 0 core       "$cfg"
check "the second listed repo is in scope"        0 interfaces "$cfg"
check "an unlisted repo is skipped"               3 go-sdk     "$cfg"
check "the .github repo is skipped"               3 .github    "$cfg"
# A listed name must match whole, not as a substring: `core` must not pull in
# `core-api`, and a prefix of a listed name must not match either.
check "a superstring of a listed repo is skipped" 3 core-api   "$cfg"
check "a substring of a listed repo is skipped"   3 cor        "$cfg"
# A name is compared, never interpreted - the reason the match is grep -qxF.
check "a regex metacharacter name is skipped"     3 '.*'            "$cfg"
check "a yq metacharacter name is skipped"        3 'core|interfaces' "$cfg"
# `repos: []` is how a maintainer says "everyone opted out".
check "an explicit empty list skips"              3 core       "$emptyseq"

# --- config problems fail the run, never read as "not in scope" ---
# A silent skip would stop the sync for every repo with no signal, which is the
# failure this gate exists to prevent one level up.
check "an unparseable config is an error"         2 core       "$bad"
check "a config with no repos key is an error"    2 core       "$norepos"
check "a scalar where a list belongs is an error" 2 core       "$scalar"
check "a null repos key is an error"              2 core       "$nullrepos"
check "an unknown top-level key is an error"      2 core       "$unknown"
check "a map entry is an error"                   2 core       "$mapentry"
check "an empty entry is an error"                2 core       "$blank"

# The missing-yq preflight is the branch this script leads with; assert it
# rather than trusting the comment. PATH is stripped so yq cannot be found.
set +e
env PATH=/usr/bin:/bin bash "$gate" core "$cfg" >/dev/null 2>&1; rc=$?
set -e
if [ "$rc" -ne 2 ]; then
  echo "FAIL: a missing yq is an error - expected rc=2, got rc=$rc"
  fail=1
else
  echo "ok: a missing yq is an error"
fi

check "a missing config file is an error"         2 core       "/nonexistent/copilot-repos.yml"

# --- the wiring, not just the gate ---
# Deleting the gate call from either script would leave every assertion above
# green while an `all` dispatch seeded the file into all 75 repos.
sync="$here/sync-all.sh"
diff="$here/diff-all.sh"
wired() {
  local name="$1" file="$2" gate_line copy_line
  # Match an invocation, not a mention: both scripts name copilot-target.sh in
  # an ::error:: string, which would satisfy a looser grep even with the call
  # deleted.
  # `|| true` on both: under set -e a non-matching grep inside the assignment
  # would abort the suite before the checks below could name what is missing.
  gate_line=$(grep -nE '^[[:space:]]*bash .*copilot-target\.sh' "$file" | head -1 | cut -d: -f1 || true)
  copy_line=$(grep -n "templates/copilot-instructions.md" "$file" | head -1 | cut -d: -f1 || true)
  if [ -z "$gate_line" ]; then
    echo "FAIL: $name - no copilot-target.sh invocation"
    fail=1
  elif [ -z "$copy_line" ]; then
    echo "FAIL: $name - no reference to the template"
    fail=1
  elif [ "$gate_line" -ge "$copy_line" ]; then
    echo "FAIL: $name - gate called at line $gate_line, after the template at $copy_line"
    fail=1
  else
    echo "ok: $name"
  fi
}
wired "sync-all.sh calls the gate before copying the template" "$sync"
wired "diff-all.sh calls the gate before reading the template" "$diff"

# --- the shipped config ---
# Run unconditionally: wrapping these in a file-exists test would let three
# assertions vanish silently if the config moved, which is the same
# skip-instead-of-signal failure the gate is written to avoid. The assertions
# are about shape, not membership, so widening the allowlist needs no edit here.
live="$here/../../../config/copilot-repos.yml"
if [ ! -f "$live" ]; then
  echo "FAIL: shipped config not found at $live"
  fail=1
else
  check "shipped config parses and gates"          0 core       "$live"
  check "shipped config skips an unlisted repo"    3 definitely-not-a-repo "$live"
fi

if [ "$fail" -eq 0 ]; then
  echo "copilot-target.sh: all checks passed"
fi
exit "$fail"
