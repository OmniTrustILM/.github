#!/usr/bin/env bash
# Behavioral tests for render-codeowners.sh — protects the resolution order
# (exclude -> domain(s) -> qa -> default) and the single-line OR output that
# CODEOWNERS enforcement depends on. ShellCheck lints the script; this executes it.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
render="$here/render-codeowners.sh"

command -v yq >/dev/null 2>&1 || { echo "yq required for these tests" >&2; exit 1; }

map="$(mktemp)"
trap 'rm -f "$map"' EXIT
cat > "$map" <<'YAML'
core:
  - core
  - proxy
  - saas-provisioning
fe:
  - fe-administrator
  - saas-provisioning
go:
  - go-sdk
  - proxy
qa:
  - automated-testing-framework
infra:
  - saas-provisioning
exclude:
  - figma-test
YAML

fail=0
# check <name> <expected-rc> <expected-last-line> <repo>
check() {
  local name="$1" exp_rc="$2" exp="$3" repo="$4" out rc last
  set +e
  out="$(bash "$render" "$repo" "$map" 2>/dev/null)"; rc=$?
  set -e
  if [ "$rc" -ne "$exp_rc" ]; then
    echo "FAIL $name: rc=$rc, expected $exp_rc"; fail=1; return
  fi
  if [ "$exp_rc" -eq 0 ]; then
    last="$(printf '%s\n' "$out" | tail -n1)"
    if [ "$last" != "$exp" ]; then
      echo "FAIL $name: got '$last', expected '$exp'"; fail=1; return
    fi
  fi
  echo "ok   $name"
}

check "single-domain core"    0 "*  @OmniTrustILM/maintainers-core" core
check "single-domain go"      0 "*  @OmniTrustILM/maintainers-go" go-sdk
check "single-domain fe"      0 "*  @OmniTrustILM/maintainers-fe" fe-administrator
check "multi core+go"         0 "*  @OmniTrustILM/maintainers-core @OmniTrustILM/maintainers-go" proxy
check "multi core+fe+infra"   0 "*  @OmniTrustILM/maintainers-core @OmniTrustILM/maintainers-fe @OmniTrustILM/maintainers-infra" saas-provisioning
check "qa"                    0 "*  @OmniTrustILM/qa" automated-testing-framework
check "default maintainers"   0 "*  @OmniTrustILM/maintainers" some-uncurated-repo
check "excluded -> exit 3"    3 "" figma-test

# Preflight: an unparseable / missing map must exit 2, never fall through to default.
set +e
bash "$render" core /nonexistent/repo-domains.yml >/dev/null 2>&1; rc=$?
set -e
if [ "$rc" -eq 2 ]; then echo "ok   missing-map -> exit 2"; else echo "FAIL missing-map: rc=$rc, expected 2"; fail=1; fi

if [ "$fail" -ne 0 ]; then echo "render-codeowners tests FAILED"; exit 1; fi
echo "All render-codeowners tests passed."
