#!/usr/bin/env bash
# Run epic-breakdown's offline tests (dry-run + pure logic). Seeds the cache from
# the sibling create-issue skill when present so dry-run tests run without the
# project scope. The live test (test_fetch.sh) and the E2 live-proof are separate.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL="$(cd "$HERE/.." && pwd)"
CACHE="$SKILL/cache"
SIB="$SKILL/../create-issue/cache"

mkdir -p "$CACHE"
if [ ! -f "$CACHE/project-fields.json" ] && [ -d "$SIB" ]; then
  echo "[run] seeding cache from create-issue for offline dry-run tests (gitignored)"
  for f in project-fields.json repos.json templates.json issue-types.json labels.json; do
    [ -f "$SIB/$f" ] && cp "$SIB/$f" "$CACHE/$f"
  done
fi

PY="$(command -v python3 || command -v python)"
fails=0
run() { echo "=== $1 ==="; if bash "$HERE/$1"; then echo "ok"; else echo "FAIL $1"; fails=$((fails+1)); fi; }

run test_enrich.sh
run test_link.sh
run test_create_generic.sh
run test_set_fields.sh
run test_fetch.sh

echo "=== test_reconcile.py ==="
if "$PY" "$HERE/test_reconcile.py"; then echo "ok"; else echo "FAIL test_reconcile.py"; fails=$((fails+1)); fi

echo "----------------------------------------"
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails test file(s) failed"; exit 1; fi
