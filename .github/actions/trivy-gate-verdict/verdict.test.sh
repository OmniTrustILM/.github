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

# Stands in for the GitHub CLI: records its arguments, one per line, prints
# GH_STDERR the way gh reports an API error, and exits with GH_EXIT, so no case
# ever calls GitHub.
mkdir -p "$work/bin"
cat > "$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$GH_ARGS_FILE"
if [[ -n "${GH_STDERR:-}" ]]; then
  printf '%s\n' "$GH_STDERR" >&2
fi
exit "${GH_EXIT:-0}"
STUB
chmod +x "$work/bin/gh"

# The checkout the verdict runs in; HEAD_SHA="" makes it fall back to this HEAD.
git init -q "$work/repo"
git -C "$work/repo" -c user.name=test -c user.email=test@example.com commit -q --allow-empty -m init

failures=0

# assert_eq <description> <expected> <actual>
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" = "$actual" ]]; then
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

# run_verdict <mode> <report-json> [label] [gate-outcome] — runs verdict.sh in
# the test checkout and sets rc, log (its stdout), errors (its stderr), summary
# (the job summary it wrote) and gh_args (what it passed to gh, empty when it
# did not call it). An empty report-json runs it without a report file; the
# label defaults to amd64 and the gate step's outcome to success. GH_EXIT,
# GH_STDERR and HEAD_SHA, set on the call, change the stub's exit code, its
# error message and the head commit.
run_verdict() {
  local mode="$1" report_json="$2" label="${3-amd64}" outcome="${4-success}"
  local report="$work/report.json"
  rm -f "$report" "$work/gh-args"
  : > "$work/summary"
  if [[ -n "$report_json" ]]; then
    printf '%s' "$report_json" > "$report"
  fi
  rc=0
  log="$(cd "$work/repo" && PATH="$work/bin:$PATH" GH_ARGS_FILE="$work/gh-args" GH_EXIT="${GH_EXIT:-0}" GH_STDERR="${GH_STDERR:-}" \
    INPUT_GATE_MODE="$mode" INPUT_REPORT_FILE="$report" INPUT_LABEL="$label" \
    INPUT_GATE_OUTCOME="$outcome" INPUT_HEAD_SHA="${HEAD_SHA-abc123}" \
    GITHUB_REPOSITORY=OmniTrustILM/core GITHUB_SERVER_URL=https://github.com GITHUB_RUN_ID=42 \
    GITHUB_STEP_SUMMARY="$work/summary" bash "$verdict" 2> "$work/stderr")" || rc=$?
  errors="$(cat "$work/stderr")"
  summary="$(cat "$work/summary")"
  gh_args="$(cat "$work/gh-args" 2> /dev/null || true)"
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
assert_has "no results: says so" "$log" "Vulnerability gate (amd64): no findings."
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
assert_lacks "enforce, gate passed: no error annotation" "$errors" "::error"

run_verdict enforce "$VULNERABILITIES" amd64 failure
assert_eq "enforce, gate failed: exits 0, the gate step already failed" "0" "$rc"
assert_has "enforce, gate failed: one error annotation names the cause" "$errors" \
  "::error title=Vulnerability gate (amd64)::Findings fail this build (vulnerabilities: 2, other: 0). Details are in the job summary."

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
assert_has "warn: error annotation" "$errors" \
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
assert_has "warn: a passed check is not a finding" "$errors" \
  "Findings other than vulnerabilities, such as leaked secrets: 2."
assert_lacks "warn: a passed check is not listed" "$summary" "DS001"

# -- An unreadable report fails in both modes --------------------------------
run_verdict warn ""
assert_eq "missing report: exits 1" "1" "$rc"
assert_has "missing report: error annotation" "$errors" \
  "::error title=Vulnerability gate (amd64)::The Trivy report"

run_verdict enforce '[]'
assert_eq "not an object: exits 1" "1" "$rc"

run_verdict warn "" amd64 ""
assert_eq "missing report, no gate outcome: exits 1" "1" "$rc"

run_verdict enforce "" amd64 failure
assert_eq "gate failed without a report: exits 0, the gate step already failed" "0" "$rc"
assert_lacks "gate failed without a report: no second error" "$errors" "::error"

run_verdict warn "$MALFORMED"
assert_eq "malformed report: exits 1" "1" "$rc"
assert_has "malformed report: error annotation" "$errors" \
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

# -- The commit gets a check run that mirrors the verdict --------------------
run_verdict warn "$VULNERABILITIES"
assert_has "check run: created for the repository" "$gh_args" "repos/OmniTrustILM/core/check-runs"
assert_has "check run: named after the gate" "$gh_args" "name=Vulnerability gate (amd64)"
assert_has "check run: on the head commit" "$gh_args" "head_sha=abc123"
assert_has "check run: needs action" "$gh_args" "conclusion=action_required"
assert_has "check run: links to the run" "$gh_args" "details_url=https://github.com/OmniTrustILM/core/actions/runs/42"
assert_has "check run: carries the count" "$gh_args" "output[title]=Vulnerabilities: 2"
assert_has "check run: the log says so" "$log" "Vulnerability gate (amd64): check run on the commit: action_required."

GH_EXIT=1 GH_STDERR="gh: Resource not accessible by integration (HTTP 403)" run_verdict warn "$VULNERABILITIES"
assert_eq "no checks permission: still exits 0" "0" "$rc"
assert_has "no checks permission: the log says so" "$log" "Vulnerability gate (amd64): added no check run"
assert_lacks "no checks permission: no error annotation" "$errors" "::error"
assert_lacks "no checks permission: no warning about the check run" "$log" "could not be published"

GH_EXIT=1 GH_STDERR="gh: No commit found for SHA: abc123 (HTTP 422)" run_verdict warn "$VULNERABILITIES"
assert_eq "check run API error: still exits 0" "0" "$rc"
assert_has "check run API error: a warning names the status" "$log" \
  "::warning title=Vulnerability gate (amd64)::The check run could not be published (HTTP 422); the verdict is unaffected."
assert_lacks "check run API error: the API's message is not echoed" "$log" "No commit found"

GH_EXIT=127 run_verdict warn "$VULNERABILITIES"
assert_has "check run without gh: a warning names the exit code" "$log" \
  "::warning title=Vulnerability gate (amd64)::The check run could not be published (exit 127); the verdict is unaffected."

run_verdict warn "$VULNERABILITIES" "ilm/core amd64"
assert_has "check run: named by the label, so each image keeps its own" "$gh_args" "name=Vulnerability gate (ilm/core amd64)"

HEAD_SHA="" run_verdict warn "$VULNERABILITIES"
assert_has "check run: without a pull request head, the checked-out commit" "$gh_args" \
  "head_sha=$(git -C "$work/repo" rev-parse HEAD)"

# A rescan of the same commit replaces the earlier check of the same name.
run_verdict warn "$NO_RESULTS"
assert_has "check run: a clean scan succeeds" "$gh_args" "conclusion=success"
assert_has "check run: a clean scan says so" "$gh_args" "output[title]=No findings"
assert_has "check run: a clean scan keeps the gate's name" "$gh_args" "name=Vulnerability gate (amd64)"

run_verdict warn "$WITH_SECRET"
assert_has "check run: a finding that fails the build fails it" "$gh_args" "conclusion=failure"

run_verdict enforce "$VULNERABILITIES" amd64 failure
assert_has "check run: a failed release gate fails it" "$gh_args" "conclusion=failure"

run_verdict enforce "$VULNERABILITIES"
assert_has "check run: a release gate that passed succeeds" "$gh_args" "conclusion=success"

run_verdict enforce "" amd64 failure
assert_eq "check run: none without a report" "" "$gh_args"

run_verdict warn "$HOSTILE"
assert_lacks "check run: no report values sent (legacy command)" "$gh_args" "forged"
assert_lacks "check run: no report values sent (line break)" "$gh_args" "injected"

# -- Label -------------------------------------------------------------------
run_verdict warn "$VULNERABILITIES" ""
assert_has "empty label: plain heading" "$summary" $'### Vulnerability gate\n'
assert_has "empty label: plain annotation title" "$log" "::warning title=Vulnerability gate::"

echo "----"
if [[ "$failures" -eq 0 ]]; then
  echo "All verdict.sh tests passed."
else
  echo "$failures test(s) failed."
  exit 1
fi
