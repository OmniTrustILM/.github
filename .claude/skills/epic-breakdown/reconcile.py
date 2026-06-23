#!/usr/bin/env python3
"""Expected-vs-actual diff for an Epic — the engine behind epic-breakdown's
reconcile mode.

Pure logic: the caller (SKILL.md) fetches the EpicState GraphQL JSON, passes it
to `normalize()` to get the flat shape below, then to `diff()` for findings.

Rule names match what project-triage's eval.py emits, so the two skills speak the
same vocabulary (this skill does not import triage's code — only reuses the
names and reads the shared `config/project-triage-rules.yml` for parameters).

Scope: reconcile covers the *Epic-and-its-children* consistency rules. Board-wide
hygiene — staleness, `blocked_but_in_progress`, `done_but_open_state`,
`reopened_without_reason`, `closed_but_not_done` — stays in /project-triage and is
intentionally NOT duplicated here.

Each finding: {"rule", "level" (error|warning|info), "detail"}.
"""
from __future__ import annotations

import json
import sys

# §2.6 work streams a complete Epic decomposition should cover.
WORK_STREAMS = ["API", "Backend", "Frontend", "Access Control",
                "Testing", "Documentation", "Deployment"]
ADVANCED_STATUSES = {"In Progress", "Review", "Testing"}
EARLY_STATUSES = {"Open", "Planning"}
PROJECT_NUMBER = 5


def _labels(issue):
    """Labels as a set of names, tolerant of ['qa'] or [{'name': 'qa'}]."""
    out = set()
    for lab in issue.get("labels", []) or []:
        out.add(lab["name"] if isinstance(lab, dict) else lab)
    return out


def _project_field(item_nodes, field_name, project_number=PROJECT_NUMBER):
    """Read a single-select/number value for `field_name` from a node's
    Project #5 item field-value list."""
    for pi in item_nodes or []:
        if (pi.get("project") or {}).get("number") == project_number:
            for fv in pi.get("fieldValues", {}).get("nodes", []) or []:
                f = fv.get("field") or {}
                if f.get("name") == field_name:
                    return fv.get("name", fv.get("number"))
    return None


def normalize(epic_state):
    """Flatten raw EpicState GraphQL JSON into the dict `diff()` expects:

        {state, status, version, children_status:[...],
         subIssues:[{number, state, labels:[name], version, status, work_stream?}]}

    `work_stream` is present only if the caller (the LLM) annotated each child.
    """
    issue = epic_state["data"]["repository"]["issue"]
    epic_items = issue.get("projectItems", {}).get("nodes", [])

    subs = []
    children_status = []
    for s in issue.get("subIssues", {}).get("nodes", []) or []:
        s_items = s.get("projectItems", {}).get("nodes", [])
        st = _project_field(s_items, "Status")
        if st:
            children_status.append(st)
        subs.append({
            "number": s.get("number"),
            "state": s.get("state"),
            "labels": [n["name"] for n in (s.get("labels", {}).get("nodes", []) or [])],
            "issueType": (s.get("issueType") or {}).get("name"),
            "status": st,
            "version": _project_field(s_items, "Version"),
        })

    summary = issue.get("subIssuesSummary") or {}
    return {
        "number": issue.get("number"),
        "state": issue.get("state"),
        "status": _project_field(epic_items, "Status"),
        "version": _project_field(epic_items, "Version"),
        "children_status": children_status,
        "subIssues": subs,
        "summary": {"total": summary.get("total"), "completed": summary.get("completed")},
    }


def diff(epic, rules=None):
    """Compute findings for a normalised Epic dict. `rules` (the parsed
    project-triage-rules.yml) is accepted for parity but the rules below are
    structural §7.2/§3.2 checks, not threshold-parameterised."""
    findings = []
    subs = epic.get("subIssues", []) or []
    status = epic.get("status")
    child_statuses = epic.get("children_status", []) or []
    open_children = [s for s in subs if s.get("state") == "OPEN"]

    # §3.2 — Empty Epic (no sub-issues) is an Error before it can leave Planning.
    if not subs:
        findings.append({"rule": "empty_epic_no_sub_issues", "level": "error",
                         "detail": "Epic has no sub-issues (§3.2 blocks moving it to Open)."})

    # §7.2 — Epic without a Task+qa sub-issue (testing may be forgotten).
    if subs and not any("qa" in _labels(s) for s in subs):
        findings.append({"rule": "epic_without_qa_sub_issue", "level": "warning",
                         "detail": "Epic has no sub-issue with the `qa` label; testing may be forgotten."})
    # Completeness extension (paired with the QA rule in §2.6) — not in the triage YAML.
    if subs and not any("documentation" in _labels(s) for s in subs):
        findings.append({"rule": "epic_without_docs_sub_issue", "level": "warning",
                         "detail": "Epic has no sub-issue with the `documentation` label."})

    # §7.2 — Epic Done with open children (Error). Per §7.3 it outranks the
    # Epic-status warnings and the orphaned warning, which are filtered below.
    done_with_open = status == "Done" and open_children
    if done_with_open:
        findings.append({"rule": "epic_done_with_open_children", "level": "error",
                         "detail": f"Epic Status=Done but {len(open_children)} child issue(s) still open."})
    # §7.2 — Epic status lags children.
    if status == "Open" and any(cs in ADVANCED_STATUSES for cs in child_statuses):
        findings.append({"rule": "epic_status_lags_children", "level": "warning",
                         "detail": "A child is more advanced than the Epic (Open); move the Epic to In Progress."})
    # §7.2 — Epic status ahead of children.
    if status == "In Progress" and child_statuses and all(cs in EARLY_STATUSES for cs in child_statuses):
        findings.append({"rule": "epic_status_ahead_of_children", "level": "warning",
                         "detail": "Epic is In Progress but all children are still Open/Planning."})

    # §7.2 — Orphaned sub-issue (Epic closed, child open).
    if epic.get("state") == "CLOSED" and open_children:
        findings.append({"rule": "orphaned_sub_issues", "level": "warning",
                         "detail": f"Epic is closed but {len(open_children)} child issue(s) are still open."})

    # §7.2 — Version mismatch (child Version != Epic Version). Error.
    epic_v = epic.get("version")
    if epic_v:
        for s in subs:
            if s.get("version") and s["version"] != epic_v:
                findings.append({"rule": "version_mismatch", "level": "error",
                                 "detail": f"Child #{s.get('number')} Version {s['version']} != Epic Version {epic_v}."})

    # Completeness — work streams with no child (info; the LLM judges relevance).
    covered = {s.get("work_stream") for s in subs if s.get("work_stream")}
    if covered:
        missing = [w for w in WORK_STREAMS if w not in covered]
        if missing:
            findings.append({"rule": "missing_workstream", "level": "info",
                             "detail": "No child issue for work stream(s): " + ", ".join(missing)})

    # §7.3 rule 1/5 — the Done-with-open-children Error suppresses the Epic-level
    # warnings that describe the same situation, to avoid noise.
    if done_with_open:
        suppressed = {"epic_status_ahead_of_children", "epic_status_lags_children", "orphaned_sub_issues"}
        findings = [f for f in findings if f["rule"] not in suppressed]
    return findings


def load_epic_state(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def load_rules(path):
    import yaml
    with open(path, encoding="utf-8") as fh:
        return yaml.safe_load(fh)


def main(argv):
    if len(argv) < 2:
        print("usage: reconcile.py <epic-state.json|normalized.json> [rules.yml]", file=sys.stderr)
        return 2
    raw = load_epic_state(argv[1])
    epic = normalize(raw) if "data" in raw else raw  # accept raw GraphQL or pre-normalised
    rules = load_rules(argv[2]) if len(argv) > 2 else None
    print(json.dumps(diff(epic, rules), indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
