#!/usr/bin/env bash
# Self-contained test for resolve.sh. Runs each branch in an isolated temp
# workspace and asserts the resolved config-file, ignore-file handling, and
# exit code.
#
# Run locally: bash .github/actions/resolve-trivy-config/resolve.test.sh
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
resolve="$script_dir/resolve.sh"
default_src="$script_dir/trivy.yaml"
default_ignore_src="$script_dir/trivyignore.yaml"

failures=0

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

# valid_expiry <date> <latest>: <date> is a real yyyy-mm-dd day no later than
# <latest>. Round-tripping through date rejects both a wrong shape and a day
# that does not exist, which a pattern alone lets through.
valid_expiry() {
  [[ "$(date -u -d "$1" +%F 2>/dev/null)" == "$1" && ! "$1" > "$2" ]]
}

# ---------------------------------------------------------------------------
# Case 1: override not allowed -> bundled default copied into the workspace,
# and a repo-local .trivyignore is swapped for the bundled org exceptions via
# TRIVY_IGNOREFILE.
# ---------------------------------------------------------------------------
work="$(mktemp -d)"
out="$work/gh_output"
env_out="$work/gh_env"
rt="$work/runner_temp"
mkdir -p "$rt"
: > "$out"
: > "$env_out"
(
  cd "$work"
  INPUT_ALLOW_TRIVY_CONFIG_OVERRIDE=false \
  INPUT_TRIVY_CONFIG_PATH=config/trivy.yaml \
  DEFAULT_CONFIG_SRC="$default_src" \
  DEFAULT_IGNORE_SRC="$default_ignore_src" \
  GITHUB_OUTPUT="$out" \
  GITHUB_ENV="$env_out" \
  RUNNER_TEMP="$rt" \
  bash "$resolve"
)
assert_eq "default: exits 0" "0" "$?"
assert_eq "default: outputs .trivy-default.yaml" \
  "config-file=.trivy-default.yaml" "$(cat "$out")"
assert_eq "default: file materialized in workspace" \
  "yes" "$([ -f "$work/.trivy-default.yaml" ] && echo yes || echo no)"
assert_eq "default: content matches bundled policy" \
  "$(cat "$default_src")" "$(cat "$work/.trivy-default.yaml")"
assert_eq "default: TRIVY_IGNOREFILE pointed at the org exceptions copy" \
  "TRIVY_IGNOREFILE=$rt/trivy-org-ignore.yaml" "$(cat "$env_out")"
assert_eq "default: org exceptions copy matches bundled file" \
  "$(cat "$default_ignore_src")" "$(cat "$rt/trivy-org-ignore.yaml")"
rm -rf "$work"

# ---------------------------------------------------------------------------
# Case 2: override allowed + file present -> repo file used verbatim, and
# Trivy's normal .trivyignore discovery is left intact (no TRIVY_IGNOREFILE).
# ---------------------------------------------------------------------------
work="$(mktemp -d)"
out="$work/gh_output"
env_out="$work/gh_env"
rt="$work/runner_temp"
mkdir -p "$rt"
: > "$out"
: > "$env_out"
mkdir -p "$work/config"
echo "severity: [CRITICAL]" > "$work/config/trivy.yaml"
(
  cd "$work"
  INPUT_ALLOW_TRIVY_CONFIG_OVERRIDE=true \
  INPUT_TRIVY_CONFIG_PATH=config/trivy.yaml \
  DEFAULT_CONFIG_SRC="$default_src" \
  GITHUB_OUTPUT="$out" \
  GITHUB_ENV="$env_out" \
  RUNNER_TEMP="$rt" \
  bash "$resolve"
)
assert_eq "override present: exits 0" "0" "$?"
assert_eq "override present: outputs repo path" \
  "config-file=config/trivy.yaml" "$(cat "$out")"
assert_eq "override present: bundled default NOT copied" \
  "no" "$([ -f "$work/.trivy-default.yaml" ] && echo yes || echo no)"
assert_eq "override present: TRIVY_IGNOREFILE NOT set" "" "$(cat "$env_out")"
rm -rf "$work"

# ---------------------------------------------------------------------------
# Case 3: override allowed + file missing -> fail loudly (non-zero exit).
# ---------------------------------------------------------------------------
work="$(mktemp -d)"
out="$work/gh_output"
: > "$out"
rc=0
(
  cd "$work"
  INPUT_ALLOW_TRIVY_CONFIG_OVERRIDE=true \
  INPUT_TRIVY_CONFIG_PATH=config/trivy.yaml \
  DEFAULT_CONFIG_SRC="$default_src" \
  GITHUB_OUTPUT="$out" \
  bash "$resolve"
) || rc=$?
assert_eq "override missing: exits non-zero" "1" "$rc"
assert_eq "override missing: no config-file written" "" "$(cat "$out")"
rm -rf "$work"

# ---------------------------------------------------------------------------
# Case 4: override allowed + file present but EMPTY -> fail closed (an empty
# config would silently disable the gate).
# ---------------------------------------------------------------------------
work="$(mktemp -d)"
out="$work/gh_output"
: > "$out"
mkdir -p "$work/config"
: > "$work/config/trivy.yaml"
rc=0
(
  cd "$work"
  INPUT_ALLOW_TRIVY_CONFIG_OVERRIDE=true \
  INPUT_TRIVY_CONFIG_PATH=config/trivy.yaml \
  DEFAULT_CONFIG_SRC="$default_src" \
  GITHUB_OUTPUT="$out" \
  bash "$resolve"
) || rc=$?
assert_eq "override empty: exits non-zero" "1" "$rc"
assert_eq "override empty: no config-file written" "" "$(cat "$out")"
rm -rf "$work"

# ---------------------------------------------------------------------------
# Case 5: override not allowed + workspace has a symlink named
# .trivy-default.yaml -> fail closed (refuse symlink traversal, do not write).
# ---------------------------------------------------------------------------
work="$(mktemp -d)"
out="$work/gh_output"
: > "$out"
ln -s /etc/passwd "$work/.trivy-default.yaml"
rc=0
(
  cd "$work"
  INPUT_ALLOW_TRIVY_CONFIG_OVERRIDE=false \
  INPUT_TRIVY_CONFIG_PATH=config/trivy.yaml \
  DEFAULT_CONFIG_SRC="$default_src" \
  DEFAULT_IGNORE_SRC="$default_ignore_src" \
  GITHUB_OUTPUT="$out" \
  bash "$resolve"
) || rc=$?
assert_eq "symlink guard: exits non-zero" "1" "$rc"
assert_eq "symlink guard: no config-file written" "" "$(cat "$out")"
assert_eq "symlink guard: link left in place, not written through" \
  "yes" "$([ -L "$work/.trivy-default.yaml" ] && echo yes || echo no)"
rm -rf "$work"

# ---------------------------------------------------------------------------
# Case 6: override not allowed + bundled org exceptions missing -> fail
# closed (packaging error), rather than fall back to Trivy's own .trivyignore.
# ---------------------------------------------------------------------------
work="$(mktemp -d)"
out="$work/gh_output"
env_out="$work/gh_env"
: > "$out"
: > "$env_out"
rc=0
(
  cd "$work"
  INPUT_ALLOW_TRIVY_CONFIG_OVERRIDE=false \
  INPUT_TRIVY_CONFIG_PATH=config/trivy.yaml \
  DEFAULT_CONFIG_SRC="$default_src" \
  DEFAULT_IGNORE_SRC="$work/missing.yaml" \
  GITHUB_OUTPUT="$out" \
  GITHUB_ENV="$env_out" \
  RUNNER_TEMP="$work" \
  bash "$resolve"
) || rc=$?
assert_eq "exceptions missing: exits non-zero" "1" "$rc"
assert_eq "exceptions missing: no config-file written" "" "$(cat "$out")"
assert_eq "exceptions missing: TRIVY_IGNOREFILE NOT set" "" "$(cat "$env_out")"
rm -rf "$work"

# ---------------------------------------------------------------------------
# Case 7: the expiry check rejects what Trivy cannot parse. An impossible date
# makes Trivy exit fatally, failing the scan in every repo on the default.
# ---------------------------------------------------------------------------
assert_eq "expiry check: rejects an impossible day" \
  "no" "$(valid_expiry 2026-02-30 2099-12-31 && echo yes || echo no)"
assert_eq "expiry check: rejects an impossible month" \
  "no" "$(valid_expiry 2026-13-01 2099-12-31 && echo yes || echo no)"
assert_eq "expiry check: rejects a date past the limit" \
  "no" "$(valid_expiry 2027-01-01 2026-12-31 && echo yes || echo no)"
assert_eq "expiry check: accepts a real date up to the limit" \
  "yes" "$(valid_expiry 2026-12-31 2026-12-31 && echo yes || echo no)"

# ---------------------------------------------------------------------------
# Case 8: every bundled org exception carries an id, purls, a statement and an
# expiry at most a year out. Needs mikefarah yq v4 (installed by action-tests).
# ---------------------------------------------------------------------------
if command -v yq >/dev/null 2>&1; then
  limit="$(date -u -d '+366 days' +%F)"
  count="$(yq '.vulnerabilities | length' "$default_ignore_src")"
  for ((i = 0; i < count; i++)); do
    e=".vulnerabilities[$i]"
    id="$(yq "$e.id // \"\"" "$default_ignore_src")"
    label="exception ${id:-#$i}"
    assert_eq "$label: has an id" "yes" "$([ -n "$id" ] && echo yes || echo no)"
    assert_eq "$label: names its purls" \
      "yes" "$([ "$(yq "$e.purls // [] | length" "$default_ignore_src")" -gt 0 ] && echo yes || echo no)"
    assert_eq "$label: has a statement" \
      "yes" "$([ -n "$(yq "$e.statement // \"\"" "$default_ignore_src")" ] && echo yes || echo no)"
    expiry="$(yq "$e.expired_at // \"\"" "$default_ignore_src")"
    assert_eq "$label: expires (yyyy-mm-dd) at most a year out" \
      "yes" "$(valid_expiry "$expiry" "$limit" && echo yes || echo no)"
  done
else
  echo "skip - bundled org exceptions lint (yq not installed)"
fi

echo "----"
if [ "$failures" -eq 0 ]; then
  echo "All resolve.sh tests passed."
else
  echo "$failures test(s) failed."
  exit 1
fi
