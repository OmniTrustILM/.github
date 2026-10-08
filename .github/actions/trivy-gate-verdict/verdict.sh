#!/usr/bin/env bash
# Report what the vulnerability gate found, and decide what it means for the
# build.
#
# Called by the reusable Docker workflows right after the "Vulnerability gate"
# step, which writes the findings of the resolved Trivy policy to a JSON
# report. The findings go to the job summary and their counts to the log, then:
#   enforce -> exit 0; the gate step's own exit code decides the build
#   warn    -> vulnerabilities only: a warning, and the build continues;
#              any other finding, such as a leaked secret: an error, exit 1
# A missing or unreadable report fails in both modes. Any mode other than
# "warn" enforces.
#
# Report values never reach the log, where the runner reads a legacy
# "##[command]" anywhere in a line; jq's diagnostics can quote them, so those
# are discarded too. In the job summary the values are code spans, so they can
# neither break the table nor render as markdown. A secret's Match and Code are
# never read, because the run pages of public repos are public.
#
# Reads: INPUT_GATE_MODE, INPUT_REPORT_FILE, INPUT_LABEL, GITHUB_STEP_SUMMARY
set -euo pipefail

mode="${INPUT_GATE_MODE:-}"
report="${INPUT_REPORT_FILE:?INPUT_REPORT_FILE must name the gate report}"
label="${INPUT_LABEL:-}"
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"
title="Vulnerability gate${label:+ (${label})}"

if [[ "$mode" != "warn" ]]; then
  mode="enforce"
fi

readonly JQ_DEFS='
  def cell:
    (. // "") | tostring | gsub("[\r\n]+"; " ") | gsub("`"; "") | gsub("\\|"; "\\|")
    | if . == "" then . else "`\(.)`" end;
  def rank: {"CRITICAL": 0, "HIGH": 1, "MEDIUM": 2, "LOW": 3}[.Severity // ""] // 4;
  def package_name: (.PkgName // "") + (if .PkgPath then " (\(.PkgPath))" else "" end);
  def vulnerability_rows:
    [.Results[]?.Vulnerabilities[]?]
    | sort_by(rank, .VulnerabilityID)
    | map("| \(.Severity | cell) | \(.VulnerabilityID | cell) | \(package_name | cell) | \(.InstalledVersion | cell) | \(.FixedVersion | cell) |");
  def other_rows:
    [.Results[]? | .Target as $target
      | ((.Secrets // [])[] | {Severity, kind: "secret", id: .RuleID, where: "\($target):\(.StartLine)"}),
        ((.Misconfigurations // [])[] | select(.Status == "FAIL") | {Severity, kind: "misconfiguration", id: .ID, where: $target}),
        ((.Licenses // [])[] | {Severity, kind: "license", id: .Name, where: $target})]
    | sort_by(rank, .id)
    | map("| \(.Severity | cell) | \(.kind) | \(.id | cell) | \(.where | cell) |");
'

if ! jq -e 'type == "object"' "$report" > /dev/null 2>&1 ||
  ! vulnerabilities="$(jq "${JQ_DEFS} vulnerability_rows | length" "$report" 2> /dev/null)" ||
  ! others="$(jq "${JQ_DEFS} other_rows | length" "$report" 2> /dev/null)"; then
  echo "::error title=${title}::The Trivy report ${report} is missing or unreadable, so the gate cannot tell what the scan found." >&2
  exit 1
fi

if [[ "$vulnerabilities" -eq 0 ]] && [[ "$others" -eq 0 ]]; then
  echo "${title}: no findings."
  exit 0
fi

{
  echo "### ${title}"
  echo
  if [[ "$mode" = "warn" ]]; then
    echo "This build is not a release, so vulnerabilities do not fail it. Release builds enforce the Trivy policy."
    if [[ "$others" -gt 0 ]]; then
      echo "Findings other than vulnerabilities fail every build."
    fi
  else
    echo "This build enforces the Trivy policy."
  fi
  if [[ "$vulnerabilities" -gt 0 ]]; then
    echo
    echo "| Severity | Vulnerability | Package | Installed | Fixed |"
    echo "|---|---|---|---|---|"
    jq -r "${JQ_DEFS} vulnerability_rows | .[]" "$report" 2> /dev/null
  fi
  if [[ "$others" -gt 0 ]]; then
    echo
    echo "| Severity | Kind | ID | Location |"
    echo "|---|---|---|---|"
    jq -r "${JQ_DEFS} other_rows | .[]" "$report" 2> /dev/null
  fi
} >> "$summary"
echo "${title}: findings listed in the job summary (vulnerabilities: ${vulnerabilities}, other: ${others})."

if [[ "$mode" != "warn" ]]; then
  exit 0
fi

if [[ "$others" -gt 0 ]]; then
  echo "::error title=${title}::Findings other than vulnerabilities, such as leaked secrets: ${others}. These fail every build, release or not." >&2
  exit 1
fi

echo "::warning title=${title}::Vulnerabilities found by the Trivy policy: ${vulnerabilities}. This build is not a release, so it continues; release builds enforce the policy. Details are in the job summary."
