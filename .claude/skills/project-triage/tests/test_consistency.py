#!/usr/bin/env python3
"""Tests for the §7.2 Epic-status + closed-but-not-done rules. Runnable under
pytest OR standalone:  python3 tests/test_consistency.py

These cover the pure logic; eval.py wires it to the live project cache (which
needs the read:project scope and so is exercised separately by a real run)."""
import os
import sys
from datetime import datetime, timezone

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from consistency import (  # noqa: E402
    epic_status_findings, expected_epic_status,
    closed_but_not_done_finding, within_window,
)

_NOW = datetime(2026, 6, 21, tzinfo=timezone.utc)
BD, NBD = True, False  # breakdown done / not done


def kid(status, state="OPEN"):
    return (status, state)


def rules_of(findings):
    return {r for _, r, _ in findings}


# ---- expected_epic_status: the RM §5.1 ladder ----

def test_expected_all_done_children():
    assert expected_epic_status([kid("Done"), kid(None, "CLOSED")], BD) == "Done"


def test_expected_closed_not_planned_counts_as_done():
    assert expected_epic_status([kid("Done"), kid("Open", "CLOSED")], BD) == "Done"


def test_expected_all_testing_or_beyond():
    assert expected_epic_status([kid("Testing"), kid("Done")], BD) == "Testing"


def test_expected_all_review_or_beyond():
    assert expected_epic_status([kid("Review"), kid("Testing")], BD) == "Review"


def test_expected_any_started_wins():
    assert expected_epic_status([kid("In Progress"), kid("Planning")], BD) == "In Progress"


def test_expected_open_when_breakdown_done():
    assert expected_epic_status([kid("Planning")], BD) == "Open"


def test_expected_analysis_while_breakdown_running():
    assert expected_epic_status([kid("Analysis"), kid("Open")], NBD) == "Analysis"


def test_expected_open_child_without_breakdown():
    assert expected_epic_status([kid("Open"), kid("Planning")], NBD) == "Open"


def test_expected_planning_default():
    assert expected_epic_status([kid("Planning"), kid("Planning")], NBD) == "Planning"


def test_expected_none_without_usable_children():
    assert expected_epic_status([kid(None)], BD) is None
    assert expected_epic_status([], BD) is None


# ---- epic_status_findings: findings + §7.3 precedence ----

def test_done_with_open_children_is_error():
    f = epic_status_findings("Done", [kid("Planning"), kid("Planning")], BD)
    assert [(lvl, r) for lvl, r, _ in f] == [("Error", "epic_done_with_open_children")]


def test_done_with_all_children_closed_no_finding():
    assert epic_status_findings("Done", [kid("Done", "CLOSED")], BD) == []


def test_matching_status_no_finding():
    assert epic_status_findings("In Progress", [kid("In Progress"), kid("Open")], BD) == []


def test_mismatch_warns():
    f = epic_status_findings("Open", [kid("In Progress")], BD)
    assert rules_of(f) == {"epic_status_mismatch"}
    assert f[0][0] == "Warning" and "In Progress" in f[0][2]


def test_no_children_no_finding():
    assert epic_status_findings("In Progress", [], BD) == []


def test_done_error_outranks_mismatch():
    # A Done Epic with an In Progress child yields only the Done error (§7.3 rule 5).
    assert rules_of(epic_status_findings("Done", [kid("In Progress")], BD)) == {"epic_done_with_open_children"}


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
