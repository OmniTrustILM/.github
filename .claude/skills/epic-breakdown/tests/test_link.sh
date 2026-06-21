#!/usr/bin/env bash
# Tests link.sh argument handling + dry-run. No network.
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

echo "PASS"
