---
name: create-issue
version: 1.0.0
description: >
  Use when creating an OmniTrustILM issue from a natural-language
  description. Supports Bug, Feature, Task, Documentation, QA. Skip
  for Epic (use /epic-breakdown), Release, or Vulnerability (use the
  form templates).
tags:
  - github
  - issues
  - projects
  - ilm
inputs:
  - name: REPO
    description: Target repo short name (no owner). Optional; otherwise inferred.
    required: false
    example: core
    auto_detect:
      source: .git/config
      field: remote.origin.url
      pattern: 'github\.com[:/]OmniTrustILM/(?P<repo>[^/.]+)'
  - name: TYPE
    description: Issue type. Optional; otherwise asked interactively.
    required: false
    example: bug
  - name: SEVERITY
    description: Bug severity. Optional; otherwise inferred or asked.
    required: false
    example: major
  - name: MODULE
    description: Platform module. Optional; otherwise inferred.
    required: false
    example: Certificates
  - name: REFRESH
    description: Force re-fetch of cached templates / fields / labels / repos.
    required: false
    example: "1"
permissions:
  - cli:gh:read
  - cli:gh:write
  - github:issues:write
  - github:projects:write
  - github:org:read
  - github:contents:read
created_at: 2026-04-28
updated_at: 2026-04-28
---

# Skill: Create Issue

Convert a natural-language description into a well-formed OmniTrustILM issue. The skill prompts for type if not provided, picks the target repo (or accepts an override), auto-fills the issue's template fields, shows a preview with provenance tags, lets the user edit, then posts the issue and sets project fields via `gh` and GraphQL.

Logic that is deterministic and gh/GraphQL-shaped is pre-written in `fetch.sh` and `create.sh`. **Invoke those scripts; do not re-derive the GraphQL or template parsing logic.** The LLM-led work is type prompts, repo inference, paraphrasing, preview rendering, and the edit loop.

---

## Invocation

```
/create-issue [--repo <name>] [--type <bug|feature|task|documentation|qa>] [--severity <minor|major|critical|blocker>] [--module <module>] [--refresh] <description>
```

All flags optional. `<description>` is everything after the last flag — free natural-language text. Quotes inside `<description>` are preserved verbatim.

`--refresh` re-runs `fetch.sh` before any other phase. Use after template / project schema changes.

---

## Phase 1 — Parse args

Split the invocation into flags and `<description>`. Validate flag values:

- `--type` must be one of: `bug`, `feature`, `task`, `documentation`, `qa`. If `epic`, `release`, or `vulnerability`, abort with: "`<type>` issues are best created via the form template directly. For Epic, use `/epic-breakdown` after creation."
- `--severity` must be one of: `minor`, `major`, `critical`, `blocker`.
- `--module` must match one of the 17 Module values (case-insensitive). Read from `cache/project-fields.json → fields.Module.options`.
- `--repo` validation deferred to phase 4 (after cache is loaded).
- Unknown flags abort with: "unknown flag `<flag>`. Accepted: --repo, --type, --severity, --module, --refresh".

The remainder after the last flag is `<description>`. If `<description>` is empty, abort: "missing description. Usage: /create-issue <description>".

## Phase 2 — Ensure cache

If `--refresh` was passed, OR any of `cache/templates.json` / `cache/project-fields.json` / `cache/labels.json` / `cache/repos.json` is missing, run `bash $SKILL_DIR/fetch.sh` and check exit status.

If `fetch.sh` exits non-zero, surface the error to the user verbatim and stop. Do not proceed to later phases without a complete cache.

If `cache/fetched-at.txt` is older than 14 days, print a one-line soft notice at the top of the eventual preview: "Cache is N days old. Run with `--refresh` if you've recently changed templates or project fields."

## Phase 3 — Resolve type

If `--type` was set in phase 1, use it. Otherwise present a numbered select to the user:

```
Which issue type?
  1. Bug         — something is broken
  2. Feature     — new functionality
  3. Task        — non-feature work
  4. Documentation — docs work
  5. QA Issue    — testing framework / automation work

Pick a number, or type the name:
```

Re-prompt up to 3 times on invalid input, then cancel cleanly.

For each unsupported type the user might attempt:
- `epic` / `Epic` → "Epics are best created via the form + `/epic-breakdown` skill — see methodics 2.6. Cancelled."
- `release` / `Release` → "Releases are PM ceremony; use the form template directly. Cancelled."
- `vulnerability` / `Vulnerability` → "Vulnerabilities should be entered deliberately via the form template (CVE, source, severity all matter). Cancelled."

## Phase 4 — Resolve target repo

If `--repo` was set in phase 1, validate against `cache/repos.json` (must match a `name` exactly). If not found, abort with the closest-match suggestion using a string-distance heuristic.

Otherwise, attempt auto-detection from the current working directory. If the cwd or any ancestor contains a `.git/config` whose `remote.origin.url` matches `github\.com[:/]OmniTrustILM/(?P<repo>[^/.]+)`, default to that repo and tag it `(auto-detected from .git/config)` in the preview. If no clone is detected, the LLM picks a repo from `cache/repos.json` based on the description. Each cached repo has `name` and `description` (from gh). Use the description text to anchor the choice. The choice is shown in the preview tagged `(suggested)` and editable.

For multi-repo descriptions (description spans both UI and API or two providers), pick the **primary** repo — the surface where the user-facing change lands or where the bulk of the work concentrates. Note the cross-repo touch in the issue body's Description as a final sentence: "Note: this also touches `<other-repo>` for related backend / frontend / connector work."

## Phase 5 — Auto-fill fields

Look up the chosen issue type in `cache/templates.json` to get the field structure for that type. Each field has: label, id, type (`textarea` / `dropdown` / `input` / `checkboxes`), required-ness, options (for dropdowns).

For each field, decide its provenance:

- **`(suggested)`** — categorical or short-form field; LLM infers from description signals. Examples: Severity from urgency words (crash, blocker, broken → Major/Critical/Blocker; minor, cosmetic → Minor), Module from domain keywords (certificate, key, secret → corresponding Module value).
- **`(paraphrased)`** — prose fields where the LLM rewrites the user's input into clean field-shaped text. Description, Use Case, Definition of Done, Acceptance Criteria, Steps to Reproduce, Expected, Actual.
- **`(extracted)`** — verbatim fragments from the user's input. Triggered by:
  - Triple-backtick code blocks
  - Patterns matching error codes (`HTTP \d{3}`, `[A-Z][A-Za-z]*Exception`)
  - Version strings (`\d+\.\d+\.\d+`)
  - Quoted strings (single or double quotes around 5+ chars)

Fields **never** auto-filled (PM-controlled, set during triage):

- Version (target release)
- Sprint (iteration)
- Priority (PM during triage)
- Start Date / End Date (PM for Epics/Releases)
- Complexity / Estimate (developer or `/epic-breakdown` skill)

Optional fields where the description has no signal: leave blank. They are listed at the bottom of the preview under "Optional fields not filled" but the body sent to GitHub omits them entirely.

## Phase 6 — Render preview

Render the filled issue as a fixed-width aligned block. Field name on the left, value on the right, provenance tag in parentheses where applicable. Long values wrap aligned under the value column.

Example for Bug:

```
Type:                Bug
Repo:                OmniTrustILM/core           (suggested)
Title:               Certificate export crashes with wildcard SAN
Severity:            Major                       (suggested)
Module:              Certificates                (suggested)
Description:         The certificate export fails when the SAN contains
                     a wildcard. Started in 2.14.0.    (paraphrased)
Steps to Reproduce:  1. Open a certificate with wildcard SAN
                     2. Click Export
                     3. Observe crash                  (suggested)
Expected:            Export completes and produces a file.   (suggested)
Actual:              Export crashes.                  (extracted)
Environment:         ILM 2.14.0                       (extracted)

Optional fields not filled: Logs, Screenshot

Confirm and create? [confirm / cancel / edit / edit <field> <value>]
```

**Tag rules in the rendered preview:**

- `(suggested)` for LLM-inferred categorical/short fields
- `(paraphrased)` for LLM-paraphrased prose
- `(extracted)` for verbatim fragments
- No tag for direct flag values (`--severity major`) or for fields the user has already edited in this session

**Tags are preview-only.** They never appear in the issue body that the skill posts. The body is the clean form-shaped markdown shown in Phase 8.

## Phase 7 — Edit loop

User responses at the preview:

- `confirm` → proceed to Phase 8.
- `cancel` → exit cleanly. No issue created. Cache stays warm for next invocation.
- `edit` → enter the **two-step** flow.
- `edit <field> [<value>]` → enter the **one-step shortcut**.

**Two-step (`edit`):** print a numbered list of all fields (filled and optional unfilled). User picks a number. Re-prompt that field's value:

- Categorical fields (Type, Repo, Severity, Module): list valid options, accept the user's next message verbatim, validate.
- Prose / long-form fields (Description, Steps to Reproduce, Expected, Actual, Acceptance Criteria, Use Case, Definition of Done, Test Scenarios, Environment): prompt "Type the new value (entire next message will replace the current value):". The user's next chat message — verbatim, including any line breaks — replaces the field. Strip outer whitespace only. Do NOT wait for a `.` or empty-line terminator; this is a turn-based chat UX, not a shell.

Re-render preview.

**One-step shortcut (`edit <field> [<value>]`):** match `<field>` case-insensitively, prefix-matched, against the current field set. Examples: `edit sev blocker` → matches Severity. For categorical fields, validate `<value>` against the option list — re-prompt that field on invalid value. For prose / long-form fields, ignore the optional inline `<value>` and drop into the same "next message replaces value" prompt described above.

**Tag transitions on edit:** when the user edits a tagged field, the tag drops in subsequent previews. The value is now user-set, not LLM-set, so the provenance label no longer applies. Untagged values stay untagged across edits.

Loop until `confirm` or `cancel`.

## Phase 8 — Create

Build the form-shaped body from the confirmed fields. For each filled field, emit:

```
### <Field Label>

<value>

```

(Field Label is the exact label string from `cache/templates.json`. A blank line separates fields.)

Skip optional fields that are blank. Do not emit `_No response_` placeholder text — leaving the field absent from the body matches GitHub's behavior for blank form submissions.

**Pipe the body via stdin in a single Bash tool call.** Do NOT write a temp file with the Write tool and then invoke `create.sh` in a separate Bash call — Windows Git-Bash tmpfile paths resolved by the Write tool do not always match what `bash` sees, and the second tool call will fail with `body file not found`. Use a heredoc, all in one Bash invocation:

```bash
bash $SKILL_DIR/create.sh \
  --repo "$REPO" \
  --type "$TYPE" \
  --title "$TITLE" \
  --body-file - \
  ${SEVERITY:+--severity "$SEVERITY"} \
  ${MODULE:+--module "$MODULE"} <<'BODY_EOF'
### Description

…paraphrased description here…

### Severity

Major

…remaining filled fields…
BODY_EOF
```

`--body-file -` means create.sh reads the body from stdin into a script-internal temp file, eliminating any cross-tool path mismatch. Use the literal heredoc terminator `BODY_EOF` (not a generated random one) so the LLM does not need to mint a unique sentinel each invocation.

`create.sh` returns key=value lines on stdout: `url=...`, `number=...`, `item_id=...`. Capture them.

If `create.sh` exits non-zero with output containing `gh issue create failed`, abort with the gh error.

If `create.sh` exits non-zero with output containing `addProjectV2ItemById failed`, the issue exists but was not added to the project. Surface to the user: "Issue created at <url> but adding to Project #5 failed. Run `gh project item-add 5 --url <url> --owner OmniTrustILM` to add manually."

If `create.sh` exits 0 but the field-set log shows `warn: failed to set <field>=<value>`, surface that line to the user too — the issue is in the project but a field is blank.

## Phase 9 — Confirm to user

Print:

```
Issue created.

  URL:     <url>
  Number:  #<n>
  Repo:    OmniTrustILM/<repo>
  Type:    <Type>
  Module:  <module if set>
  Severity: <severity if set>

Project #5: <project URL>

Body posted (form-shaped markdown):
<the body content>
```

Then exit cleanly. Cache stays warm for the next invocation.

---

## Error handling

| Phase | Situation | Action |
|---|---|---|
| Args | Unknown flag | Abort with accepted-flag list |
| Args | Invalid `--type` for unsupported types | Abort with "use form / use /epic-breakdown" pointer |
| Cache | `gh auth status` fails | Tell user `gh auth login` |
| Cache | Missing `repo` scope | Tell user `gh auth refresh -s repo` |
| Cache | `fetch.sh` fails on any sub-step | Surface verbatim; stop — partial cache is rejected by atomic-rename |
| Type | 3 invalid prompts | Cancel cleanly |
| Repo | `--repo X` not in cache | Suggest closest match; hint to `--refresh` |
| Auto-fill | LLM call fails or times out | Fall through to a description-only template; proceed to preview with notice "Auto-fill unavailable; please edit fields before confirming" |
| Edit | Invalid value for categorical field | Re-prompt that field |
| Create | `gh issue create` fails | No issue created, no project mutations |
| Create | Issue created but project add fails | Issue exists; print manual fix command |
| Create | Project add succeeds, field set fails | Issue is in project; print warning per failed field |
| Cancel | At preview | No issue, no mutations, clean exit |

## Notes

- The skill is **stateless across invocations** — each invocation reads the cache and starts fresh. Cache is the only persistent artifact.
- Concurrent `create.sh` invocations are safe — each creates an independent issue. Concurrent `fetch.sh` runs (e.g. two `--refresh` invocations at once) are NOT safe; the second will overwrite the first's `cache.tmp/`. Avoid running two refreshes simultaneously. Normal `create.sh` invocations that hit a warm cache do not race.
- Rate limits — Project V2 GraphQL is ~5 points per mutation; per invocation we do at most 3 mutations (add + 2 fields). Well below per-hour limits.
- The skill must NOT touch Version, Sprint, Priority, Start Date, End Date, Complexity, or Estimate fields. Those are PM/triage controlled.
- Required `gh` token scope: `repo` (write access). If the active token (e.g. `GH_TOKEN` env var) only has `public_repo`, label management on internal/private repos returns 404 with a misleading "label not found" message. Run `gh auth refresh -s repo`, or unset `GH_TOKEN` to fall back to a keyring token that has `repo`.
