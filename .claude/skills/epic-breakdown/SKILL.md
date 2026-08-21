---
name: epic-breakdown
version: 1.0.0
description: >
  Use when turning a requirement or user story into a planned OmniTrustILM
  Epic with sub-issues, enriching an existing Epic, or syncing an Epic with
  its current progress. Acts as the ILM architect: explores repos and existing
  issues, decomposes work by stream (API/Backend/Frontend/Access Control/
  Testing/Documentation/Deployment), and fills the Project #5 fields it is
  permitted to own — always behind a human-approval gate. Refuses to plan when
  the architecture is undecided.
tags:
  - github
  - issues
  - projects
  - epics
  - ilm
inputs:
  - name: EPIC
    description: An existing Epic (issue number or URL), or a free-text requirement.
    required: false
    example: "#142"
  - name: MODE
    description: Force a mode instead of auto-classifying.
    required: false
    example: preflight
  - name: REPO
    description: Target repo short name (no owner). Auto-detected from the cwd clone.
    required: false
    example: core
    auto_detect:
      source: .git/config
      field: remote.origin.url
      pattern: 'github\.com[:/]OmniTrustILM/(?P<repo>[^/.]+)'
  - name: REFRESH
    description: Force re-fetch of the cache before running.
    required: false
    example: "1"
permissions:
  - cli:gh:read
  - cli:gh:write
  - cli:python:read
  - github:issues:read
  - github:issues:write
  - github:projects:read
  - github:projects:write
  - github:org:read
  - github:contents:read
created_at: 2026-06-21
updated_at: 2026-06-21
---

# Skill: Epic Breakdown

Act as the OmniTrustILM platform architect. Given a requirement or an existing
Epic, this skill explores the affected repositories and existing issues, then
either (a) tells you what must be decided before this can be planned
(**preflight**), (b) enriches the Epic and proposes a complete, dependency-aware
set of sub-issues (**breakdown**), or (c) reconciles an existing Epic against the
current state of work (**reconcile**). It is the sanctioned writer of Complexity
and Estimate, and it creates/links sub-issues and sets project fields — but only
after you approve.

`docs/development-process.md` (the methodics) is the authority. The skill reads
it at runtime (`cache/development-process.md`) rather than restating it, so its
behavior cannot drift from the process. Section references below (§) point into
that document.

**Deterministic `gh`/GraphQL/parsing lives in the scripts — do not re-derive it:**
`fetch.sh`, `create-issue-generic.sh`, `link.sh`, `set-epic-fields.sh`,
`enrich-epic.sh`, `reconcile.py`, and the operations in `epic-breakdown.graphql`.
The LLM-led work is classification, exploration, architectural analysis,
decomposition, paraphrasing/enrichment, the preview, and the approval gates.

---

## Invocation

```
/epic-breakdown [--mode preflight|breakdown|reconcile] [--repo <name>] [--refresh] <epic ref or requirement>
```

All flags optional. `<epic ref or requirement>` is either an Epic number/URL or
free-text. `--mode` overrides auto-classification. `--refresh` re-runs `fetch.sh`.

## Phase 0 — Parse args

Extract flags and the trailing reference/requirement. Validate `--mode` against
`preflight|breakdown|reconcile`. `--repo`, if given, is validated against
`cache/repos.json` in Phase 2. Empty input → abort: "missing requirement or Epic
reference."

## Phase 1 — Ensure cache

If `--refresh`, or any of `cache/{project-fields,repos,issue-types,labels}.json`
or `cache/development-process.md` is missing, run `bash $SKILL_DIR/fetch.sh` and
check the exit status. On non-zero exit, surface the error verbatim and stop
(`fetch.sh` rejects a partial cache). If `fetch.sh` reports a missing scope,
relay its exact `gh auth refresh -s …` command.

If `cache/fetched-at.txt` is older than 14 days, print a one-line notice at the
top of the eventual output: "Cache is N days old; re-run with `--refresh` if the
project schema or repo set changed recently."

Read `references/lessons.md` and keep its entries in mind for the rest of the run.

## Phase 2 — Classify the mode

If `--mode` was set, use it. Otherwise classify from the input (content, not
keywords):

- **Reconcile** — input references an existing Epic and asks to update/sync it
  with progress, or the Epic already has sub-issues and the user wants a check.
- **Breakdown** — an existing Epic whose design is settled, or a requirement
  explicit enough to be Epic-ready (clear user story, decided approach).
- **Preflight** — a raw requirement / discovery note with an undecided
  architecture: missing or weak user story/use cases, open questions, competing
  approaches, "needs analysis" language, or a fork that changes which repos are
  touched.

When ambiguous, choose the **least destructive** reading, state your
interpretation, and ask — do not assume breakdown.

If `--repo` was given, validate it against `cache/repos.json`; otherwise
auto-detect from the cwd's `.git/config`, else infer per-sub-issue during
decomposition from the Module→repo map in the methodics (§3.1).

---

## Mode A — Preflight (creates nothing)

The job is analysis and honest blockers, not a plan.

1. **Normalize & restate** the requirement precisely (handle non-English input;
   produce English output unless asked otherwise).
2. **Gather context.** Use the methodics §3.1 Module→repo map to pick the
   relevant repos; explore them; search existing issues/Epics for overlap and
   precedent (cite issue numbers).
3. **Gap & prerequisite check** against the §3.2 required-field gates and the
   §7.2 consistency rules: state *why* this cannot yet be an Epic and which
   undecided forks are load-bearing (a fork that changes repos touched →
   changes Complexity/Estimate → changes the feasible Version).
4. **Architect-level framing.** Lay out the realistic options with trade-offs,
   each mapped to concrete repos/modules and the existing issues you found. Do
   not pick one unless the input already decided it.
5. **Return blocking questions + prerequisites.** Create nothing. Explicitly
   refuse to emit Complexity, Estimate, or a target Version while the design is
   undecided — this enforces the methodics' release-honesty principle (§3.2).

---

## Mode B — Breakdown

**Precondition — the Epic must be in Planning.** Breakdown happens during
Planning (§2.2, §2.6). After resolving the Epic, if its Status is not Planning
(Open/In Progress/Done), warn — "This Epic is in <Status>; breakdown is for
Planning-stage Epics (§2.6). Creating sub-issues now may duplicate
already-implemented work — consider reconcile mode. Proceed anyway? [yes/no]" —
and stop unless confirmed.

1. **Resolve the Epic.** Given an existing Epic number/URL, load it (read its
   form fields). Given a raw, Epic-ready requirement, draft the Epic shell
   (User Story, Use Cases, Constraints, Out of Scope, Testing Scope) and **ask
   the user to approve creating the Epic** before proceeding — never silently
   create it. (Create it with `create-issue-generic.sh --type epic`.)
2. **Explore** the affected repos and existing issues; apply relevant
   `lessons.md` entries.
3. **Generate enrichment** for the Epic body: Acceptance Criteria, Technical
   Analysis, Impact Assessment, enriched Testing Scope, and **Estimate Basis**
   (§3.5 — the basis plus both aggregates: agent-executed total and developer
   baseline).
4. **Decompose by work stream** — API, Backend, Frontend, Access Control,
   Testing, Documentation, Deployment (§2.6). For each child: type
   (Feature/Task/Bug — **never a sub-Feature under a Feature**, §1), target repo,
   §9-conformant title, description, acceptance criteria **including the Sonar +
   ≥80% coverage quality gate**, Module, Complexity, a *suggested* Estimate
   (agent-executed basis per §3.5 by default — derive it from the developer-built
   Complexity scale; use the developer-built basis only when the Epic declares
   it, and **never repeat estimates inside a child body**), blocked-by
   dependencies, and a suggested assignee.
   **Estimate granularity — quarter days, nothing finer.** Every estimate is a
   positive multiple of **0.25** mandays: `0.25`, `0.5`, `0.75`, `1`, `1.25`, …
   0.25 is both the minimum and the increment; `0`, `0.1`, `0.333` and `1.4` are
   all rejected outright by `set-epic-fields.sh`. Round to the nearest quarter
   day — a value derived by division (a day split three ways → `0.333`) fails
   the write.
   **Two ceilings.** An **Epic** caps at **100** mandays: a ~10-week cycle, 50
   working days, at most 2 people. Above it the Epic cannot ship in one release
   — say so rather than writing the number.
   A **child** caps at **4** mandays (agent-executed basis), so it stays
   deliverable inside one week with reserve; on a **developer-built** Epic the
   child cap is **10** mandays, matching the Complexity table's developer-built
   High range. Prefer splitting. When a child genuinely cannot be split, it is
   allowed over the cap **only** if its body carries an `### Estimate` section
   saying why — `set-epic-fields.sh --scope child` reads that section from the
   issue and refuses the write without it (needs at least 20 characters of
   prose). The section carries **only the reason** the work cannot be split —
   never restate the number (the Estimate field is the single source, §3.5). Put
   the reason in the body you build in step 7.1, and surface it in the preview so
   it is approved along with everything else:

   ```markdown
   ### Estimate

   Single Flyway migration; applying it in halves would leave the schema
   inconsistent between steps, so it cannot be split across sub-issues.
   ```
   **Mandatory:** at least one **Task+qa** and one **Task+documentation** child
   (else §7.2 flags the Epic and docs/testing get forgotten).
   **De-duplicate:** before proposing a new child, check the Epic's existing
   sub-issues and search for matching standalone issues. Mark an already-present
   sub-issue `(existing — skipping)`; for a strong match that exists *unlinked*,
   propose **linking** it (Phase 7 uses `link.sh`) instead of creating a
   duplicate. This makes re-running breakdown safe.
5. **Compute Epic-level Complexity & Estimate** per the §3.5 heuristics (the Epic
   Estimate is the overall delivery estimate, not the sum of children).
6. **Render the preview** (see Preview & edit UX). Work-stream-grouped tree,
   provenance tags, dependency arrows, per-child field summary, and an explicit
   "what stays for the PM / Developer" footer.
7. **On `confirm` → human-approval gate (§10),** run this sequence. **Build each
   child body WITHOUT `### Module` / `### Severity` / `### Version Number`
   sections** (the skill sets those fields itself; this avoids racing the
   `auto-set-fields-from-form` automation):
   1. `create-issue-generic.sh --type <t> --repo <r> --title … --body-file - --module <M>` (add `--severity <S>` for Bug children) → capture `node_id`, `item_id`, `number`, `url`. The body must NOT contain `### Module`/`### Severity`/`### Version Number` sections — the script rejects them; fields are set via these flags.
   2. `link.sh --parent-node-id <epic> --child-node-id <child>` to attach the child.
   3. `link.sh --issue-node-id <child> --blocked-by-node-id <blocker>` for each dependency.
   4. `set-epic-fields.sh --item-id <child item> --scope child --basis <agent-executed|developer-built> --complexity <C> --estimate <E>` (`--basis` matches the Epic's declared basis; omit it to default to agent-executed).
   5. After all children: `set-epic-fields.sh --item-id <epic item> --scope epic --complexity <C> --estimate <E>` for the Epic.
   6. `enrich-epic.sh --repo <r> --number <epic#> --enriched-file -` to rewrite the Epic body.
   - **Leave child Version blank** so `version-propagation` automation copies it from the parent. Status stays Planning.
   - **Mid-sequence failure:** stop, and print three lists — completed (with URLs), the failing step (with the error), and not-yet-started. Created-but-unlinked children are also in `cache/orphans.log`. Never silently continue.
8. **Confirm to the user** every created URL, what was set, and what remains:
   **PM** — Version, Sprint, Priority, Start/End Date, moving Status to Open;
   **Developer** — reviewing the written child Estimates; an override is final (§3.5).

---

## Mode C — Reconcile

Sync one Epic's content/decomposition with reality. (Board-wide field/staleness
hygiene belongs to `/project-triage` — do not duplicate it here.)

1. **Load** the Epic and its children via the `EpicState` query
   (`epic-breakdown.graphql`); pass the JSON to `reconcile.py` to get findings.
2. **Re-derive** the expected decomposition from the current Epic content + repo
   state + any new related issues; annotate each child with its work stream.
3. **Present findings** (from `reconcile.py`, which mirrors the §7.2 rules):
   missing QA/docs child, missing work streams, orphaned children,
   Epic-status-lags/ahead-of-children, Epic-Done-with-open-children, version
   mismatch, plus proposed new children or estimate/complexity adjustments.
4. **Per-change confirm** (like `/project-triage`, not one bulk confirm). Before
   each mutation, re-check current state and skip with a warning if it changed.
   **Never overwrite a non-empty, human-set Complexity/Estimate/Module without
   showing the before→after diff and getting that change approved.** Apply
   approved changes with the same scripts as breakdown — a child Estimate write
   is `set-epic-fields.sh --item-id <child item> --scope child --basis <basis> --estimate <E>`; `--scope child` is mandatory with `--estimate` (the script refuses the write otherwise), so the child cap and rationale rule always run.
5. **Never** set Version/Sprint/Priority/dates, force Status, or close issues.
   Propose status nudges to the human (§7.3 rule 4). Child Estimate may be set
   on children this run *creates*, as in breakdown; an Estimate already on an
   existing child is a developer's number and falls under the overwrite rule
   above — diff and approval, never a silent replacement.

**Rule coverage.** `reconcile.py` checks the Epic-and-children consistency rules
(using the same rule names as `project-triage`'s `eval.py`): `empty_epic_no_sub_issues`,
`epic_without_qa_sub_issue`, `epic_without_docs_sub_issue` (this skill's
completeness extension), `epic_done_with_open_children`, `epic_status_lags_children`,
`epic_status_ahead_of_children`, `orphaned_sub_issues`, `version_mismatch`, plus a
`missing_workstream` hint. §7.3 precedence is applied (the Done-with-open-children
error suppresses the overlapping status/orphan warnings). Board-wide hygiene —
staleness, `blocked_but_in_progress`, `done_but_open_state`, `closed_but_not_done`,
`reopened_without_reason` — is **deferred to `/project-triage`** and not duplicated here.

---

## Permission guardrails (§10) — non-negotiable

- **Propose freely; require explicit human approval before ANY create/mutation.**
- **Writes (on approval):** Epic Complexity, Epic Estimate, child Complexity,
  child Estimate, child Module, Epic body, sub-issue links, blocked-by deps,
  sub-issue creation.
  Child Estimate is written as the *suggested* value the preview showed; the
  Developer owns the field and an override is final. Rationale and the
  board-visibility trade-off are in §3.5. (The granularity and caps are in
  step 4 above, where estimates are produced.)
- **Never autonomously:** Version, Sprint, Priority, Start/End Date; forcing
  Status; the deprecated Component/Developer fields; closing issues.

---

## Preview & edit UX

Mirror `create-issue`. Render a fixed-width, provenance-tagged preview:
`(suggested)` for inferred categorical fields, `(paraphrased)` for rewritten
prose, `(extracted)` for verbatim fragments. The breakdown preview adds the
sub-issue tree grouped by work stream with dependency arrows and a per-child
field summary. Tags are preview-only; they never appear in posted content, and
they drop once you edit a field.

Responses: `confirm` / `cancel` / `edit` / `edit <field> <value>`. On `edit`,
re-render. Loop until `confirm` or `cancel`.

**Learning:** if you correct the skill during the edit loop in a way that
generalizes (a Module mapping, a precedent issue, a decomposition rule), the
skill **offers** to append a one-line entry to `references/lessons.md` and writes
it only after you approve.

---

## Error handling

| Situation | Action |
|---|---|
| `gh auth status` fails | tell the user `gh auth login` |
| Missing `repo`/`read:org`/`project` scope | relay `fetch.sh`'s exact `gh auth refresh -s …` command |
| `project`/`read:project` scope missing for project writes | `gh auth refresh -s project` (creating/linking/field-setting needs it; preflight is read-only) |
| `fetch.sh` fails on any sub-step | surface verbatim; stop (partial cache rejected) |
| Stale option ID (Module/Complexity not found) | scripts warn + hint `--refresh`; re-run `fetch.sh` |
| `addSubIssue`/`addBlockedBy` fails | child exists but is unlinked/undepended; `link.sh` prints the manual fix and logs to `cache/orphans.log` |
| `addProjectV2ItemById` fails | issue exists but not in Project #5; logged to `orphans.log`; print manual `gh project item-add` |
| Mid-sequence mutation failure | stop; print completed / failing / not-started lists |
| Reconcile sees state changed since fetch | skip that mutation with a warning |
| Preflight on a non-Epic / undecided design | return analysis + blocking questions; create nothing |
| Epic Status ≠ Planning in breakdown | warn + confirm before proceeding |

---

## Notes

- **Stateless across invocations** — each run reads the cache and starts fresh;
  `references/lessons.md` is the only durable, human-curated knowledge.
- **Scopes:** `repo`, `read:org`, and `project` (write) — or `read:project` for
  preflight-only. The project mutations and `addProjectV2ItemById` need `project`.
- **Don't fight automation:** child bodies omit form tokens the
  `auto-set-fields-from-form` action parses; the skill sets those fields via
  GraphQL so its values are authoritative. Child Version is left blank for
  `version-propagation` to copy from the parent.
- **Rate limits:** breakdown of a large Epic is many mutations; they run
  sequentially. Projects V2 GraphQL is ~5–10 points per mutation — well within
  hourly limits for a single Epic.
- **Concurrent `--refresh` runs are unsafe** (the second overwrites the first's
  `cache.tmp/`); normal runs against a warm cache do not race.
