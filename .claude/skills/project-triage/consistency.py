"""Pure §7.2 consistency checks for project-triage that need more than a single
field lookup: the Epic-status rules and closed-but-not-done.

These are kept side-effect-free and importable so they can be unit-tested
without a live project cache (eval.py itself reads cache files at import). Rule
names match epic-breakdown/reconcile.py so the two skills share one vocabulary.

§7.3 precedence note: epic_done_with_open_children is an Error and the three
Epic-status rules are mutually exclusive by the Epic's Status (Done / Open /
In Progress), so at most one fires per Epic; eval.py's existing has_error
suppression handles any co-occurring warnings on the same issue.
"""

from datetime import datetime

ADVANCED_STATUSES = {"In Progress", "Review", "Testing"}
EARLY_STATUSES = {"Open", "Planning"}


def within_window(closed_at_iso, now, days):
    """True if `closed_at_iso` falls within `days` before `now`. A missing or
    unparseable date returns False so closed_but_not_done only flags recent
    closes (avoids flagging large numbers of legacy closed issues)."""
    if not closed_at_iso:
        return False
    try:
        dt = datetime.fromisoformat(closed_at_iso.replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        return False
    return 0 <= (now - dt).days <= days


def epic_status_findings(status, child_statuses, open_children_count):
    """Return a list of (level, rule, msg) for the §7.2 Epic-status rules.

    status               — the Epic's project Status field value.
    child_statuses       — list of children's project Status values (those known).
    open_children_count  — number of children in GitHub OPEN state.
    """
    out = []
    if status == "Done" and open_children_count > 0:
        out.append(("Error", "epic_done_with_open_children",
                    f"Epic Status=Done but {open_children_count} child issue(s) still open"))
    elif status == "Open" and any(cs in ADVANCED_STATUSES for cs in child_statuses):
        out.append(("Warning", "epic_status_lags_children",
                    "Epic in Open but a child is In Progress/Review/Testing"))
    elif status == "In Progress" and child_statuses and all(cs in EARLY_STATUSES for cs in child_statuses):
        out.append(("Warning", "epic_status_ahead_of_children",
                    "Epic In Progress but all children are still Open/Planning"))
    return out


def closed_but_not_done_finding(state, state_reason, status):
    """Return (level, rule, msg) or None.

    Fires when an issue is CLOSED as COMPLETED but its Status never reached Done.
    Closes marked NOT_PLANNED / DUPLICATE are legitimate terminal states and are
    excluded (§7.3 rule 2)."""
    if (state or "").upper() == "CLOSED" \
            and (state_reason or "").upper() == "COMPLETED" \
            and status != "Done":
        return ("Warning", "closed_but_not_done",
                "Closed as completed but Status never reached Done")
    return None
