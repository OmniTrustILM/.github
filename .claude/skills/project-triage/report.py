"""Render the findings Markdown report.

Reads (from $TRIAGE_DIR, default .triage/):
  findings.json   surviving findings from eval.py
  summary.json    {total, violating, errors, score}
  filtered.json   the issues evaluated (for per-assignee breakdown)
  scope.json      optional {filters: {...}, config_sha: "..."} — for report headers

Writes:
  report.md       the Markdown report

Also prints the report to stdout.
"""

import collections
import json
import os
from pathlib import Path

BASE = Path(os.environ.get('TRIAGE_DIR', '.triage')).resolve()


def load_json(name, default=None):
    p = BASE / name
    if not p.exists():
        return default
    return json.loads(p.read_text(encoding='utf-8'))


findings = load_json('findings.json', [])
summary = load_json('summary.json', {'total': 0, 'violating': 0, 'errors': 0, 'score': 100})
target = load_json('filtered.json', [])
scope = load_json('scope.json', {'filters': {}, 'config_sha': ''})

errors = [f for f in findings if f['level'] == 'Error']
warnings_ = [f for f in findings if f['level'] == 'Warning']


def group_by_issue(fs):
    groups = collections.OrderedDict()
    for f in fs:
        groups.setdefault((f['repo'], f['number']), []).append(f)
    return groups


def short_type(t):
    return t or '(no-type)'


def filter_description(filters):
    parts = []
    if filters.get('version'):
        parts.append(f"Version={filters['version']}")
    if filters.get('assignee'):
        parts.append(f"Assignee={filters['assignee']}")
    if filters.get('repo'):
        parts.append(f"Repo={filters['repo']}")
    return ', '.join(parts) if parts else 'all open issues'


config_sha = scope.get('config_sha') or ''
sha_label = f"`{config_sha[:8]}`" if config_sha else '(unknown)'

out = []
out.append('## Project #5 - Triage Report')
out.append(f"**Scope:** {filter_description(scope.get('filters', {}))}")
out.append(f'**Source:** config @ {sha_label}')
out.append(f"**Evaluated:** {summary['total']} issues  |  **Health score:** {summary['score']} / 100")
out.append('')

if not findings:
    out.append('✅ No findings.')
else:
    out.append(f'### Errors ({len(errors)})' if errors else '### Errors')
    if errors:
        for key, fs in group_by_issue(errors).items():
            sample = fs[0]
            msgs = ', '.join(f['msg'] for f in fs)
            assignees = ', '.join(sample.get('assignees') or []) or '_unassigned_'
            out.append(
                f"- [{sample['repo']}#{sample['number']}]({sample['url']}) {short_type(sample['type'])} "
                f"[{sample.get('status') or '-'}] ({assignees}) - {msgs}"
            )
    else:
        out.append('_None._')

    out.append('')
    out.append(f'### Warnings ({len(warnings_)})' if warnings_ else '### Warnings')
    if warnings_:
        for key, fs in group_by_issue(warnings_).items():
            sample = fs[0]
            msgs = ', '.join(f['msg'] for f in fs)
            assignees = ', '.join(sample.get('assignees') or []) or '_unassigned_'
            out.append(
                f"- [{sample['repo']}#{sample['number']}]({sample['url']}) {short_type(sample['type'])} "
                f"[{sample.get('status') or '-'}] ({assignees}) - {msgs}"
            )
    else:
        out.append('_None._')

# Per-Version breakdown (only meaningful when no --version filter is applied)
version_stats = collections.defaultdict(lambda: {'open': set(), 'err': set(), 'warn': set()})
error_keys = {(f['repo'], f['number']) for f in errors}
warning_keys = {(f['repo'], f['number']) for f in warnings_}
for it in target:
    c = it['content']
    k = (c['repository']['name'], c['number'])
    v = None
    for fv in it['fieldValues']['nodes']:
        fd = fv.get('field') or {}
        if fd.get('name') == 'Version':
            v = fv.get('name')
            break
    v = v or '_Unversioned_'
    version_stats[v]['open'].add(k)
    if k in error_keys:
        version_stats[v]['err'].add(k)
    if k in warning_keys and k not in error_keys:
        version_stats[v]['warn'].add(k)

if version_stats:
    out.append('')
    out.append('### Per-Version')
    out.append('')
    out.append('| Version | Open | Errors | Warnings |')
    out.append('|---|---|---|---|')
    for v in sorted(version_stats.keys()):
        s = version_stats[v]
        out.append(f"| {v} | {len(s['open'])} | {len(s['err'])} | {len(s['warn'])} |")

# Per-assignee breakdown (top 10 by open)
assignee_stats = collections.defaultdict(lambda: {'open': set(), 'err': set(), 'warn': set()})
for it in target:
    c = it['content']
    k = (c['repository']['name'], c['number'])
    asns = [a['login'] for a in (c.get('assignees', {}).get('nodes') or [])]
    if not asns:
        asns = ['_unassigned_']
    for a in asns:
        assignee_stats[a]['open'].add(k)
for f in errors:
    for a in (f.get('assignees') or ['_unassigned_']):
        assignee_stats[a]['err'].add((f['repo'], f['number']))
for f in warnings_:
    for a in (f.get('assignees') or ['_unassigned_']):
        assignee_stats[a]['warn'].add((f['repo'], f['number']))

rows = sorted(assignee_stats.items(), key=lambda kv: -len(kv[1]['open']))[:10]
if rows:
    out.append('')
    out.append('### Per-assignee (top 10)')
    out.append('')
    out.append('| Assignee | Open | Errors | Warnings |')
    out.append('|---|---|---|---|')
    for a, s in rows:
        out.append(f"| {a} | {len(s['open'])} | {len(s['err'])} | {len(s['warn'])} |")

# Findings by rule
if findings:
    out.append('')
    out.append('### Findings by rule')
    out.append('')
    rule_counts = collections.Counter(f['rule'] for f in findings)
    out.append('| Rule | Level | Count |')
    out.append('|---|---|---|')
    for rule, n in rule_counts.most_common():
        lvl = next((f['level'] for f in findings if f['rule'] == rule), '')
        out.append(f'| `{rule}` | {lvl} | {n} |')

report = '\n'.join(out) + '\n'
(BASE / 'report.md').write_text(report, encoding='utf-8')
print(report)
