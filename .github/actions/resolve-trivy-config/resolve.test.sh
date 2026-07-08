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

# ---------------------------------------------------------------------------
# Case 1: override not allowed -> bundled default copied into the workspace,
# and a repo-local .trivyignore is neutralized via TRIVY_IGNOREFILE.
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
assert_eq "default: TRIVY_IGNOREFILE pointed at empty ignore file" \
  "TRIVY_IGNOREFILE=$rt/trivy-empty-ignore" "$(cat "$env_out")"
assert_eq "default: empty ignore file exists and is empty" \
  "yes" "$([ -f "$rt/trivy-empty-ignore" ] && [ ! -s "$rt/trivy-empty-ignore" ] && echo yes || echo no)"
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
  GITHUB_OUTPUT="$out" \
  bash "$resolve"
) || rc=$?
assert_eq "symlink guard: exits non-zero" "1" "$rc"
assert_eq "symlink guard: no config-file written" "" "$(cat "$out")"
assert_eq "symlink guard: link left in place, not written through" \
  "yes" "$([ -L "$work/.trivy-default.yaml" ] && echo yes || echo no)"
rm -rf "$work"

echo "----"
if [ "$failures" -eq 0 ]; then
  echo "All resolve.sh tests passed."
else
  echo "$failures test(s) failed."
  exit 1
fi
