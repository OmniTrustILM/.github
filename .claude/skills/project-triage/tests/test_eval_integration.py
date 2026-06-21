#!/usr/bin/env python3
"""End-to-end integration test for eval.py: builds a synthetic TRIAGE_DIR,
runs eval.py as a subprocess, and asserts the findings it writes. This exercises
the parts the unit tests can't — the sub-issue lookup, the Epic-status wiring,
and the windowed closed_but_not_done loop — without needing the read:project
scope (no live GitHub calls; all inputs are local fixtures).

Runnable under pytest OR standalone:  python3 tests/test_eval_integration.py
"""
import json
import os
import subprocess
import sys
import tempfile
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL_DIR = os.path.dirname(HERE)
REPO_ROOT = os.path.abspath(os.path.join(SKILL_DIR, "..", "..", ".."))
CONFIG = os.path.join(REPO_ROOT, "config", "project-triage-rules.yml")

NOW = datetime.now(timezone.utc)
RECENT = (NOW - timedelta(days=2)).strftime("%Y-%m-%dT%H:%M:%SZ")
OLD = (NOW - timedelta(days=400)).strftime("%Y-%m-%dT%H:%M:%SZ")


def _item(number, repo, itype, status, *, state="OPEN", state_reason=None, version=None,
          parent=None, subcount=0, labels=None, closed_at=None, body="", updated=None):
    updated = updated or RECENT
    fvs = [{"__typename": "ProjectV2ItemFieldSingleSelectValue", "name": status,
            "field": {"name": "Status"}, "optionId": "opt", "updatedAt": updated}]
    if version:
        fvs.append({"__typename": "ProjectV2ItemFieldSingleSelectValue", "name": version,
                    "field": {"name": "Version"}})
    content = {
        "number": number, "title": f"Issue {number}",
        "url": f"https://github.com/OmniTrustILM/{repo}/issues/{number}",
        "body": body, "createdAt": "2026-01-01T00:00:00Z", "updatedAt": updated,
        "closedAt": closed_at, "state": state, "stateReason": state_reason,
        "repository": {"name": repo}, "issueType": {"name": itype}, "author": {"login": "alice"},
        "assignees": {"nodes": []}, "labels": {"nodes": [{"name": l} for l in (labels or [])]},
        "parent": parent, "subIssues": {"totalCount": subcount}, "timelineItems": {"nodes": []},
    }
    return {"id": f"PVTI_{number}", "content": content, "fieldValues": {"nodes": fvs}}


def _run_eval():
    import yaml
    d = tempfile.mkdtemp(prefix="triage-it-")
    epic_body = "## User Story\nAs a user...\n## Use Cases\nUC1\n## Acceptance Criteria\n- [ ] done\n"
    epic = _item(100, "core", "Epic", "Done", subcount=1, version="2.18.0", body=epic_body)
    child = _item(101, "core", "Feature", "In Progress", version="2.18.0",
                  parent={"number": 100, "url": "https://github.com/OmniTrustILM/core/issues/100",
                          "repository": {"name": "core"}})
    closed_recent = _item(200, "core", "Bug", "In Progress", state="CLOSED",
                          state_reason="COMPLETED", closed_at=RECENT, body="x")
    closed_old = _item(201, "core", "Bug", "In Progress", state="CLOSED",
                       state_reason="COMPLETED", closed_at=OLD, body="x")

    def dump(name, obj):
        with open(os.path.join(d, name), "w", encoding="utf-8") as fh:
            json.dump(obj, fh)

    dump("items-flat.json", [epic, child])
    dump("filtered.json", [epic, child])
    dump("filtered-closed.json", [closed_recent, closed_old])
    dump("rules.json", yaml.safe_load(open(CONFIG, encoding="utf-8")))
    dump("subs-core-100.json", [{
        "number": 101, "state": "open",
        "repository_url": "https://api.github.com/repos/OmniTrustILM/core", "labels": []}])
    with open(os.path.join(d, "members.txt"), "w", encoding="utf-8") as fh:
        fh.write("alice\n")

    env = {**os.environ, "TRIAGE_DIR": d}
    r = subprocess.run([sys.executable, os.path.join(SKILL_DIR, "eval.py")],
                       env=env, capture_output=True, text=True)
    assert r.returncode == 0, f"eval.py failed: {r.stderr}"
    findings = json.load(open(os.path.join(d, "findings.json"), encoding="utf-8"))
    return findings


def test_eval_emits_epic_done_with_open_children():
    findings = _run_eval()
    assert any(f["rule"] == "epic_done_with_open_children" and f["number"] == 100 for f in findings)


def test_eval_emits_recent_closed_but_not_done_only():
    findings = _run_eval()
    closed = [f for f in findings if f["rule"] == "closed_but_not_done"]
    nums = {f["number"] for f in closed}
    assert 200 in nums, "recent closed-but-not-done should be flagged"
    assert 201 not in nums, "issue closed 400d ago must be outside the window"


if __name__ == "__main__":
    import traceback
    failed = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try:
                fn()
                print(f"ok   {name}")
            except Exception:
                failed += 1
                print(f"FAIL {name}")
                traceback.print_exc()
    sys.exit(1 if failed else 0)
