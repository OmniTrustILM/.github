#!/usr/bin/env bash
# Fetch + cache everything eval.py needs.
#
# Env (all optional):
#   TRIAGE_DIR    output directory (default: .triage)
#   VERSION       filter by project Version field
#   ASSIGNEE      filter by assignee login
#   REPO          filter by repository short-name (e.g. "core")
#
# Writes into $TRIAGE_DIR:
#   rules.yml, rules.json          triage rules
#   items.json                     raw paginated GraphQL response
#   items-flat.json                concatenated nodes across pages
#   filtered.json                  open subset after filters applied
#   filtered-closed.json           closed-as-completed subset (closed_but_not_done)
#   members.txt                    org member logins
#   subs-<repo>-<num>.json         Epic sub-issue lists (on demand)
#   blocked-<repo>-<num>.json      In Progress blocked-by lists (on demand)
#   scope.json                     {filters, config_sha} for the report
#
# Dependencies: gh (read:org + read:project). python3 (or python). For the rules
# YAML->JSON step: yq OR Python PyYAML.
set -euo pipefail

TRIAGE_DIR=${TRIAGE_DIR:-.triage}
export TRIAGE_DIR   # so the inline python blocks below see it via os.environ
mkdir -p "$TRIAGE_DIR"
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { echo "[fetch] $*" >&2; }

# Resolve one Python interpreter (python3 preferred) for every inline block below,
# and fail early with a clear message instead of a later "python: command not found".
PYTHON="$(command -v python3 || command -v python || true)"
[ -n "$PYTHON" ] || { echo "error: python3 (or python) not found on PATH" >&2; exit 1; }

# --- 1. Verify auth + scopes ---
if ! gh auth status >/dev/null 2>&1; then
  echo "error: gh not authenticated. Run: gh auth login" >&2
  exit 1
fi
# Capture the scopes line once; empty means a fine-grained PAT / App token whose
# scopes gh can't enumerate — skip and let the API enforce rather than false-reject.
SCOPES_LINE=$(gh auth status 2>&1 | grep -E "Token scopes:" || true)
if [ -n "$SCOPES_LINE" ]; then
  if ! printf '%s' "$SCOPES_LINE" | grep -q 'read:org'; then
    echo "error: token missing read:org scope. Run: gh auth refresh -s read:org" >&2
    exit 1
  fi
  # Reading Project #5 items (query.graphql) requires read:project (or project).
  if ! printf '%s' "$SCOPES_LINE" | grep -qE "'(read:project|project)'"; then
    echo "error: token missing read:project scope (needed to read Project #5). Run: gh auth refresh -s read:project" >&2
    exit 1
  fi
fi

# --- 2. Load triage rules ---
CONFIG_REPO="OmniTrustILM/.github"
CONFIG_PATH="config/project-triage-rules.yml"
CONFIG_SHA=""

if git -C . config --get remote.origin.url 2>/dev/null | grep -qi 'OmniTrustILM/.github'; then
  log "config: local clone"
  cp "$CONFIG_PATH" "$TRIAGE_DIR/rules.yml"
  CONFIG_SHA="$(git -C . rev-parse HEAD 2>/dev/null || echo '')"
else
  log "config: fetching from API"
  gh api "repos/$CONFIG_REPO/contents/$CONFIG_PATH" --jq '.content' | base64 -d > "$TRIAGE_DIR/rules.yml"
  CONFIG_SHA="$(gh api "repos/$CONFIG_REPO/commits?path=$CONFIG_PATH&per_page=1" --jq '.[0].sha' 2>/dev/null || echo '')"
fi

# YAML -> JSON: prefer yq; fall back to Python + PyYAML. PyYAML is NOT stdlib, so
# check for it and emit an actionable hint rather than a ModuleNotFoundError trace.
if command -v yq >/dev/null 2>&1; then
  yq eval -o=json "$TRIAGE_DIR/rules.yml" > "$TRIAGE_DIR/rules.json"
elif "$PYTHON" -c 'import yaml' >/dev/null 2>&1; then
  "$PYTHON" -c "import sys, yaml, json; json.dump(yaml.safe_load(sys.stdin), sys.stdout)" \
    < "$TRIAGE_DIR/rules.yml" > "$TRIAGE_DIR/rules.json"
else
  echo "error: parsing the rules YAML needs either 'yq' or Python PyYAML." >&2
  echo "  install yq (https://github.com/mikefarah/yq), or run: $PYTHON -m pip install pyyaml" >&2
  exit 1
fi

# --- 3. Cache org members ---
log "fetching org members"
gh api --paginate "orgs/OmniTrustILM/members" --jq '.[].login' | sort -u > "$TRIAGE_DIR/members.txt"

# --- 4. Paginate project items ---
log "fetching project items (GraphQL)"
gh api graphql --paginate -f query="$(cat "$SKILL_DIR/query.graphql")" > "$TRIAGE_DIR/items.json"

# Flatten: collect all .data.organization.projectV2.items.nodes across pages into one array
"$PYTHON" - <<PYEOF
import json, os
base = os.environ.get('TRIAGE_DIR', '.triage')
raw = open(os.path.join(base, 'items.json'), encoding='utf-8').read()
# gh --paginate concatenates JSON responses; parse each object
docs = []
decoder = json.JSONDecoder()
idx = 0
while idx < len(raw):
    while idx < len(raw) and raw[idx].isspace():
        idx += 1
    if idx >= len(raw):
        break
    obj, end = decoder.raw_decode(raw, idx)
    docs.append(obj)
    idx = end
nodes = []
for d in docs:
    nodes.extend(d['data']['organization']['projectV2']['items']['nodes'])
json.dump(nodes, open(os.path.join(base, 'items-flat.json'), 'w', encoding='utf-8'), indent=2)
print(f"flattened {len(nodes)} items across {len(docs)} pages")
PYEOF

# --- 5. Apply filters ---
log "filtering (version=${VERSION:-}, assignee=${ASSIGNEE:-}, repo=${REPO:-})"
VERSION="${VERSION:-}" ASSIGNEE="${ASSIGNEE:-}" REPO="${REPO:-}" "$PYTHON" - <<'PYEOF'
import json, os
base = os.environ.get('TRIAGE_DIR', '.triage')
items = json.load(open(os.path.join(base, 'items-flat.json'), encoding='utf-8'))
version = os.environ.get('VERSION', '').strip() or None
assignee = os.environ.get('ASSIGNEE', '').strip() or None
repo = os.environ.get('REPO', '').strip() or None

def field_value(item, name):
    for fv in item['fieldValues']['nodes']:
        f = fv.get('field') or {}
        if f.get('name') == name:
            return fv.get('name') or fv.get('number') or fv.get('date') or fv.get('text') or fv.get('title')
    return None

out = []
closed_out = []
for it in items:
    c = it.get('content') or {}
    if not c:
        continue
    if version and field_value(it, 'Version') != version:
        continue
    if assignee:
        logins = {a['login'] for a in (c.get('assignees', {}).get('nodes') or [])}
        if assignee not in logins:
            continue
    if repo and c['repository']['name'] != repo:
        continue
    state = c.get('state')
    if state == 'OPEN':
        out.append(it)
    elif state == 'CLOSED' and (c.get('stateReason') or '').upper() == 'COMPLETED':
        # COMPLETED-only: not-planned / duplicate closes are legitimate (§7.3) and
        # are excluded from the closed_but_not_done check downstream.
        closed_out.append(it)

json.dump(out, open(os.path.join(base, 'filtered.json'), 'w', encoding='utf-8'), indent=2)
json.dump(closed_out, open(os.path.join(base, 'filtered-closed.json'), 'w', encoding='utf-8'), indent=2)
print(f"filtered: {len(out)} open, {len(closed_out)} closed-completed of {len(items)} items")
PYEOF

# --- 6. On-demand enrichment: sub-issues for Epics, blocked-by for In Progress ---
log "enriching Epics with sub-issues and In Progress with blocked-by"
TRIAGE_DIR="$TRIAGE_DIR" "$PYTHON" - <<'PYEOF'
import json, os, subprocess
base = os.environ.get('TRIAGE_DIR', '.triage')
target = json.load(open(os.path.join(base, 'filtered.json'), encoding='utf-8'))

def field_value(item, name):
    for fv in item['fieldValues']['nodes']:
        f = fv.get('field') or {}
        if f.get('name') == name:
            return fv.get('name') or fv.get('number') or fv.get('date') or fv.get('text') or fv.get('title')
    return None

PREVIEW = 'Accept: application/vnd.github.issue-deps-preview+json'
n_subs = n_blocked = 0

for it in target:
    c = it['content']
    repo = c['repository']['name']
    num = c['number']
    t = (c.get('issueType') or {}).get('name')
    status = field_value(it, 'Status')

    if t == 'Epic' and c.get('subIssues', {}).get('totalCount', 0) > 0:
        out = os.path.join(base, f'subs-{repo}-{num}.json')
        if not os.path.exists(out):
            try:
                r = subprocess.run(
                    ['gh', 'api', '-H', PREVIEW, f'repos/OmniTrustILM/{repo}/issues/{num}/sub_issues'],
                    capture_output=True, text=True, timeout=30
                )
                if r.returncode == 0:
                    open(out, 'w', encoding='utf-8').write(r.stdout)
                    n_subs += 1
                else:
                    open(out + '.err', 'w').write(r.stderr)
            except Exception as e:
                open(out + '.err', 'w').write(str(e))

    if status == 'In Progress':
        out = os.path.join(base, f'blocked-{repo}-{num}.json')
        if not os.path.exists(out):
            try:
                r = subprocess.run(
                    ['gh', 'api', '-H', PREVIEW, f'repos/OmniTrustILM/{repo}/issues/{num}/dependencies/blocked_by'],
                    capture_output=True, text=True, timeout=30
                )
                if r.returncode == 0:
                    open(out, 'w', encoding='utf-8').write(r.stdout)
                    n_blocked += 1
                else:
                    # 404 = preview not enabled on that repo; cache empty array so we skip next run
                    open(out, 'w').write('[]')
                    open(out + '.err', 'w').write(r.stderr)
            except Exception as e:
                open(out + '.err', 'w').write(str(e))

print(f"enriched: {n_subs} Epics with sub-issues, {n_blocked} issues with blocked_by")
PYEOF

# --- 7. Write scope.json for the report ---
# Env assignments MUST be in prefix position to reach the python process; placed
# after `python -c` they would be positional args and os.environ would miss them
# (this previously left config_sha always empty and could KeyError on TRIAGE_DIR).
CONFIG_SHA="$CONFIG_SHA" VERSION="${VERSION:-}" ASSIGNEE="${ASSIGNEE:-}" REPO="${REPO:-}" \
"$PYTHON" -c "
import json, os
json.dump({
    'filters': {
        'version': os.environ.get('VERSION') or None,
        'assignee': os.environ.get('ASSIGNEE') or None,
        'repo': os.environ.get('REPO') or None,
    },
    'config_sha': os.environ.get('CONFIG_SHA') or '',
}, open(os.path.join(os.environ.get('TRIAGE_DIR', '.triage'), 'scope.json'), 'w'))
"

log "fetch complete. Output: $TRIAGE_DIR/"
