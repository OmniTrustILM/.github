#!/usr/bin/env python3
"""Offline unit tests for plan.py (no network, no gh)."""
import json
import os
import subprocess
import sys
import tempfile
import unittest

SKILL_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PLAN = os.path.join(SKILL_DIR, "plan.py")


def run_plan(*args, iterations=None):
    cmd = [sys.executable, PLAN, *args]
    tmp = None
    if iterations is not None:
        tmp = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
        json.dump(iterations, tmp)
        tmp.close()
        cmd += ["--iterations-json", tmp.name]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, check=True)
        return json.loads(out.stdout)
    finally:
        if tmp:
            os.unlink(tmp.name)


class NextReleaseTest(unittest.TestCase):
    """2.21.0 ends 2026-12-31 (Thu) -> 2.22.0 covers 27/Q1."""

    def setUp(self):
        self.plan = run_plan("--prev-version", "2.21.0",
                             "--prev-end", "2026-12-31")

    def test_version_bump(self):
        self.assertEqual(self.plan["version"], "2.22.0")

    def test_window(self):
        # Jan 1 2027 is a Friday, Mar 31 a Wednesday: no weekend adjustment.
        self.assertEqual(self.plan["start_date"], "2027-01-01")
        self.assertEqual(self.plan["end_date"], "2027-03-31")
        self.assertEqual(self.plan["target_date"], "2027-03-31")
        self.assertEqual(self.plan["quarter_label"], "27/Q1")

    def test_boundary_sprints_are_cut(self):
        sprints = self.plan["sprints"]
        first, last = sprints[0], sprints[-1]
        # Fri Jan 1 - Sun Jan 3
        self.assertEqual(first["title"], "Sprint 1 (27/Q1)")
        self.assertEqual((first["start_date"], first["duration"],
                          first["end_date"]), ("2027-01-01", 3, "2027-01-03"))
        # Mon Mar 29 - Wed Mar 31
        self.assertEqual((last["start_date"], last["duration"],
                          last["end_date"]), ("2027-03-29", 3, "2027-03-31"))
        # 3 + 12*7 + 3 = 90 days = the whole window, contiguous
        self.assertEqual(len(sprints), 14)
        self.assertTrue(all(s["duration"] == 7 for s in sprints[1:-1]))

    def test_sprint_numbering_and_no_conflicts(self):
        titles = [s["title"] for s in self.plan["sprints"]]
        self.assertEqual(titles[:3], ["Sprint 1 (27/Q1)", "Sprint 2 (27/Q1)",
                                      "Sprint 3 (27/Q1)"])
        self.assertEqual(self.plan["conflicts"], [])
        self.assertEqual(self.plan["trims"], [])


class WeekendAdjustmentTest(unittest.TestCase):
    def test_start_moved_to_monday(self):
        # Q1 2028 starts Sat Jan 1 -> Mon Jan 3; ends Fri Mar 31 (no change).
        plan = run_plan("--prev-version", "2.25.0", "--prev-end", "2027-12-31")
        self.assertEqual(plan["start_date"], "2028-01-03")
        self.assertEqual(plan["end_date"], "2028-03-31")
        self.assertEqual(plan["quarter_label"], "28/Q1")

    def test_end_moved_to_friday(self):
        # Q3 2028 ends Sat Sep 30 -> Fri Sep 29; starts Sat Jul 1 -> Mon Jul 3.
        plan = run_plan("--prev-version", "2.27.0", "--prev-end", "2028-06-30")
        self.assertEqual(plan["start_date"], "2028-07-03")
        self.assertEqual(plan["end_date"], "2028-09-29")
        # last sprint must not spill past the adjusted Friday end
        self.assertEqual(plan["sprints"][-1]["end_date"], "2028-09-29")

    def test_weekend_gap_is_not_warned(self):
        # Fri Dec 31 2027 -> Mon Jan 3 2028 skips only the weekend: normal.
        plan = run_plan("--prev-version", "2.25.0", "--prev-end", "2027-12-31")
        self.assertFalse(any("day(s) between" in w for w in plan["warnings"]))

    def test_real_gap_is_warned(self):
        # Previous release ending mid-quarter leaves a real gap to Jan 1.
        plan = run_plan("--prev-version", "2.25.0", "--prev-end", "2027-12-15")
        self.assertTrue(any("day(s) between" in w for w in plan["warnings"]))


class SprintsOnlyTest(unittest.TestCase):
    """Existing release 2.21.0: 2026-10-01 (Thu) .. 2026-12-31 (Thu)."""

    def test_window_passthrough_and_label(self):
        plan = run_plan("--version", "2.21.0",
                        "--start", "2026-10-01", "--end", "2026-12-31")
        self.assertEqual(plan["version"], "2.21.0")
        self.assertEqual(plan["quarter_label"], "26/Q4")
        first = plan["sprints"][0]
        # Thu Oct 1 - Sun Oct 4
        self.assertEqual((first["start_date"], first["duration"]),
                         ("2026-10-01", 4))

    def test_overhanging_iteration_gets_trim(self):
        # Sprint 8 (26/Q3) runs Sep 28 - Oct 4 and overhangs the Oct 1 start.
        plan = run_plan("--version", "2.21.0",
                        "--start", "2026-10-01", "--end", "2026-12-31",
                        iterations=[{"title": "Sprint 8 (26/Q3)",
                                     "startDate": "2026-09-28", "duration": 7}])
        self.assertEqual(len(plan["trims"]), 1)
        trim = plan["trims"][0]
        self.assertEqual(trim["new_duration"], 3)
        self.assertEqual(trim["new_end"], "2026-09-30")
        self.assertEqual(plan["conflicts"], [])

    def test_existing_matching_sprint_marked(self):
        plan = run_plan("--version", "2.21.0",
                        "--start", "2026-10-01", "--end", "2026-12-31",
                        iterations=[{"title": "Sprint 1 (26/Q4)",
                                     "startDate": "2026-10-01", "duration": 4}])
        self.assertTrue(plan["sprints"][0]["exists"])
        self.assertEqual(plan["trims"], [])
        self.assertEqual(plan["conflicts"], [])

    def test_unexpected_inside_iteration_is_conflict(self):
        plan = run_plan("--version", "2.21.0",
                        "--start", "2026-10-01", "--end", "2026-12-31",
                        iterations=[{"title": "Sprint 99",
                                     "startDate": "2026-11-02", "duration": 7}])
        self.assertEqual(len(plan["conflicts"]), 1)

    def test_iteration_outside_window_ignored(self):
        plan = run_plan("--version", "2.21.0",
                        "--start", "2026-10-01", "--end", "2026-12-31",
                        iterations=[{"title": "Sprint 5 (26/Q3)",
                                     "startDate": "2026-09-07", "duration": 7}])
        self.assertEqual(plan["trims"], [])
        self.assertEqual(plan["conflicts"], [])


class VersionBumpTest(unittest.TestCase):
    def test_explicit_version_wins(self):
        plan = run_plan("--prev-version", "2.21.0",
                        "--prev-end", "2026-12-31", "--version", "2.30.0")
        self.assertEqual(plan["version"], "2.30.0")

    def test_minor_bump_keeps_major(self):
        plan = run_plan("--prev-version", "2.9.0", "--prev-end", "2026-12-31")
        self.assertEqual(plan["version"], "2.10.0")


if __name__ == "__main__":
    unittest.main(verbosity=2)
