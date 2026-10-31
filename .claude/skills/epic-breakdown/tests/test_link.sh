#!/usr/bin/env bash
# Tests link.sh argument handling, dry-run, and the different-parent refusal
# (against a stubbed gh). No network.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LINK="$HERE/../link.sh"

# 1) Sub-issue dry-run prints the planned addSubIssue.
out=$(bash "$LINK" --parent-node-id I_PARENT --child-node-id I_CHILD --dry-run 2>&1)
echo "$out" | grep -q "addSubIssue" || { echo "FAIL: no addSubIssue in dry-run"; exit 1; }

# 2) Blocked-by dry-run prints the planned addBlockedBy.
out=$(bash "$LINK" --issue-node-id I_A --blocked-by-node-id I_B --dry-run 2>&1)
echo "$out" | grep -q "addBlockedBy" || { echo "FAIL: no addBlockedBy in dry-run"; exit 1; }

# 3) Mixing modes is rejected.
if bash "$LINK" --parent-node-id P --child-node-id C --issue-node-id X --blocked-by-node-id Y --dry-run >/dev/null 2>&1; then
  echo "FAIL: mixed modes accepted"; exit 1
fi

# 4) Incomplete pair is rejected.
if bash "$LINK" --parent-node-id P --dry-run >/dev/null 2>&1; then
  echo "FAIL: incomplete sub-issue pair accepted"; exit 1
fi

# 5) A child that already has a different parent is refused, not silently skipped.
STUB_DIR=$(mktemp -d)
trap 'rm -rf "$STUB_DIR"' EXIT
cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = "api" ] && echo "I_OTHER_PARENT ilm#409"
exit 0
STUB
chmod +x "$STUB_DIR/gh"
if out=$(PATH="$STUB_DIR:$PATH" bash "$LINK" --parent-node-id I_PARENT --child-node-id I_CHILD 2>&1); then
  echo "FAIL: child under a different parent reported success"; exit 1
fi
echo "$out" | grep -q "different parent (ilm#409)" || { echo "FAIL: conflict not named"; echo "$out"; exit 1; }

echo "PASS"
