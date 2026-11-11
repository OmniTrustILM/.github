#!/usr/bin/env bash
# Self-contained test of the epic-scaffold decision helpers (scaffold-lib.sh):
# which issues get the standard tasks, and how an existing task is
# recognised so that the action stays idempotent.
#
# Run locally: bash .github/actions/epic-scaffold/scaffold.test.sh
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scaffold-lib.sh
source "$script_dir/scaffold-lib.sh"

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

# --- scaffold_wanted ---------------------------------------------------------
assert_eq "product Epic gets the tasks" "yes" \
  "$(scaffold_wanted "Epic" '["new-feature"]' "Certificate Revocation Redesign")"
assert_eq "Feature is skipped" "not an Epic (type: Feature)" \
  "$(scaffold_wanted "Feature" '[]' "Add bulk revocation")"
assert_eq "issue without a type is skipped" "not an Epic (type: none)" \
  "$(scaffold_wanted "" '[]' "Anything")"
assert_eq "tech epic is skipped" "tech-epic" \
  "$(scaffold_wanted "Epic" '["tech-epic","ignore-for-release"]' "Spring Boot 4.1 migration")"
assert_eq "bug collector is skipped by title" "release collector" \
  "$(scaffold_wanted "Epic" '[]' "Bugs 2.22.0")"
assert_eq "closed-bugs collector is skipped by title" "release collector" \
  "$(scaffold_wanted "Epic" '[]' "Closed bugs 2.21.0")"
assert_eq "a title merely containing Bugs is not a collector" "yes" \
  "$(scaffold_wanted "Epic" '[]' "Reported bugs dashboard")"

# --- doc_title ---------------------------------------------------------------
assert_eq "documentation task title" "Doc: SM: Raw Signing" "$(doc_title "SM: Raw Signing")"

# --- has_analysis_task / has_doc_task ------------------------------------------
none='[]'
with_both='[{"title":"Analysis, breakdown, estimations","labels":[]},{"title":"Doc: SM: Raw Signing","labels":["documentation"]}]'
only_dev='[{"title":"CSC API contracts","labels":["new-feature"]},{"title":"E2E tests","labels":["qa","testing"]}]'
doc_by_label='[{"title":"Revocation user guide","labels":["documentation"]}]'
analysis_variant='[{"title":"Epic analysis and estimates","labels":[]}]'

assert_eq "no sub-issues: no analysis task" "no" "$(has_analysis_task "$none")"
assert_eq "no sub-issues: no doc task" "no" "$(has_doc_task "$none")"
assert_eq "both present: analysis found" "yes" "$(has_analysis_task "$with_both")"
assert_eq "both present: doc found" "yes" "$(has_doc_task "$with_both")"
assert_eq "development only: no analysis task" "no" "$(has_analysis_task "$only_dev")"
assert_eq "development only: no doc task" "no" "$(has_doc_task "$only_dev")"
assert_eq "doc task recognised by label" "yes" "$(has_doc_task "$doc_by_label")"
assert_eq "analysis task recognised by a title variant" "yes" "$(has_analysis_task "$analysis_variant")"

# --- bodies ------------------------------------------------------------------
assert_eq "doc body names the Epic" "yes" \
  "$(doc_body OmniTrustILM/ilm 259 "Support for SSH" | grep -q 'OmniTrustILM/ilm#259 (Support for SSH)' && echo yes || echo no)"
assert_eq "analysis body carries the DoD" "yes" \
  "$(analysis_body | grep -q '^- \[ \] Estimated' && echo yes || echo no)"

if [ "$failures" -gt 0 ]; then
  echo "$failures failure(s)"
  exit 1
fi
echo "all passed"
