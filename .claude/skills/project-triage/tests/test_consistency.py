#!/usr/bin/env python3
"""Tests for the §7.2 Epic-status + closed-but-not-done rules. Runnable under
pytest OR standalone:  python3 tests/test_consistency.py

These cover the pure logic; eval.py wires it to the live project cache (which
needs the read:project scope and so is exercised separately by a real run)."""
import os
import sys
from datetime import datetime, timezone

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from consistency import epic_status_findings, closed_but_not_done_finding, within_window  # noqa: E402

_NOW = datetime(2026, 6, 21, tzinfo=timezone.utc)


def rules_of(findings):
    return {r for _, r, _ in findings}


def test_done_with_open_children_is_error():
    f = epic_status_findings("Done", ["Planning"], 2)
    assert [(lvl, r) for lvl, r, _ in f] == [("Error", "epic_done_with_open_children")]


def test_done_with_no_open_children_no_finding():
    assert epic_status_findings("Done", [], 0) == []


def test_lags_children_warns():
    assert "epic_status_lags_children" in rules_of(epic_status_findings("Open", ["In Progress"], 1))


def test_open_no_advanced_child_no_finding():
    assert epic_status_findings("Open", ["Open", "Planning"], 1) == []


def test_ahead_of_children_warns():
    assert "epic_status_ahead_of_children" in rules_of(epic_status_findings("In Progress", ["Open", "Planning"], 2))


def test_in_progress_with_advanced_child_no_ahead():
    assert epic_status_findings("In Progress", ["Review"], 1) == []


def test_in_progress_no_children_no_finding():
    assert epic_status_findings("In Progress", [], 0) == []


def test_status_rules_mutually_exclusive():
    # A Done Epic with an In Progress child yields only the Done error.
    assert rules_of(epic_status_findings("Done", ["In Progress"], 1)) == {"epic_done_with_open_children"}


def test_closed_but_not_done_fires():
    r = closed_but_not_done_finding("CLOSED", "COMPLETED", "In Progress")
    assert r and r[1] == "closed_but_not_done" and r[0] == "Warning"


def test_closed_and_done_no_finding():
    assert closed_but_not_done_finding("CLOSED", "COMPLETED", "Done") is None


def test_closed_not_planned_excluded():
    assert closed_but_not_done_finding("CLOSED", "NOT_PLANNED", "Open") is None


def test_open_issue_no_closed_finding():
    assert closed_but_not_done_finding("OPEN", None, "Open") is None


def test_within_window_recent_true():
    assert within_window("2026-06-10T00:00:00Z", _NOW, 30) is True


def test_within_window_old_false():
    assert within_window("2026-01-01T00:00:00Z", _NOW, 30) is False


def test_within_window_missing_false():
    assert within_window(None, _NOW, 30) is False


def test_within_window_unparseable_false():
    assert within_window("not-a-date", _NOW, 30) is False


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
