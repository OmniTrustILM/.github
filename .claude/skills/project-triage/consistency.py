"""Pure §7.2 consistency checks for project-triage that need more than a single
field lookup: the Epic-status rules, closed-but-not-done, and the tree walks
behind version_mismatch and epic_without_qa_sub_issue.

These are kept side-effect-free and importable so they can be unit-tested
without a live project cache (eval.py itself reads cache files at import). Rule
names match epic-breakdown/reconcile.py so the two skills share one vocabulary.

The Epic's expected Status is derived from its children per Release
Management §5.1 (the same ladder as PM_reporting's health check):
Done = all children have Status Done — closing an issue only ends
development and hands it to QA (the automation moves it to Testing), so a
closed child ranks by its Status field, floored at Testing; only children
cancelled as not planned / duplicate (or closed with no project Status)
count as Done outright. Testing / Review = all children at that stage or
beyond; In Progress = any child started; otherwise Open once the breakdown
is complete (Complexity, Estimate, Start/End Date set on the Epic — §3.2),
Analysis while a child is still being scoped, else Planning.

§7.3 precedence note: epic_done_with_open_children is an Error and outranks
the epic_status_mismatch Warning — when it fires, the mismatch is not
emitted for the same Epic; eval.py's existing has_error suppression handles
any co-occurring warnings on the same issue.
"""

from datetime import datetime

STATUS_ORDER = ("Planning", "Analysis", "Open", "In Progress", "Review", "Testing", "Done")
_RANK = {s: i for i, s in enumerate(STATUS_ORDER)}


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


def _child_rank(status, state, state_reason):
    """Ladder rank of one child, or None when nothing is derivable. Closing
    an issue only ends development and hands it to QA (the automation moves
    it to Testing), so a CLOSED child ranks by its Status field, floored at
    Testing — Done comes only from QA setting Status Done. Children
    cancelled as not planned / duplicate (and closed ones with no project
    Status) count as Done outright: cancelled work must not hold the Epic
    open."""
    rank = _RANK.get(status)
    if (state or "").upper() != "CLOSED":
        return rank
    if (state_reason or "").upper() in ("NOT_PLANNED", "DUPLICATE") or rank is None:
        return _RANK["Done"]
    return max(rank, _RANK["Testing"])


def expected_epic_status(children, breakdown_done):
    """The Status an Epic should have, derived from its children — the
    Release Management §5.1 ladder (most advanced rule wins).

    children       — list of (project_status, github_state, state_reason)
                     triples, one per child, ranked by _child_rank above.
    breakdown_done — True when Complexity, Estimate, Start Date and End Date
                     are all set on the Epic (§3.2: the fields the breakdown
                     must produce before the Epic may move to Open).

    Returns None when nothing can be derived (no child has a usable state).
    """
    ranked = [r for c in children if (r := _child_rank(*c)) is not None]
    if not ranked:
        return None
    if min(ranked) >= _RANK["Done"]:
        return "Done"
    if min(ranked) >= _RANK["Testing"]:
        return "Testing"
    if min(ranked) >= _RANK["Review"]:
        return "Review"
    if max(ranked) >= _RANK["In Progress"]:
        return "In Progress"
    # nothing started yet: breakdown completion decides Analysis vs. Open
    if breakdown_done:
        return "Open"
    if _RANK["Analysis"] in ranked:
        return "Analysis"
    if _RANK["Open"] in ranked:
        return "Open"
    return "Planning"


def epic_status_findings(status, children, breakdown_done):
    """Return a list of (level, rule, msg) for the §7.2 Epic-status rules.

    status         — the Epic's project Status field value.
    children       — list of (project_status, github_state, state_reason)
                     triples per child.
    breakdown_done — see expected_epic_status().
    """
    open_count = sum(1 for c in children if (c[1] or "").upper() == "OPEN")
    if status == "Done" and open_count > 0:
        # §7.3 rule 5: this Error outranks (and replaces) the mismatch Warning
        return [("Error", "epic_done_with_open_children",
                 f"Epic Status=Done but {open_count} child issue(s) still open")]
    expected = expected_epic_status(children, breakdown_done)
    if status and expected and status != expected:
        return [("Warning", "epic_status_mismatch",
                 f"Epic Status is `{status}` but its children imply `{expected}` (RM §5.1)")]
    return []


def closed_but_not_done_finding(state, state_reason, status):
    """Return (level, rule, msg) or None.

    Fires when an issue is CLOSED as COMPLETED but its Status is neither
    Testing nor Done. Closing hands the issue to QA and the automation moves
    it to Testing, so closed-with-Testing is the normal QA queue and Done is
    the QA-approved end state — anything lower means the automation was
    bypassed. Closes marked NOT_PLANNED / DUPLICATE are legitimate terminal
    states and are excluded (§7.3 rule 2)."""
    if (state or "").upper() == "CLOSED" \
            and (state_reason or "").upper() == "COMPLETED" \
            and status not in ("Testing", "Done"):
        return ("Warning", "closed_but_not_done",
                "Closed as completed but Status never reached Testing/Done")
    return None


def version_reference(key, parent_of, type_of):
    """The item whose Version `key` must carry, or None without a parent.

    The parent's Version wins, transitively (the same rule as PM_reporting's
    health check): every issue of an Epic's tree, at any depth, must carry
    the Epic's Version — a sub-issue is compared with the Epic, never with a
    container issue that may itself be off. Epics (and Releases) compare
    with their immediate parent; an issue with no Epic above it in the
    project falls back to its immediate parent.

    key        — (repo, number) of the evaluated item.
    parent_of  — {key: parent key} for the project's items.
    type_of    — {key: issue type name} for the project's items.
    """
    parent = parent_of.get(key)
    if parent is None or type_of.get(key) in ("Epic", "Release"):
        return parent
    seen, cur = {key}, parent
    while cur is not None and cur not in seen:
        if type_of.get(cur) == "Epic":
            return cur
        seen.add(cur)
        cur = parent_of.get(cur)
    return parent


def tree_has_qa(root, children_of, labels_of, type_of):
    """True when any non-Bug issue below `root`, at any depth, carries the
    `qa` label — QA tasks count wherever they sit in the Epic's tree (the
    layout is not a rule; same as PM_reporting's test coverage)."""
    stack, seen = list(children_of.get(root, ())), {root}
    while stack:
        cur = stack.pop()
        if cur in seen:
            continue
        seen.add(cur)
        if type_of.get(cur) != "Bug" and "qa" in labels_of.get(cur, ()):
            return True
        stack.extend(children_of.get(cur, ()))
    return False
