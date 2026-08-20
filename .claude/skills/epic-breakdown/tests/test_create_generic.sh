#!/usr/bin/env bash
# Tests create-issue-generic.sh: dry-run planning, the form-token race guard,
# and one stubbed non-dry-run creation.
# Requires a warm cache (run.sh seeds it from create-issue for offline runs).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../create-issue-generic.sh"
CACHE="$HERE/../cache"

if [ ! -f "$CACHE/project-fields.json" ]; then
  echo "SKIP test_create_generic: no cache (run fetch.sh or tests/run.sh)"; exit 0
fi

# Pick a repo that exists in the cache so repo validation passes.
REPO=$(jq -r '.[0].name' "$CACHE/repos.json")

# 1) Dry-run for a Feature child: prints create + project add + type + module, no network.
out=$(printf '### Description\n\nx\n' | bash "$SCRIPT" \
  --repo "$REPO" --type feature --title "T" --body-file - --module Certificates --dry-run 2>&1)
echo "$out" | grep -q "gh issue create" || { echo "FAIL: no create in dry-run"; exit 1; }
echo "$out" | grep -qi "Module=Certificates" || { echo "FAIL: module not planned"; exit 1; }
echo "$out" | grep -q "node_id=(dry-run)" || { echo "FAIL: no node_id output"; exit 1; }

# 2) Epic type resolves (Epic shell creation path).
out=$(printf '### User Story\n\nx\n' | bash "$SCRIPT" \
  --repo "$REPO" --type epic --title "E" --body-file - --dry-run 2>&1)
echo "$out" | grep -qi "type Epic" || { echo "FAIL: epic type not resolved"; exit 1; }

# 3) Form-token guard REJECTS a body containing a Module section (hard fail).
if printf '### Description\n\nx\n\n### Module\n\nCertificates\n' | bash "$SCRIPT" \
     --repo "$REPO" --type bug --title "B" --body-file - --dry-run >/dev/null 2>&1; then
  echo "FAIL: form-token guard did not reject a body with a Module section"; exit 1
fi

# 4) Unknown type is rejected.
if printf 'x' | bash "$SCRIPT" --repo "$REPO" --type nonsense --title T --body-file - --dry-run >/dev/null 2>&1; then
  echo "FAIL: unknown type accepted"; exit 1
fi

# 5) Bug child with --severity: dry-run shows the planned Severity write.
out=$(printf '### Description\n\nx\n' | bash "$SCRIPT" \
  --repo "$REPO" --type bug --title "B" --body-file - --severity Major --dry-run 2>&1)
echo "$out" | grep -qi "Severity=Major" || { echo "FAIL: severity not planned"; exit 1; }

# 6) Regression: label-less Task, NON-dry-run, executed with /bin/bash.
# Bash 3.2 (macOS /bin/bash) under `set -u` treats an empty-array expansion as an
# unbound variable, so an unguarded "${LABEL_FLAGS[@]}" crashed the real
# `gh issue create` line for label-less types. Dry-run exits before that line,
# hence this stubbed full-sequence run; `jq` stays real. Only reproduces the
# crash where /bin/bash is 3.2 (macOS) - on Linux it covers the non-dry-run path.
STUB_DIR=$(mktemp -d)
trap 'rm -rf "$STUB_DIR"' EXIT
cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  auth)  exit 0 ;;  # no "Token scopes:" line -> require_project_scope passes
  issue) echo "https://github.com/OmniTrustILM/stub/issues/999" ;;
  api)
    if [ "${2:-}" = "graphql" ]; then
      echo '{"data":{"addProjectV2ItemById":{"item":{"id":"PVTI_stub"}}}}'
    else
      echo "I_stubnode"  # repos/.../issues/999 node_id lookup
    fi ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/gh"
out=$(printf '### Description\n\nx\n' | PATH="$STUB_DIR:$PATH" /bin/bash "$SCRIPT" \
  --repo "$REPO" --type task --title "Label-less regression" --body-file - 2>&1)
rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL: label-less non-dry-run creation exited $rc:"; echo "$out"; exit 1; }
echo "$out" | grep -q "url=https://github.com/OmniTrustILM/stub/issues/999" \
  || { echo "FAIL: no url output from stubbed creation"; echo "$out"; exit 1; }
echo "$out" | grep -q "node_id=I_stubnode" || { echo "FAIL: no node_id output"; echo "$out"; exit 1; }

echo "PASS"
