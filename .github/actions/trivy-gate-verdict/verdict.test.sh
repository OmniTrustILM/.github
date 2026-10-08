#!/usr/bin/env bash
# Self-contained test for verdict.sh. Runs it against inline Trivy JSON
# reports and asserts the exit code, the log and the job summary.
#
# Run locally: bash .github/actions/trivy-gate-verdict/verdict.test.sh
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
verdict="$script_dir/verdict.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

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

# assert_has <description> <text> <needle> — text contains needle. The needle
# is not echoed: some are workflow-command lookalikes.
assert_has() {
  local desc="$1" text="$2" needle="$3"
  case "$text" in
    *"$needle"*) echo "ok - $desc" ;;
    *) echo "FAIL - $desc (expected text missing)"; failures=$((failures + 1)) ;;
  esac
}

# assert_lacks <description> <text> <needle> — text does not contain needle.
assert_lacks() {
  local desc="$1" text="$2" needle="$3"
  case "$text" in
    *"$needle"*) echo "FAIL - $desc (unexpected text found)"; failures=$((failures + 1)) ;;
    *) echo "ok - $desc" ;;
  esac
}

# run_verdict <mode> <report-json> [label] — runs verdict.sh and sets rc, log
# (its stdout), errors (its stderr) and summary (the job summary it wrote). An
# empty report-json runs it without a report file; the label defaults to amd64.
run_verdict() {
  local mode="$1" report_json="$2" label="${3-amd64}"
  local report="$work/report.json"
  rm -f "$report"
  : > "$work/summary"
  if [ -n "$report_json" ]; then
    printf '%s' "$report_json" > "$report"
  fi
  rc=0
  log="$(INPUT_GATE_MODE="$mode" INPUT_REPORT_FILE="$report" INPUT_LABEL="$label" \
    GITHUB_STEP_SUMMARY="$work/summary" bash "$verdict" 2> "$work/stderr")" || rc=$?
  errors="$(cat "$work/stderr")"
  summary="$(cat "$work/summary")"
}

readonly NO_RESULTS='{"SchemaVersion": 2}'

readonly CLEAN='{"SchemaVersion": 2, "Results": [{"Target": "app.jar", "Class": "lang-pkgs", "Type": "jar"}]}'

readonly VULNERABILITIES='{"SchemaVersion": 2, "Results": [
  {"Target": "img (debian 12.12)", "Class": "os-pkgs", "Type": "debian", "Vulnerabilities": [
    {"VulnerabilityID": "CVE-2026-0002", "PkgName": "libssl3", "InstalledVersion": "3.0.17-1", "FixedVersion": "3.0.18-1", "Severity": "HIGH"}]},
  {"Target": "Java", "Class": "lang-pkgs", "Type": "jar", "Vulnerabilities": [
    {"VulnerabilityID": "CVE-2026-47884", "PkgName": "org.springframework:spring-webmvc", "PkgPath": "app.jar", "InstalledVersion": "6.2.19", "FixedVersion": "7.0.9", "Severity": "CRITICAL"}]}]}'

readonly WITH_SECRET='{"SchemaVersion": 2, "Results": [
  {"Target": "Java", "Class": "lang-pkgs", "Type": "jar", "Vulnerabilities": [
    {"VulnerabilityID": "CVE-2026-47884", "PkgName": "org.springframework:spring-webmvc", "PkgPath": "app.jar", "InstalledVersion": "6.2.19", "FixedVersion": "7.0.9", "Severity": "CRITICAL"}]},
  {"Target": "/app/config/key.pem", "Class": "secret", "Secrets": [
    {"RuleID": "private-key", "Category": "AsymmetricPrivateKey", "Severity": "HIGH", "Title": "Asymmetric Private Key", "StartLine": 1, "EndLine": 1,
     "Match": "MATCHED-SECRET-TEXT", "Code": {"Lines": [{"Number": 1, "Content": "CODE-SECRET-TEXT"}]}}]}]}'

readonly OTHER_KINDS='{"SchemaVersion": 2, "Results": [
  {"Target": "Dockerfile", "Class": "config", "Misconfigurations": [
    {"ID": "DS002", "Severity": "HIGH", "Status": "FAIL"}, {"ID": "DS001", "Severity": "LOW", "Status": "PASS"}]},
  {"Target": "OS Packages", "Class": "license", "Licenses": [{"Name": "AGPL-3.0", "Severity": "CRITICAL", "PkgName": "example"}]}]}'

readonly HOSTILE='{"SchemaVersion": 2, "Results": [{"Target": "Java", "Class": "lang-pkgs", "Vulnerabilities": [
  {"VulnerabilityID": "CVE-2026-0003", "PkgName": "evil|pkg\n::error::injected", "InstalledVersion": "1.0", "FixedVersion": "1.1", "Severity": "HIGH"},
  {"VulnerabilityID": "CVE-2026-0006", "PkgName": "lib", "PkgPath": "##[error]forged [trusted](https://attacker.example)", "InstalledVersion": "1.0`x", "FixedVersion": "1.1", "Severity": "HIGH"}]}]}'

readonly MALFORMED='{"SchemaVersion": 2, "Results": [{"Target": "x", "Secrets": "##[error]x"}]}'

readonly LOWER_SEVERITIES='{"SchemaVersion": 2, "Results": [{"Target": "Java", "Class": "lang-pkgs", "Vulnerabilities": [
  {"VulnerabilityID": "CVE-2026-0005", "PkgName": "unrated", "InstalledVersion": "1.0", "Severity": "UNKNOWN"},
  {"VulnerabilityID": "CVE-2026-0004", "PkgName": "medium", "InstalledVersion": "2.0", "FixedVersion": "2.1", "Severity": "MEDIUM"}]}]}'

# -- Clean reports pass quietly ---------------------------------------------
run_verdict warn "$NO_RESULTS"
assert_eq "no results: exits 0" "0" "$rc"
assert_eq "no results: says so" "Vulnerability gate (amd64): no findings." "$log"
assert_eq "no results: writes no summary" "" "$summary"

run_verdict enforce "$CLEAN"
assert_eq "clean: exits 0" "0" "$rc"
assert_eq "clean: writes no summary" "" "$summary"

# -- Warn mode: vulnerabilities warn, the build continues -------------------
run_verdict warn "$VULNERABILITIES"
assert_eq "warn: vulnerabilities exit 0" "0" "$rc"
assert_has "warn: warning annotation" "$log" \
  "::warning title=Vulnerability gate (amd64)::Vulnerabilities found by the Trivy policy: 2."
assert_has "warn: summary says the build continues" "$summary" \
  "This build is not a release, so vulnerabilities do not fail it."
assert_has "warn: summary lists the library finding" "$summary" \
  '| `CRITICAL` | `CVE-2026-47884` | `org.springframework:spring-webmvc (app.jar)` | `6.2.19` | `7.0.9` |'
assert_has "warn: summary lists the OS finding" "$summary" \
  '| `HIGH` | `CVE-2026-0002` | `libssl3` | `3.0.17-1` | `3.0.18-1` |'
assert_eq "warn: CRITICAL sorts first" '| `CRITICAL`' \
  "$(printf '%s\n' "$summary" | grep -m1 -oE '^\| `(CRITICAL|HIGH)`')"
assert_has "warn: the log points to the summary" "$log" \
  "Vulnerability gate (amd64): findings listed in the job summary (vulnerabilities: 2, other: 0)."
assert_lacks "warn: the log carries no report values" "$log" "CVE-2026-47884"

# -- Enforce mode only reports; the gate step decides ------------------------
run_verdict enforce "$VULNERABILITIES"
assert_eq "enforce: exits 0" "0" "$rc"
assert_has "enforce: summary says the policy is enforced" "$summary" "This build enforces the Trivy policy."
assert_lacks "enforce: no warning annotation" "$log" "::warning"

run_verdict report "$VULNERABILITIES"
assert_has "unknown mode: enforces" "$summary" "This build enforces the Trivy policy."
assert_lacks "unknown mode: no warning annotation" "$log" "::warning"

run_verdict "" "$VULNERABILITIES"
assert_eq "missing mode: exits 0" "0" "$rc"
assert_has "missing mode: enforces" "$summary" "This build enforces the Trivy policy."
assert_lacks "missing mode: no warning annotation" "$log" "::warning"

# -- Warn mode: any other finding fails; secrets stay unread -----------------
run_verdict warn "$WITH_SECRET"
assert_eq "warn: a secret exits 1" "1" "$rc"
assert_has "warn: error annotation" "$log" \
  "::error title=Vulnerability gate (amd64)::Findings other than vulnerabilities, such as leaked secrets: 1."
assert_has "warn: summary says other findings fail" "$summary" \
  "Findings other than vulnerabilities fail every build."
assert_has "warn: summary lists the secret by rule and line" "$summary" \
  '| `HIGH` | secret | `private-key` | `/app/config/key.pem:1` |'
assert_has "warn: summary still lists the vulnerability" "$summary" '| `CRITICAL` | `CVE-2026-47884`'
assert_lacks "secret match not in the log" "$log" "MATCHED-SECRET-TEXT"
assert_lacks "secret code not in the log" "$log" "CODE-SECRET-TEXT"
assert_lacks "secret match not in the summary" "$summary" "MATCHED-SECRET-TEXT"
assert_lacks "secret code not in the summary" "$summary" "CODE-SECRET-TEXT"

run_verdict enforce "$WITH_SECRET"
assert_eq "enforce: a secret exits 0, the gate step decides" "0" "$rc"

run_verdict warn "$OTHER_KINDS"
assert_eq "warn: misconfiguration and license exit 1" "1" "$rc"
assert_has "warn: lists the license" "$summary" '| `CRITICAL` | license | `AGPL-3.0` | `OS Packages` |'
assert_has "warn: lists the misconfiguration" "$summary" '| `HIGH` | misconfiguration | `DS002` | `Dockerfile` |'
assert_has "warn: a passed check is not a finding" "$log" \
  "Findings other than vulnerabilities, such as leaked secrets: 2."
assert_lacks "warn: a passed check is not listed" "$summary" "DS001"

# -- An unreadable report fails in both modes --------------------------------
run_verdict warn ""
assert_eq "missing report: exits 1" "1" "$rc"
assert_has "missing report: error annotation" "$log" \
  "::error title=Vulnerability gate (amd64)::The Trivy report"

run_verdict enforce '[]'
assert_eq "not an object: exits 1" "1" "$rc"

run_verdict warn "$MALFORMED"
assert_eq "malformed report: exits 1" "1" "$rc"
assert_has "malformed report: error annotation" "$log" \
  "::error title=Vulnerability gate (amd64)::The Trivy report"
assert_lacks "malformed report: no report value on stderr" "$errors" "##[error]"
assert_lacks "malformed report: no report value in the log" "$log" "##[error]"

# -- Report content stays out of the log and inert in the summary ------------
run_verdict warn "$HOSTILE"
assert_has "pipe escaped, line break flattened" "$summary" '| `evil\|pkg ::error::injected` |'
assert_has "markdown stays inside a code span" "$summary" '`lib (##[error]forged [trusted](https://attacker.example))`'
assert_has "a backtick cannot close the code span" "$summary" '`1.0x`'
assert_lacks "log: no command smuggled in a value" "$log" "injected"
assert_lacks "log: no legacy command smuggled in a value" "$log" "forged"

# -- Severities a repo's own policy may report -------------------------------
run_verdict warn "$LOWER_SEVERITIES"
assert_eq "lower severities: MEDIUM sorts before an unknown severity" '| `MEDIUM`' \
  "$(printf '%s\n' "$summary" | grep -m1 -oE '^\| `(MEDIUM|UNKNOWN)`')"
assert_has "lower severities: a missing fixed version stays empty" "$summary" \
  '| `UNKNOWN` | `CVE-2026-0005` | `unrated` | `1.0` |  |'

# -- Label -------------------------------------------------------------------
run_verdict warn "$VULNERABILITIES" ""
assert_has "empty label: plain heading" "$summary" $'### Vulnerability gate\n'
assert_has "empty label: plain annotation title" "$log" "::warning title=Vulnerability gate::"

echo "----"
if [ "$failures" -eq 0 ]; then
  echo "All verdict.sh tests passed."
else
  echo "$failures test(s) failed."
  exit 1
fi
