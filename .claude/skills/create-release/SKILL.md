---
name: create-release
version: 1.0.0
description: >
  Use when starting the next OmniTrustILM quarterly release: creates the
  Release issue and its "Bugs <version>" tech-epic in ilm, sets their
  Project #5 fields, computes the full sprint schedule (incl. boundary-sprint
  trims), and verifies the manual Sprint/Version UI steps. Also plans sprints
  for an existing release via --sprints-only.
tags:
  - github
  - projects
  - release
  - ilm
inputs:
  - name: VERSION
    description: Explicit version for the new release. Optional; default is the latest open 2.x release with the minor bumped.
    required: false
    example: "2.22.0"
  - name: SPRINTS_ONLY
    description: Plan sprints for this EXISTING release instead of creating a new one.
    required: false
    example: "2.21.0"
  - name: REFRESH
    description: Force re-fetch of cached project fields / issue types.
    required: false
    example: "1"
permissions:
  - cli:gh:read
  - cli:gh:write
  - github:issues:write
  - github:projects:write
  - github:org:read
created_at: 2026-09-08
updated_at: 2026-09-08
---

# Skill: Create Release

Start the next quarterly release cycle: compute the version, the release
window, and the sprint schedule from the PM conventions baked into `plan.py`;
create the Release issue and its `Bugs <version>` tech-epic; set their
Project #5 fields; and walk the user through the two steps that must stay
manual (adding the Version option and the Sprint iterations in the UI),
verifying them afterwards.

Deterministic gh/GraphQL/date logic is pre-written in `fetch.sh`, `plan.sh`,
`plan.py`, `apply.sh`, and `verify.sh`. **Invoke those scripts; do not
re-derive the GraphQL or the date math.** The LLM-led work is the preview,
the confirm/edit loop, and relaying the manual checklist.

## ⚠️ Never write Sprint or Version field configuration via the API

`updateProjectV2Field` **replaces** a field's option list / iteration
configuration and **regenerates every option and iteration ID** — including
ones resubmitted unchanged. Existing item assignments point at the old IDs
and are silently orphaned: one such call would blank the Sprint or Version
value on every issue in Project #5 (verified empirically on a scratch
project, 2026-09-08; completed iterations omitted from the payload are
deleted outright). This is why sprints and the Version option are created
manually in the UI and only *verified* by this skill. Do not "fix" this by
calling the mutation with the existing values included — that still rotates
the IDs.

## Conventions encoded in plan.py

- A release covers one calendar quarter; version = previous 2.x minor + 1.
- Start = quarter's first day (weekend → following Monday). End = quarter's
  last day (weekend → preceding Friday). Target Date in the body = End Date.
- Sprints are weekly Mon–Sun, numbered from 1 per release, titled
  `Sprint <n> (<yy>/Q<q>)`. Boundary sprints are cut to the release window;
  an existing iteration overhanging the start gets a trim proposal.
- The `Bugs <version>` epic (label `tech-epic`, Prioritization Medium) is a
  sub-issue of the Release issue and shares its window.

If PM conventions change, update `docs/development-process.md` first, then
`plan.py` and its tests.

---

## Invocation

```
/create-release [--version X.Y.Z] [--sprints-only X.Y.Z] [--refresh]
```

`--sprints-only X.Y.Z` skips issue creation entirely: it reads the existing
release's Start/End Date from Project #5 and produces only the sprint
checklist + verification. `--version` and `--sprints-only` are mutually
exclusive.

## Phase 1 — Parse args

Validate that version arguments match `^\d+\.\d+\.\d+$`; abort otherwise.
Unknown flags abort with: "unknown flag `<flag>`. Accepted: --version,
--sprints-only, --refresh".

## Phase 2 — Ensure cache

If `--refresh` was passed, OR `cache/project-fields.json` or
`cache/issue-types.json` is missing, run `bash $SKILL_DIR/fetch.sh`. On
non-zero exit, surface the error verbatim and stop. If `cache/fetched-at.txt`
is older than 14 days, add a one-line notice to the preview suggesting
`--refresh`.

## Phase 3 — Plan (read-only)

```bash
bash $SKILL_DIR/plan.sh [--version X.Y.Z | --sprints-only X.Y.Z]
```

Prints the plan JSON (also saved to `cache/plan.json`). It discovers the
latest open 2.x Release issue in `ilm` live, reads its End Date, fetches the
live Sprint iterations and Version options, and runs `plan.py`.

If the plan has non-empty `conflicts`, show them and stop — the user must
resolve the iteration clash in the UI (or the plan is being re-run for a
release whose sprints half-exist with different dates). `warnings` are shown
in the preview but do not block.

## Phase 4 — Render preview

Render, all values tagged `(computed)`:

```
Release:      2.22.0                              (computed)
Window:       2027-01-01 .. 2027-03-31  (27/Q1)   (computed)
Target Date:  2027-03-31                          (computed)

Issues to create in OmniTrustILM/ilm (on confirm):
  1. Release "2.22.0"      — type Release, Project #5: Status=Planning,
                             Start Date, End Date, Version (after UI step)
  2. Epic "Bugs 2.22.0"    — type Epic, label tech-epic, sub-issue of the
                             release, Prioritization=Medium, same window

Sprint plan (manual UI step, verified afterwards):
  Sprint 1 (27/Q1)   2027-01-01  3d  (ends 2027-01-03)
  Sprint 2 (27/Q1)   2027-01-04  7d  (ends 2027-01-10)
  …
  Sprint 14 (27/Q1)  2027-03-29  3d  (ends 2027-03-31)
  (sprints already present and matching are marked "exists — OK")

Trims of overhanging iterations (manual UI step):
  Sprint 8 (26/Q3): shorten 7d → 3d so it ends 2026-09-30

Warnings: <plan.json warnings, if any>

Confirm and create? [confirm / cancel / edit]
```

In `--sprints-only` mode, omit the issues section.

## Phase 5 — Confirm / edit loop

- `confirm` → Phase 6 (or straight to Phase 7 in `--sprints-only` mode).
- `cancel` → exit cleanly; nothing was mutated (plan is read-only).
- `edit` → the only editable value is the version: re-run Phase 3 with
  `--version <new>`. Window dates are convention-derived; if the user
  explicitly wants a non-standard window, re-run `plan.py` directly —
  `jq '.iterations' cache/live.json | python3 $SKILL_DIR/plan.py --version
  X.Y.Z --start YYYY-MM-DD --end YYYY-MM-DD --iterations-json /dev/stdin >
  cache/plan.json` — note the deviation in the preview, and continue.

## Phase 6 — Apply (mutating; new-release mode only)

```bash
bash $SKILL_DIR/apply.sh
```

Creates both issues, sets types and project fields, links the sub-issue, and
writes `cache/state.json`. Output is `key=value` lines (`release_url`,
`release_number`, `epic_url`, `epic_number`) — capture them. `apply.sh`
refuses to run twice for the same version (title guard) and aborts before
creating anything if the token lacks the `project` scope.

If it exits non-zero after "created … issue", relay the error verbatim — the
issue may exist without project fields; the script logs how far it got.

## Phase 7 — Manual UI checklist

Print the exact steps, values from `cache/plan.json`:

```
Manual steps in https://github.com/orgs/OmniTrustILM/projects/5/settings:

1. Field "Version" → New option: "2.22.0"
2. Field "Sprint" → for each planned sprint not marked "exists":
   Add iteration with the exact title, start date and duration listed above
   (use "More options" to set a custom start date / duration in days).
3. Trims: edit the listed iteration(s) to the shortened duration.

Tell me when you're done and I'll verify and finish the field setup.
```

The checklist may also be executed by Claude driving the project settings UI
in a browser the user has signed into. Lessons from doing that (2026-09-08):
the React controls ignore programmatic value sets — iteration *names* must be
typed with real keystrokes (JS-set values render but silently revert on Save),
and some buttons (Edit date range, More options, Units) only respond to
dispatched pointer-event sequences, not plain synthetic clicks. The quick
"Add iteration" button reuses the last duration set in the More options
dialog, not the previous iteration's. Always re-run Phase 8 verification
after saving — a Save that looks successful can still have dropped the
renames.

## Phase 8 — Verify (repeatable)

When the user says done (or asks for a check), run:

```bash
bash $SKILL_DIR/verify.sh
```

Exit 0 = everything matches; it has also set Version on the new release and
epic (when `cache/state.json` is present). Exit 2 = show the `MISSING` /
`MISMATCH` / `PENDING` lines verbatim and offer to re-verify after the user
fixes them. Any other exit = surface the error verbatim.

Finish with a summary: issue URLs, window, sprint count, and Version status.

---

## Error handling

| Phase | Situation | Action |
|---|---|---|
| Cache | `gh` unauthenticated / missing scope | Relay the exact `gh auth …` command from the script |
| Plan | No open 2.x Release found | Ask the user for `--version` + check the `ilm` repo |
| Plan | Latest release lacks End Date | Tell the user to set it in Project #5 first |
| Plan | `conflicts` non-empty | Show them; stop before any mutation |
| Apply | Issue title already exists | Abort (guard); suggest `--sprints-only` if the release exists |
| Apply | Created but project add/field failed | Relay the script's `warn:` lines; nothing is retried silently |
| Verify | exit 2 | List remaining manual steps; loop on user request |

## Notes

- `plan.sh` is read-only and safe to re-run any time; `verify.sh` mutates
  only the Version value on the two issues recorded in `cache/state.json`.
- This skill is the sanctioned writer of the Release/Bugs-epic Version,
  Start Date and End Date values (methodics §10) — the same carve-out
  `epic-breakdown` has for Complexity/Estimate. It still never touches
  Sprint assignments on issues, and never rewrites field configurations.
- Required scopes: `repo`, `read:org`, `project`.
- Offline tests: `bash $SKILL_DIR/plan.test.sh` (run by the Action tests
  workflow).
