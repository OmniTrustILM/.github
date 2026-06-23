---
name: project-triage
version: 2.0.0
description: >
  Use when a PM / tech lead wants a project health report on
  OmniTrustILM Project #5 — required-field gaps, stale issues,
  consistency violations, with optional per-finding auto-fixes.
tags:
  - github
  - projects
  - triage
  - ilm
inputs:
  - name: VERSION
    description: Filter scope to one Version field value.
    required: false
    example: 2.18.0
  - name: ASSIGNEE
    description: Filter scope to one assignee login.
    required: false
    example: lubomirw
  - name: REPO
    description: >
      Filter scope to one repo short name (no owner). Auto-detected
      from `.git/config` if run inside a clone of an OmniTrustILM repo.
    required: false
    example: core
    auto_detect:
      source: .git/config
      field: remote.origin.url
      pattern: 'github\.com[:/]OmniTrustILM/(?P<repo>[^/.]+)'
permissions:
  - cli:gh:read
  - cli:gh:write
  - cli:python:read
  - github:projects:read
  - github:projects:write
  - github:issues:read
  - github:issues:write
  - github:org:read
  - github:contents:read
created_at: 2026-04-21
updated_at: 2026-04-22
---

# Skill: Project Triage

Evaluate open issues in `OmniTrustILM` Project #5 against the triage rules in `config/project-triage-rules.yml`, emit a Markdown report, and offer per-finding auto-fixes after confirmation.

Logic is pre-written as shell + Python scripts in this skill directory. **Do not re-derive GraphQL queries or rule-evaluation logic** — invoke the scripts below.

---

## Orchestration

The skill is three steps (+ optional fixes). Each step reads and writes a `$TRIAGE_DIR` (default `.triage/`) under the user's current working directory.

### Step 1 — Fetch

```bash
cd <any dir, e.g. the .github clone>
export VERSION="2.18.0"      # optional
export ASSIGNEE="lubomirw"   # optional
export REPO="core"           # optional
export TRIAGE_DIR=".triage"  # optional; where to cache files
bash $SKILL_DIR/fetch.sh
```

`fetch.sh` handles:
1. `gh auth status` + `read:org` / `read:project` scope check
2. Load `config/project-triage-rules.yml` (local clone if inside `.github` repo, else API) → `rules.yml` + `rules.json`
3. Cache org members → `members.txt`
4. Paginate Project #5 items via GraphQL (`query.graphql`) → `items.json` → flatten → `items-flat.json`
5. Apply filters → `filtered.json` (open) + `filtered-closed.json` (closed-as-completed, for the `closed_but_not_done` rule)
6. Enrich: fetch sub-issues for Epics and blocked-by for In Progress → `subs-*.json`, `blocked-*.json`
7. Write `scope.json` (filters + config SHA for report headers)

### Step 2 — Evaluate

```bash
TRIAGE_DIR=".triage" python $SKILL_DIR/eval.py
```

Produces `findings.json` + `summary.json` + a rule-count printout. Implements all required-field checks, recommended-field warnings, staleness thresholds, consistency rules, special rules, and precedence (§7.3 of the methodics).

### Step 3 — Report

```bash
TRIAGE_DIR=".triage" python $SKILL_DIR/report.py
```

Prints the Markdown report to stdout and writes `report.md`.

### Step 4 (optional) — Auto-fix

The `fix.py` module exposes `preview(finding, items)` and `apply_fix(finding, items)`. Fixable rules: `done_but_open_state`, `closed_but_not_done`, `version_mismatch`, `orphaned_sub_issues` — with safety guards (stateReason check, empty-child check, concurrent state re-check).

Orchestration pattern (implemented by the calling agent, not by `fix.py`):

```python
import json, os
os.environ['TRIAGE_DIR'] = '.triage'
from fix import load_findings, load_items, preview, apply_fix, FIXABLE_RULES

findings = load_findings()
items = load_items()
fixable = [f for f in findings if f['rule'] in FIXABLE_RULES]

applied = skipped = failed = 0
yes_to_all = False
for i, f in enumerate(fixable, 1):
    print(f"[{i}/{len(fixable)}] {f['level']} {f['repo']}#{f['number']} — {f['rule']}")
    print(f"    {preview(f, items)}")
    if not yes_to_all:
        ans = input("Apply? (y/n/a=yes-to-remaining/q=quit): ").strip().lower()
        if ans == 'q': break
        if ans == 'a': yes_to_all = True
        elif ans != 'y': skipped += 1; continue
    try:
        r = apply_fix(f, items)
        if r['ok']: applied += 1; print(f"    ✓ {r['message']}")
        else:       skipped += 1; print(f"    - {r['message']}")
    except Exception as e:
        failed += 1; print(f"    ✗ {e}")
        if yes_to_all and failed >= 3:
            print("    (3 consecutive failures in yes-to-all; pausing)")
            yes_to_all = False
```

### Step 5 — Summary line

```
Evaluated: <N> issues. Findings: <E> errors, <W> warnings. Fixes: <F> applied, <S> skipped, <X> failed.
```

---

## Error handling

| Situation | Action |
|---|---|
| `gh auth status` fails | tell user to run `gh auth login` |
| Missing `read:org` scope | tell user to run `gh auth refresh -s read:org` |
| `config/project-triage-rules.yml` missing / parse error | surface yq/Python error, stop |
| `--repo X` not in org | validate in `fetch.sh` via `gh repo list`; stop with suggestion |
| `gh api graphql` fails mid-pagination | `gh` retries; on persistent failure, `fetch.sh` exits non-zero and the Triage Dir is partial — tell user to re-run |
| GitHub secondary rate limit | sleep 60s; if still limited, report partial scope |
| `sub_issues` or `blocked_by` preview 404 | silently cache empty list; skip associated rule for that issue |
| Zero issues after filter | print "No issues match" and exit 0 (not an error) |
| `python` not on PATH | fail with install hint; required for eval/report |
| `yq` not on PATH | fallback to Python YAML loader (handled by `fetch.sh`) |

---

## Notes

- **Read-only by default** — only Step 4 mutates, and only within the `FIXABLE_RULES` allow-list with per-finding confirmation.
- **Concurrency** — `fix.py` re-checks current state before each mutation (issue state for close actions, field value for project mutations) and skips with a warning if changed.
- **Rate limits** — Projects V2 GraphQL is ~10pts/mutation; the fix loop is sequential and interactive, so rate limits are unlikely during fixes. Fetch phase uses `gh --paginate` which handles backoff.
- **Config source precedence** — local clone wins over API, so running from inside a working copy of `OmniTrustILM/.github` evaluates uncommitted rule changes.
- **To re-run with same scope**, keep `$TRIAGE_DIR` stable; `fetch.sh` re-fetches everything (cheap), `eval.py` and `report.py` are pure local computation.
