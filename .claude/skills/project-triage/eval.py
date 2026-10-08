"""Evaluate project items against triage rules.

Reads (from $TRIAGE_DIR, default .triage/):
  items-flat.json  all project items (flattened from paginated GraphQL)
  filtered.json    subset after --version / --assignee / --repo filters
  rules.json       triage rules (from config/project-triage-rules.yml)
  members.txt      cached org member logins (one per line)
  subs-<repo>-<num>.json     sub-issue lists (for Epic QA check) — optional
  blocked-<repo>-<num>.json  blocked-by lists (for In Progress check) — optional

Writes:
  findings.json    list of finding objects (post-precedence)
  summary.json     {total, violating, errors, score}

Prints a rule-count summary to stdout.
"""

import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from consistency import epic_status_findings, closed_but_not_done_finding, within_window  # noqa: E402

BASE = Path(os.environ.get('TRIAGE_DIR', '.triage')).resolve()
NOW = datetime.now(timezone.utc)


def load_json(name):
    return json.loads((BASE / name).read_text(encoding='utf-8'))


items = load_json('items-flat.json')
target = load_json('filtered.json')
rules = load_json('rules.json')
members = set(
    line.strip()
    for line in (BASE / 'members.txt').read_text(encoding='utf-8').splitlines()
    if line.strip()
)


def parse_dt(s):
    if not s:
        return None
    return datetime.fromisoformat(s.replace('Z', '+00:00'))


def field(item, name):
    for fv in item['fieldValues']['nodes']:
        f = fv.get('field') or {}
        if f.get('name') == name:
            return fv
    return None


def field_value(item, name):
    fv = field(item, name)
    if not fv:
        return None
    return fv.get('name') or fv.get('number') or fv.get('date') or fv.get('text') or fv.get('title')


def has_section(body, heading_regex):
    if not body:
        return False
    lines = body.splitlines()
    for i, line in enumerate(lines):
        if re.match(heading_regex, line.strip(), re.IGNORECASE):
            content = []
            for j in range(i + 1, len(lines)):
                if re.match(r'^#{1,6}\s', lines[j]):
                    break
                content.append(lines[j])
            txt = '\n'.join(content).strip()
            cleaned = re.sub(r'[_*]', '', txt).strip().lower()
            if cleaned in ('no response', ''):
                continue
            return True
    return False


BODY_SECTIONS = {
    'acceptance_criteria': r'^#{1,6}\s*acceptance criteria\b',
    'user_story': r'^#{1,6}\s*user stor(y|ies)\b',
    'use_cases': r'^#{1,6}\s*use cases?\b',
}

PROJECT_FIELDS = {
    'severity': 'Severity', 'module': 'Module', 'version': 'Version',
    # rule key stays `priority`; the Project #5 field was renamed
    'priority': 'Prioritization', 'complexity': 'Complexity',
    'estimate': 'Estimate', 'start_date': 'Start Date', 'end_date': 'End Date',
    'reopen_reason': 'Reopen Reason',
}


def is_field_missing(item, fkey):
    c = item['content']
    if fkey == 'assignee':
        return not c.get('assignees', {}).get('nodes')
    if fkey in BODY_SECTIONS:
        return not has_section(c.get('body') or '', BODY_SECTIONS[fkey])
    proj = PROJECT_FIELDS.get(fkey)
    if proj:
        return field_value(item, proj) in (None, '')
    return False


lookup = {}
for it in items:
    c = it.get('content') or {}
    if not c:
        continue
    lookup[(c['repository']['name'], c['number'])] = it


def load_sub_issues(repo, num):
    p = BASE / f'subs-{repo}-{num}.json'
    if p.exists():
        try:
            return json.loads(p.read_text(encoding='utf-8'))
        except Exception:
            return []
    return []


def load_blocked_by(repo, num):
    p = BASE / f'blocked-{repo}-{num}.json'
    if p.exists():
        try:
            return json.loads(p.read_text(encoding='utf-8'))
        except Exception:
            return None
    return []


findings = []


def add(it, level, rule, msg, fix_data=None):
    c = it['content']
    findings.append({
        'repo': c['repository']['name'],
        'number': c['number'],
        'title': c['title'],
        'url': c['url'],
        'type': (c.get('issueType') or {}).get('name') or None,
        'status': field_value(it, 'Status'),
        'assignees': [a['login'] for a in (c.get('assignees', {}).get('nodes') or [])],
        'level': level,
        'rule': rule,
        'msg': msg,
        'fix_data': fix_data,
    })


STALE = rules['staleness_thresholds']
STATUS_THRESHOLD = {
    'Planning': STALE['planning_days'],
    'Analysis': STALE['analysis_days'],
    'In Progress': STALE['in_progress_days'],
    'Review': STALE['review_days'],
    'Testing': STALE['testing_days'],
}


for it in target:
    c = it['content']
    t = (c.get('issueType') or {}).get('name')
    t_lower = (t or '').lower()
    status = field_value(it, 'Status')
    has_type = bool(t)
    if not has_type:
        add(it, 'Warning', 'missing_issue_type', 'issue type not set - evaluated as Task')
        t_lower = 'task'

    for f in rules['required_fields'].get(t_lower, []):
        if is_field_missing(it, f):
            add(it, 'Error', f'required:{f}', f'missing required field `{f}`')

    if status and status != 'Planning':
        for f in rules['required_past_planning'].get(t_lower, []):
            if is_field_missing(it, f):
                add(it, 'Error', f'required_past_planning:{f}', f'missing `{f}` (required past Planning)')

    for f in rules['recommended_fields'].get(t_lower, []):
        if is_field_missing(it, f):
            add(it, 'Warning', f'recommended:{f}', f'missing recommended field `{f}`')

    status_fv = field(it, 'Status')
    if status and status in STATUS_THRESHOLD:
        changed_at = parse_dt(status_fv.get('updatedAt')) if status_fv else parse_dt(c['createdAt'])
        age_days = (NOW - changed_at).days
        thr = STATUS_THRESHOLD[status]
        if age_days > thr:
            add(it, 'Warning', 'staleness', f'stale in {status} ~{age_days}d (threshold {thr}d)')
    elif status == 'Open':
        changed_at = parse_dt(status_fv.get('updatedAt')) if status_fv else parse_dt(c['createdAt'])
        age_days = (NOW - changed_at).days
        has_assignee = bool(c.get('assignees', {}).get('nodes'))
        thr = STALE['open_assigned_days'] if has_assignee else STALE['open_unassigned_days']
        if age_days > thr:
            state_label = 'assigned' if has_assignee else 'unassigned'
            add(it, 'Warning', 'staleness', f'stale in Open ({state_label}) ~{age_days}d (threshold {thr}d)')

    if rules['special_rules'].get('empty_epic_no_sub_issues') and t == 'Epic':
        if c['subIssues']['totalCount'] == 0:
            add(it, 'Error', 'empty_epic_no_sub_issues', 'Epic has no sub-issues')

    if rules['consistency_rules'].get('version_mismatch'):
        parent = c.get('parent')
        if parent:
            pkey = (parent['repository']['name'], parent['number'])
            p_item = lookup.get(pkey)
            if p_item:
                parent_v = field_value(p_item, 'Version')
                my_v = field_value(it, 'Version')
                if parent_v and parent_v != my_v:
                    add(it, 'Error', 'version_mismatch',
                        f'Version `{my_v or "(empty)"}` differs from parent [{parent["repository"]["name"]}#{parent["number"]}]({parent["url"]}) Version `{parent_v}`',
                        fix_data={'parent_version': parent_v, 'my_version': my_v})

    if rules['consistency_rules'].get('orphaned_sub_issues'):
        parent = c.get('parent')
        if parent:
            pkey = (parent['repository']['name'], parent['number'])
            p_item = lookup.get(pkey)
            if p_item and p_item['content'].get('state') == 'CLOSED':
                p_closed = p_item['content'].get('closedAt')
                add(it, 'Warning', 'orphaned_sub_issues',
                    f'parent [{parent["repository"]["name"]}#{parent["number"]}]({parent["url"]}) is closed',
                    fix_data={'parent_closed_at': p_closed, 'my_updated_at': c['updatedAt']})

    if rules['consistency_rules'].get('blocked_but_in_progress') and status == 'In Progress':
        bb = load_blocked_by(c['repository']['name'], c['number'])
        if isinstance(bb, list) and bb:
            open_blockers = [b for b in bb if (b.get('state') or '').lower() == 'open']
            if open_blockers:
                urls = ', '.join(b.get('html_url', '') for b in open_blockers[:3])
                add(it, 'Warning', 'blocked_but_in_progress', f'In Progress but blocked by: {urls}')

    if rules['consistency_rules'].get('done_but_open_state') and status == 'Done':
        add(it, 'Error', 'done_but_open_state', 'Status=Done but issue is still OPEN')

    if rules['consistency_rules'].get('reopened_without_reason'):
        reopen_events = c.get('timelineItems', {}).get('nodes') or []
        reopen_events = [e for e in reopen_events if e.get('createdAt')]
        if reopen_events and not field_value(it, 'Reopen Reason'):
            add(it, 'Warning', 'reopened_without_reason', f'reopened {len(reopen_events)}x without Reopen Reason')

    if rules['consistency_rules'].get('release_epic_by_non_org_member') and t in ('Release', 'Epic'):
        author = (c.get('author') or {}).get('login')
        if author and author not in members:
            add(it, 'Warning', 'release_epic_by_non_org_member',
                f'{t} authored by `{author}` (not in `{rules["authorized_org"]}`)')

    if rules['consistency_rules'].get('epic_without_qa_sub_issue') and t == 'Epic':
        if c['subIssues']['totalCount'] > 0:
            subs = load_sub_issues(c['repository']['name'], c['number'])
            has_qa = any(
                'qa' in [l.get('name', '').lower() for l in (s.get('labels') or [])]
                for s in subs
            )
            if not has_qa:
                add(it, 'Warning', 'epic_without_qa_sub_issue', 'Epic has no sub-issue with `qa` label')

    # §7.2 Epic-status consistency (logic mirrored from epic-breakdown/reconcile.py).
    # Child project Status comes from the `lookup` table; open/closed from sub_issues.
    _epic_status_rules = ('epic_done_with_open_children', 'epic_status_lags_children', 'epic_status_ahead_of_children')
    if t == 'Epic' and any(rules['consistency_rules'].get(r) for r in _epic_status_rules):
        subs = load_sub_issues(c['repository']['name'], c['number'])
        open_count = sum(1 for s in subs if (s.get('state') or '').upper() == 'OPEN')
        child_statuses = []
        for s in subs:
            # REST sub_issues objects carry repository_url (a string), not a nested
            # repository object; derive the repo name from it (defensive fallback).
            ru = s.get('repository_url') or ''
            srepo = ru.rstrip('/').split('/')[-1] if ru else (s.get('repository') or {}).get('name')
            sit = lookup.get((srepo, s.get('number')))
            if sit:
                cs = field_value(sit, 'Status')
                if cs:
                    child_statuses.append(cs)
        for level, rule, msg in epic_status_findings(status, child_statuses, open_count):
            if rules['consistency_rules'].get(rule):
                add(it, level, rule, msg)

# ---- closed_but_not_done: evaluate CLOSED-as-completed items (a separate set;
#      filtered.json is OPEN-only, so these come from filtered-closed.json) ----
if rules['consistency_rules'].get('closed_but_not_done'):
    window = rules.get('closed_but_not_done_window_days', 30)
    try:
        closed_items = load_json('filtered-closed.json')
    except FileNotFoundError:
        closed_items = []
    for it in closed_items:
        c = it['content']
        # Only flag recently-closed issues, so the rule doesn't surface every
        # legacy issue that predates the Status workflow.
        if not within_window(c.get('closedAt'), NOW, window):
            continue
        res = closed_but_not_done_finding(c.get('state'), c.get('stateReason'), field_value(it, 'Status'))
        if res:
            add(it, res[0], res[1], res[2])

# ---- rule precedence (§7.3) ----
CROSS_ISSUE = {'version_mismatch', 'orphaned_sub_issues', 'epic_without_qa_sub_issue'}
by_issue = {}
for f in findings:
    by_issue.setdefault((f['repo'], f['number']), []).append(f)

surviving = []
for key, fs in by_issue.items():
    has_error = any(f['level'] == 'Error' for f in fs)
    for f in fs:
        # §7.3 rule 1: an Error suppresses co-occurring Warnings on the same issue
        # (cross-issue rules excepted). done_but_open_state (OPEN-state) and
        # closed_but_not_done (CLOSED-state) can never share an issue, so no
        # explicit suppression between those two is needed.
        if has_error and f['level'] == 'Warning' and f['rule'] not in CROSS_ISSUE:
            continue
        surviving.append(f)

total = len(target)
# The score is calibrated against the OPEN working set (`target`). closed_but_not_done
# findings come from a separate closed-issue set and are reported in findings.json,
# but are excluded from the score so `violating` can never exceed `total`.
scored = [f for f in surviving if f['rule'] != 'closed_but_not_done']
violating_keys = {(f['repo'], f['number']) for f in scored}
error_keys = {(f['repo'], f['number']) for f in scored if f['level'] == 'Error'}
violating = len(violating_keys)
error_issues = len(error_keys)
score = round(100 - (error_issues * 3 + (violating - error_issues) * 1) / max(total, 1) * 10)
score = max(0, min(100, score))

(BASE / 'findings.json').write_text(json.dumps(surviving, indent=2), encoding='utf-8')
(BASE / 'summary.json').write_text(json.dumps({
    'total': total, 'violating': violating, 'errors': error_issues, 'score': score,
}))

print(f"total={total} violating={violating} errors={error_issues} score={score}")
print(f"surviving findings: {len(surviving)}")
rule_count = {}
for f in surviving:
    rule_count[f['rule']] = rule_count.get(f['rule'], 0) + 1
for k, v in sorted(rule_count.items(), key=lambda x: -x[1]):
    print(f"  {v:3d}  {k}")
