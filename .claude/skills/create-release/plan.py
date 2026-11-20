#!/usr/bin/env python3
"""Compute a release plan: version, quarter window, sprint schedule, trims.

Pure date/semver math — no network, no gh. Called by plan.sh with live data,
and by the offline test suite with fixtures.

Conventions (agreed with PM, 2026-09-08):
- A release covers one calendar quarter. Start = first day of the quarter,
  moved to the following Monday if it falls on a weekend. End = last day of
  the quarter, moved to the preceding Friday if it falls on a weekend.
- Sprints are weekly Monday–Sunday, numbered from 1 within the release,
  titled "Sprint <n> (<yy>/Q<q>)" after the release's calendar quarter.
- Boundary sprints are cut to the release window: the first sprint runs from
  the release start to that week's Sunday; the last sprint ends on the
  release end date. An existing iteration that overhangs the release start
  gets a trim proposal instead of being overlapped.
- Version = previous 2.x release with the minor bumped (2.21.0 -> 2.22.0),
  unless --version is given. Target Date in the release body = End Date.
"""
import argparse
import datetime as dt
import json
import re
import sys

DATE_FMT = "%Y-%m-%d"


def parse_date(s):
    return dt.datetime.strptime(s, DATE_FMT).date()


def fmt(d):
    return d.strftime(DATE_FMT)


def next_version(prev):
    m = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", prev)
    if not m:
        raise ValueError(f"previous version {prev!r} is not semver")
    major, minor, _ = (int(g) for g in m.groups())
    return f"{major}.{minor + 1}.0"


def quarter_of(d):
    return (d.month - 1) // 3 + 1


def quarter_window(year, quarter):
    """Raw first/last day of a calendar quarter, before weekend adjustment."""
    first = dt.date(year, 3 * (quarter - 1) + 1, 1)
    if quarter == 4:
        last = dt.date(year, 12, 31)
    else:
        last = dt.date(year, 3 * quarter + 1, 1) - dt.timedelta(days=1)
    return first, last


def adjust_start(d):
    if d.weekday() == 5:  # Saturday
        return d + dt.timedelta(days=2)
    if d.weekday() == 6:  # Sunday
        return d + dt.timedelta(days=1)
    return d


def adjust_end(d):
    if d.weekday() == 5:  # Saturday
        return d - dt.timedelta(days=1)
    if d.weekday() == 6:  # Sunday
        return d - dt.timedelta(days=2)
    return d


def quarter_label(year, quarter):
    return f"{year % 100}/Q{quarter}"


def build_sprints(start, end, label):
    sprints = []
    n = 1
    cur = start
    while cur <= end:
        week_sunday = cur + dt.timedelta(days=6 - cur.weekday())
        sprint_end = min(week_sunday, end)
        sprints.append({
            "title": f"Sprint {n} ({label})",
            "start_date": fmt(cur),
            "duration": (sprint_end - cur).days + 1,
            "end_date": fmt(sprint_end),
            "exists": False,
        })
        n += 1
        cur = sprint_end + dt.timedelta(days=1)
    return sprints


def reconcile(sprints, live_iterations, start, end):
    """Mark planned sprints that already exist; propose trims for overhangs."""
    trims, conflicts = [], []
    planned = {(s["title"], s["start_date"], s["duration"]) for s in sprints}
    for it in live_iterations:
        it_start = parse_date(it["startDate"])
        it_dur = int(it["duration"])
        it_end = it_start + dt.timedelta(days=it_dur - 1)
        if it_end < start or it_start > end:
            continue
        key = (it["title"], it["startDate"], it_dur)
        if key in planned:
            for s in sprints:
                if (s["title"], s["start_date"], s["duration"]) == key:
                    s["exists"] = True
            continue
        if it_start < start:
            new_dur = (start - it_start).days
            trims.append({
                "title": it["title"],
                "start_date": it["startDate"],
                "old_duration": it_dur,
                "old_end": fmt(it_end),
                "new_duration": new_dur,
                "new_end": fmt(start - dt.timedelta(days=1)),
            })
        else:
            conflicts.append(
                f"existing iteration '{it['title']}' ({it['startDate']}, "
                f"{it_dur}d) lies inside the release window but does not "
                f"match the plan"
            )
    return trims, conflicts


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--prev-version", help="latest existing 2.x release version")
    p.add_argument("--prev-end", help="End Date of that release (YYYY-MM-DD)")
    p.add_argument("--version", help="explicit version for the new release")
    p.add_argument("--start", help="explicit window start (sprints-only mode)")
    p.add_argument("--end", help="explicit window end (sprints-only mode)")
    p.add_argument("--iterations-json", help="file with live iterations "
                   '[{"title","startDate","duration"}, ...]')
    args = p.parse_args(argv)

    warnings = []

    if args.start and args.end:
        # sprints-only: the release (and its window) already exists
        start, end = parse_date(args.start), parse_date(args.end)
        raw_first, _ = quarter_window(start.year, quarter_of(start))
        version = args.version or ""
        label = quarter_label(start.year, quarter_of(start))
        if adjust_start(raw_first) != start:
            warnings.append(
                f"release start {fmt(start)} is not the adjusted quarter "
                f"start {fmt(adjust_start(raw_first))}; sprint numbering "
                f"still starts at 1"
            )
    else:
        if not (args.prev_version and args.prev_end):
            p.error("either --start/--end or --prev-version/--prev-end required")
        prev_end = parse_date(args.prev_end)
        year, q = prev_end.year, quarter_of(prev_end)
        year, q = (year + 1, 1) if q == 4 else (year, q + 1)
        raw_first, raw_last = quarter_window(year, q)
        start, end = adjust_start(raw_first), adjust_end(raw_last)
        version = args.version or next_version(args.prev_version)
        label = quarter_label(year, q)
        gap = (start - prev_end).days
        if gap < 1:
            warnings.append(
                f"computed start {fmt(start)} does not follow the previous "
                f"release end {args.prev_end}"
            )
        elif gap > 3:
            warnings.append(
                f"{gap - 1} day(s) between previous release end "
                f"{args.prev_end} and new start {fmt(start)}"
            )

    sprints = build_sprints(start, end, label)

    live = []
    if args.iterations_json:
        with open(args.iterations_json, encoding="utf-8") as f:
            live = json.load(f)
    trims, conflicts = reconcile(sprints, live, start, end)

    json.dump({
        "version": version,
        "quarter_label": label,
        "start_date": fmt(start),
        "end_date": fmt(end),
        "target_date": fmt(end),
        "sprints": sprints,
        "trims": trims,
        "conflicts": conflicts,
        "warnings": warnings,
    }, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
