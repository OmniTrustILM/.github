"""Offer per-finding auto-fixes after user confirmation.

Reads:  findings.json, filtered.json (from $TRIAGE_DIR).
Invokes gh / GraphQL mutations for fixable findings only.

Usage (driven by the calling agent, not invoked directly by humans):
  1. Parse findings.json
  2. For each fixable finding, ask the user y/n/a/q via the agent interface
  3. Call `apply_fix(finding, project_id)` to execute

This module exposes helper functions rather than a CLI — the orchestrating
agent controls the per-finding prompt flow and aggregates results.

The Project #5 node ID is discovered at runtime (never hardcoded) via
`get_project_id()`, so it cannot go stale if the project is ever recreated.
"""

import json
import os
import subprocess
from pathlib import Path

BASE = Path(os.environ.get('TRIAGE_DIR', '.triage')).resolve()

PROJECT_OWNER = 'OmniTrustILM'
PROJECT_NUMBER = 5
_PROJECT_ID = None


def get_project_id():
    """Resolve Project #5's node ID live, memoised for the process."""
    global _PROJECT_ID
    if _PROJECT_ID is None:
        query = 'query($owner:String!,$num:Int!){organization(login:$owner){projectV2(number:$num){id}}}'
        out = _gh(['api', 'graphql', '-f', f'owner={PROJECT_OWNER}', '-F', f'num={PROJECT_NUMBER}', '-f', f'query={query}'])
        _PROJECT_ID = json.loads(out)['data']['organization']['projectV2']['id']
    return _PROJECT_ID

FIXABLE_RULES = {
    'done_but_open_state',
    'closed_but_not_done',
    'version_mismatch',
    'orphaned_sub_issues',
}


def load_findings():
    return json.loads((BASE / 'findings.json').read_text(encoding='utf-8'))


def load_items():
    return json.loads((BASE / 'filtered.json').read_text(encoding='utf-8'))


def field_node(item, name):
    for fv in item['fieldValues']['nodes']:
        f = fv.get('field') or {}
        if f.get('name') == name:
            return fv
    return None


def find_item(items, repo, number):
    for it in items:
        c = it['content']
        if c['repository']['name'] == repo and c['number'] == number:
            return it
    return None


def find_parent_item(items, parent_info):
    for it in items:
        c = it['content']
        if (c['repository']['name'] == parent_info['repository']['name']
                and c['number'] == parent_info['number']):
            return it
    return None


def _gh(args, input_=None):
    r = subprocess.run(['gh'] + args, input=input_, capture_output=True, text=True, timeout=60)
    if r.returncode != 0:
        raise RuntimeError(f"gh failed: {' '.join(args)}\nstderr: {r.stderr}")
    return r.stdout


def get_field_id_and_option(field_name, option_name=None):
    """Resolve project field ID (and option ID if single-select)."""
    query = '''
      query($owner: String!, $num: Int!) {
        organization(login: $owner) {
          projectV2(number: $num) {
            fields(first: 50) {
              nodes {
                ... on ProjectV2SingleSelectField {
                  id
                  name
                  options { id name }
                }
                ... on ProjectV2Field {
                  id
                  name
                }
              }
            }
          }
        }
      }
    '''
    out = _gh(['api', 'graphql', '-f', f'owner={PROJECT_OWNER}', '-F', f'num={PROJECT_NUMBER}', '-f', f'query={query}'])
    fields = json.loads(out)['data']['organization']['projectV2']['fields']['nodes']
    for f in fields:
        if f.get('name') == field_name:
            field_id = f['id']
            if option_name is None:
                return field_id, None
            for opt in f.get('options', []) or []:
                if opt['name'] == option_name:
                    return field_id, opt['id']
            raise ValueError(f"option '{option_name}' not found on field '{field_name}'")
    raise ValueError(f"field '{field_name}' not found on project")


def get_current_single_select(item_id, field_name):
    """Live-read a single-select field's current value on a project item (for
    concurrency re-checks before a write). Returns the option name or None."""
    query = '''
      query($id: ID!) {
        node(id: $id) {
          ... on ProjectV2Item {
            fieldValues(first: 50) {
              nodes {
                ... on ProjectV2ItemFieldSingleSelectValue {
                  name
                  field { ... on ProjectV2FieldCommon { name } }
                }
              }
            }
          }
        }
      }
    '''
    out = _gh(['api', 'graphql', '-f', f'id={item_id}', '-f', f'query={query}'])
    node = (json.loads(out).get('data', {}) or {}).get('node') or {}
    for n in node.get('fieldValues', {}).get('nodes', []):
        f = n.get('field') or {}
        if f.get('name') == field_name:
            return n.get('name')
    return None


def apply_fix(finding, items):
    """Apply a single fix. Re-checks concurrent state first.

    Returns a dict: {ok: bool, message: str}.
    """
    rule = finding['rule']
    if rule not in FIXABLE_RULES:
        return {'ok': False, 'message': f'rule {rule} is not in the fixable set'}

    repo = finding['repo']
    number = finding['number']
    item = find_item(items, repo, number)
    if not item:
        return {'ok': False, 'message': 'item not in filtered set (stale cache?)'}

    # ---- done_but_open_state: close the issue ----
    if rule == 'done_but_open_state':
        # Concurrency re-check: fetch current state
        out = _gh(['issue', 'view', str(number), '--repo', f'{PROJECT_OWNER}/{repo}', '--json', 'state'])
        current = json.loads(out).get('state', '').upper()
        if current != 'OPEN':
            return {'ok': False, 'message': f'issue now {current}, skipped'}
        _gh(['issue', 'close', str(number), '--repo', f'{PROJECT_OWNER}/{repo}', '--reason', 'completed'])
        return {'ok': True, 'message': f'closed {repo}#{number} as completed'}

    # ---- closed_but_not_done: set Status=Done ----
    if rule == 'closed_but_not_done':
        c = item['content']
        if c.get('stateReason') != 'COMPLETED':
            return {'ok': False, 'message': f"stateReason={c.get('stateReason')} — not a COMPLETED close, skipped"}
        status_fv = field_node(item, 'Status')
        if status_fv and status_fv.get('name') == 'Done':
            return {'ok': False, 'message': 'Status already Done (stale finding)'}
        field_id, opt_id = get_field_id_and_option('Status', 'Done')
        mutation = '''
          mutation($proj: ID!, $item: ID!, $field: ID!, $opt: String!) {
            updateProjectV2ItemFieldValue(input: {
              projectId: $proj, itemId: $item, fieldId: $field,
              value: { singleSelectOptionId: $opt }
            }) { projectV2Item { id } }
          }
        '''
        _gh(['api', 'graphql',
             '-f', f'proj={get_project_id()}',
             '-f', f'item={item["id"]}',
             '-f', f'field={field_id}',
             '-f', f'opt={opt_id}',
             '-f', f'query={mutation}'])
        return {'ok': True, 'message': f'set Status=Done on {repo}#{number}'}

    # ---- version_mismatch: copy parent Version to child (only when child empty) ----
    if rule == 'version_mismatch':
        fd = finding.get('fix_data') or {}
        my_v = fd.get('my_version')
        parent_v = fd.get('parent_version')
        if my_v:
            return {'ok': False, 'message': f'child has Version={my_v} set; manual reconciliation required'}
        if not parent_v:
            return {'ok': False, 'message': 'parent Version unknown'}
        # Concurrency re-check: the cached my_v may be stale — re-read live before writing.
        current_v = get_current_single_select(item['id'], 'Version')
        if current_v:
            return {'ok': False, 'message': f'child now has Version={current_v}; skipped (changed since fetch)'}
        field_id, opt_id = get_field_id_and_option('Version', parent_v)
        mutation = '''
          mutation($proj: ID!, $item: ID!, $field: ID!, $opt: String!) {
            updateProjectV2ItemFieldValue(input: {
              projectId: $proj, itemId: $item, fieldId: $field,
              value: { singleSelectOptionId: $opt }
            }) { projectV2Item { id } }
          }
        '''
        _gh(['api', 'graphql',
             '-f', f'proj={get_project_id()}',
             '-f', f'item={item["id"]}',
             '-f', f'field={field_id}',
             '-f', f'opt={opt_id}',
             '-f', f'query={mutation}'])
        return {'ok': True, 'message': f'set Version={parent_v} on {repo}#{number}'}

    # ---- orphaned_sub_issues: close the child ----
    if rule == 'orphaned_sub_issues':
        fd = finding.get('fix_data') or {}
        parent_closed = fd.get('parent_closed_at')
        my_updated = fd.get('my_updated_at')
        if parent_closed and my_updated and my_updated > parent_closed:
            return {'ok': False,
                    'message': f'child updated ({my_updated}) after parent close ({parent_closed}); may be active'}
        # Check no open PR linked
        out = _gh(['issue', 'view', str(number), '--repo', f'{PROJECT_OWNER}/{repo}',
                   '--json', 'state,closedByPullRequestsReferences'])
        doc = json.loads(out)
        if doc.get('state', '').upper() != 'OPEN':
            return {'ok': False, 'message': 'child already closed (stale finding)'}
        open_prs = [pr for pr in (doc.get('closedByPullRequestsReferences') or []) if pr.get('state') == 'OPEN']
        if open_prs:
            return {'ok': False, 'message': 'child has open PR linked; manual decision required'}
        _gh(['issue', 'close', str(number), '--repo', f'{PROJECT_OWNER}/{repo}', '--reason', 'completed'])
        return {'ok': True, 'message': f'closed {repo}#{number} (orphaned)'}

    return {'ok': False, 'message': f'unhandled rule {rule}'}


def preview(finding, items):
    """Human-readable preview string for a single finding's fix."""
    rule = finding['rule']
    repo = finding['repo']
    number = finding['number']
    url = finding['url']
    if rule == 'done_but_open_state':
        return f'Close {repo}#{number} ({url}) as completed.'
    if rule == 'closed_but_not_done':
        item = find_item(items, repo, number)
        sr = (item['content'].get('stateReason') if item else None) or 'unknown'
        return f'Set Status=Done on {repo}#{number}. Close reason: {sr}. (Only applied if stateReason=COMPLETED.)'
    if rule == 'version_mismatch':
        fd = finding.get('fix_data') or {}
        return (f'Set Version={fd.get("parent_version")} on {repo}#{number}. '
                f'Current child Version: {fd.get("my_version") or "empty"}. '
                f'(Only applied when child is empty.)')
    if rule == 'orphaned_sub_issues':
        return f'Close {repo}#{number} (orphaned — parent closed). Skipped if child has open PR or recent updates.'
    return f'(no preview for rule {rule})'


if __name__ == '__main__':
    # Diagnostic: list fixable findings
    items = load_items()
    for f in load_findings():
        if f['rule'] in FIXABLE_RULES:
            print(f"- [{f['level']}] {f['repo']}#{f['number']} ({f['rule']})")
            print(f"    {preview(f, items)}")
