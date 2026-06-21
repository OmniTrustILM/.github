#!/usr/bin/env python3
"""Tests for reconcile.diff / normalize. Runnable under pytest OR standalone:
    python3 tests/test_reconcile.py
Rule names must match what project-triage's eval.py emits.
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from reconcile import diff, normalize  # noqa: E402


def _epic(**kw):
    base = {"state": "OPEN", "status": "Planning", "version": None,
            "children_status": [], "subIssues": []}
    base.update(kw)
    return base


def test_empty_epic_is_error():
    f = next(x for x in diff(_epic(subIssues=[])) if x["rule"] == "empty_epic_no_sub_issues")
    assert f["level"] == "error"


def test_missing_qa_child_flags_when_no_qa_label():
    epic = _epic(subIssues=[{"number": 2, "labels": ["documentation"], "state": "OPEN"}])
    assert any(f["rule"] == "epic_without_qa_sub_issue" for f in diff(epic))


def test_missing_docs_child_flags():
    epic = _epic(subIssues=[{"number": 2, "labels": ["qa"], "state": "OPEN"}])
    assert any(f["rule"] == "epic_without_docs_sub_issue" for f in diff(epic))


def test_no_missing_child_warnings_when_both_present():
    epic = _epic(subIssues=[{"number": 2, "labels": ["qa"], "state": "OPEN"},
                            {"number": 3, "labels": ["documentation"], "state": "OPEN"}])
    out = diff(epic)
    assert not any(f["rule"] == "epic_without_qa_sub_issue" for f in out)
    assert not any(f["rule"] == "epic_without_docs_sub_issue" for f in out)


def test_done_with_open_children_is_error():
    epic = _epic(status="Done",
                 subIssues=[{"number": 2, "state": "OPEN", "labels": ["qa"]},
                            {"number": 3, "state": "OPEN", "labels": ["documentation"]}])
    f = next(x for x in diff(epic) if x["rule"] == "epic_done_with_open_children")
    assert f["level"] == "error"


def test_done_open_children_suppresses_status_and_orphan_warnings():
    # §7.3: the error outranks Epic-level warnings about the same situation.
    epic = _epic(status="Done", state="CLOSED", children_status=["Planning"],
                 subIssues=[{"number": 2, "state": "OPEN", "labels": ["qa", "documentation"]}])
    rules = {f["rule"] for f in diff(epic)}
    assert "epic_done_with_open_children" in rules
    assert "epic_status_ahead_of_children" not in rules
    assert "orphaned_sub_issues" not in rules


def test_status_lags_children_warns():
    epic = _epic(status="Open", children_status=["In Progress"],
                 subIssues=[{"number": 2, "labels": ["qa"]}, {"number": 3, "labels": ["documentation"]}])
    assert any(f["rule"] == "epic_status_lags_children" for f in diff(epic))


def test_orphaned_when_epic_closed_child_open():
    epic = _epic(state="CLOSED", status="Open",
                 subIssues=[{"number": 2, "state": "OPEN", "labels": ["qa", "documentation"]}])
    assert any(f["rule"] == "orphaned_sub_issues" for f in diff(epic))


def test_version_mismatch_is_error():
    epic = _epic(status="Open", version="2.18.0",
                 subIssues=[{"number": 2, "labels": ["qa"], "version": "2.17.0", "state": "OPEN"},
                            {"number": 3, "labels": ["documentation"], "version": "2.18.0", "state": "OPEN"}])
    fs = [f for f in diff(epic) if f["rule"] == "version_mismatch"]
    assert len(fs) == 1 and fs[0]["level"] == "error"


def test_missing_workstream_info_when_some_annotated():
    epic = _epic(subIssues=[{"number": 2, "labels": ["qa"], "work_stream": "Testing"},
                            {"number": 3, "labels": ["documentation"], "work_stream": "Documentation"}])
    f = next(x for x in diff(epic) if x["rule"] == "missing_workstream")
    assert "API" in f["detail"] and f["level"] == "info"


def test_normalize_extracts_epic_and_child_project_fields():
    def ss(name, value):  # single-select field-value node
        return {"__typename": "ProjectV2ItemFieldSingleSelectValue", "name": value, "field": {"name": name}}
    raw = {"data": {"repository": {"issue": {
        "number": 1, "state": "OPEN",
        "projectItems": {"nodes": [{"project": {"number": 5}, "fieldValues": {"nodes": [
            ss("Status", "Planning"), ss("Version", "2.18.0")]}}]},
        "subIssues": {"nodes": [{
            "number": 2, "state": "OPEN", "issueType": {"name": "Task"},
            "labels": {"nodes": [{"name": "qa"}]},
            "projectItems": {"nodes": [{"project": {"number": 5}, "fieldValues": {"nodes": [
                ss("Status", "In Progress"), ss("Version", "2.17.0")]}}]}}]},
        "subIssuesSummary": {"total": 1, "completed": 0}}}}}
    n = normalize(raw)
    assert n["status"] == "Planning" and n["version"] == "2.18.0"
    assert n["children_status"] == ["In Progress"]
    assert n["subIssues"][0]["labels"] == ["qa"]
    assert n["subIssues"][0]["version"] == "2.17.0"
    # And the normalised dict drives diff(): version mismatch should surface.
    assert any(f["rule"] == "version_mismatch" for f in diff(n))


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
