#!/usr/bin/env bash
# Tests enrich-epic.sh's idempotent body-merge via the --merge-test hook.
# No network, no cache.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ENRICH="$HERE/../enrich-epic.sh"
START="<!-- epic-breakdown:enriched -->"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

printf '## User Story\n\nAs a user...\n' > "$TMP/old.md"
printf '## Acceptance Criteria\n\n- [ ] done\n' > "$TMP/enriched.md"

# 1) First enrichment: markers added once, original preserved.
out=$(bash "$ENRICH" --merge-test "$TMP/old.md" "$TMP/enriched.md")
count=$(printf '%s\n' "$out" | grep -cF "$START")
[ "$count" -eq 1 ] || { echo "FAIL: expected 1 start marker, got $count"; exit 1; }
printf '%s\n' "$out" | grep -q "As a user" || { echo "FAIL: original lost"; exit 1; }
printf '%s\n' "$out" | grep -q "Acceptance Criteria" || { echo "FAIL: enriched missing"; exit 1; }

# 2) Re-enrichment (idempotent): feed the merged body back; still exactly one block.
printf '%s\n' "$out" > "$TMP/old2.md"
printf '## Acceptance Criteria\n\n- [ ] updated\n' > "$TMP/enriched2.md"
out2=$(bash "$ENRICH" --merge-test "$TMP/old2.md" "$TMP/enriched2.md")
count2=$(printf '%s\n' "$out2" | grep -cF "$START")
[ "$count2" -eq 1 ] || { echo "FAIL: re-run produced $count2 markers (not idempotent)"; exit 1; }
printf '%s\n' "$out2" | grep -q "updated" || { echo "FAIL: re-run did not replace block"; exit 1; }
printf '%s\n' "$out2" | grep -q "As a user" || { echo "FAIL: re-run lost original"; exit 1; }
printf '%s\n' "$out2" | grep -q "\- \[ \] done" && { echo "FAIL: stale enriched content survived"; exit 1; }

# 3) Non-ASCII round trip. Glyphs are built from bytes rather than typed inline so
# the assertions cannot be weakened by this file's own encoding. The merge runs
# with PYTHONIOENCODING cleared from the environment, so what is under test is the
# script exporting it -- inheriting it from the caller would pass either way.
EMDASH=$(printf '\xe2\x80\x94')   # U+2014
ARROW=$(printf '\xe2\x86\x92')    # U+2192
GE=$(printf '\xe2\x89\xa5')       # U+2265
LQUO=$(printf '\xe2\x80\x9c')     # U+201C
RQUO=$(printf '\xe2\x80\x9d')     # U+201D
FFFD=$(printf '\xef\xbf\xbd')     # U+FFFD, what cp1252 stdio degrades to

printf '## User Story\n\nAs a user %s I want %sscope%s %s clarity.\n' \
  "$EMDASH" "$LQUO" "$RQUO" "$ARROW" > "$TMP/old3.md"
printf '## Acceptance Criteria\n\n- [ ] coverage %s 80%%\n' "$GE" > "$TMP/enriched3.md"

out3=$(env -u PYTHONIOENCODING bash "$ENRICH" --merge-test "$TMP/old3.md" "$TMP/enriched3.md") \
  || { echo "FAIL: merge errored on non-ASCII input"; exit 1; }

for g in "$EMDASH" "$ARROW" "$GE" "$LQUO" "$RQUO"; do
  case "$out3" in
    *"$g"*) ;;
    *) echo "FAIL: glyph lost in merge: $(printf '%s' "$g" | od -An -tx1 | tr -d ' ')"; exit 1 ;;
  esac
done
case "$out3" in
  *"$FFFD"*) echo "FAIL: U+FFFD in merged body (stdio encoding not forced to UTF-8)"; exit 1 ;;
esac
count3=$(printf '%s\n' "$out3" | grep -cF "$START")
[ "$count3" -eq 1 ] || { echo "FAIL: expected 1 start marker on non-ASCII merge, got $count3"; exit 1; }

# Second merge over the same content must be byte-identical, so re-enrichment
# neither drops nor re-encodes glyphs already in the body.
printf '%s\n' "$out3" > "$TMP/old4.md"
out4=$(env -u PYTHONIOENCODING bash "$ENRICH" --merge-test "$TMP/old4.md" "$TMP/enriched3.md") \
  || { echo "FAIL: second merge errored on non-ASCII body"; exit 1; }
[ "$out3" = "$out4" ] || { echo "FAIL: non-ASCII merge not idempotent"; exit 1; }

echo "PASS"
