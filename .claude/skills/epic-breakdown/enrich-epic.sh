#!/usr/bin/env bash
# Rewrite an Epic's body with the skill-enriched sections (Acceptance Criteria,
# Technical Analysis, Impact Assessment, enriched Testing Scope, Estimate Basis).
# The enriched
# block is delimited by HTML-comment markers so the human-authored sections
# survive and re-runs (reconcile) replace — not duplicate — the block.
#
# Usage:
#   enrich-epic.sh --repo NAME --number N --enriched-file PATH|-  [--dry-run]
#   enrich-epic.sh --merge-test OLD_FILE ENRICHED_FILE            (prints merged body; used by tests)
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_TAG="enrich"
# shellcheck source-path=SCRIPTDIR source=_common.sh
. "$SKILL_DIR/_common.sh"
resolve_python

START_MARKER="<!-- epic-breakdown:enriched -->"
END_MARKER="<!-- /epic-breakdown:enriched -->"

# merge_body OLD_FILE ENRICHED_FILE -> merged body on stdout.
# Idempotent: if the markers already exist, replace the block between them;
# otherwise append a fresh block after the existing (human) content.
merge_body() {
  START="$START_MARKER" END="$END_MARKER" "$PYTHON" - "$1" "$2" <<'PY'
import os, sys
if hasattr(sys.stdout, "reconfigure"):  # 3.7+; PYTHONIOENCODING covers 3.6
    sys.stdout.reconfigure(encoding="utf-8")
old = open(sys.argv[1], encoding="utf-8").read()
enriched = open(sys.argv[2], encoding="utf-8").read().strip()
start, end = os.environ["START"], os.environ["END"]
block = start + "\n" + enriched + "\n" + end
if start in old and end in old:
    pre = old.split(start)[0]
    post = old.split(end, 1)[1]
    out = pre.rstrip() + "\n\n" + block + post
else:
    out = old.rstrip() + "\n\n" + block + "\n"
sys.stdout.write(out)
PY
}

# Test hook: merge two files and print, no network.
if [ "${1:-}" = "--merge-test" ]; then
  [ $# -eq 3 ] || fail "usage: --merge-test OLD_FILE ENRICHED_FILE"
  merge_body "$2" "$3"
  exit 0
fi

REPO="" NUMBER="" ENRICHED_FILE="" DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)          REPO="${2:-}"; shift 2 ;;
    --number)        NUMBER="${2:-}"; shift 2 ;;
    --enriched-file) ENRICHED_FILE="${2:-}"; shift 2 ;;
    --dry-run)       DRY_RUN=1; shift ;;
    *)               fail "unknown arg: $1" ;;
  esac
done

[ -n "$REPO" ]          || fail "--repo is required"
[ -n "$NUMBER" ]        || fail "--number is required"
[ -n "$ENRICHED_FILE" ] || fail "--enriched-file is required"

# Single cleanup trap; both vars are declared up front so set -u is happy and the
# trap covers whichever temp files get created below.
TMP_ENRICHED="" OLD_BODY_FILE=""
trap 'rm -f "$TMP_ENRICHED" "$OLD_BODY_FILE"' EXIT

if [ "$ENRICHED_FILE" = "-" ]; then
  TMP_ENRICHED=$(mktemp); cat > "$TMP_ENRICHED"; ENRICHED_FILE="$TMP_ENRICHED"
fi
[ -f "$ENRICHED_FILE" ] || fail "enriched file not found: $ENRICHED_FILE"

OLD_BODY_FILE=$(mktemp)
gh issue view "$NUMBER" --repo "$ORG/$REPO" --json body --jq '.body' > "$OLD_BODY_FILE" \
  || fail "could not read issue #$NUMBER in $ORG/$REPO"

MERGED=$(merge_body "$OLD_BODY_FILE" "$ENRICHED_FILE")

if [ "$DRY_RUN" -eq 1 ]; then
  log "DRY-RUN — would rewrite body of $ORG/$REPO#$NUMBER to:"
  printf '%s\n' "$MERGED" >&2
  exit 0
fi

printf '%s' "$MERGED" | gh issue edit "$NUMBER" --repo "$ORG/$REPO" --body-file - \
  || fail "gh issue edit failed for #$NUMBER"
log "enriched Epic body: $ORG/$REPO#$NUMBER"
