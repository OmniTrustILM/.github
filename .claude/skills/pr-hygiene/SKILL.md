---
name: pr-hygiene
version: 1.0.0
description: >
  Use when scanning a pull request or branch diff for comment and log noise
  before merge - internal or planning refs, leftover debug prints, comments
  that restate the code, verbose doc comments, decision-log narration, facts
  duplicated across doc surfaces, unimported fully-qualified names and dead
  code. Proposes concrete before/after edits over added lines only and applies
  the ones the author picks. Hygiene only: correctness, security, performance
  and design belong to a full code review.
tags:
  - github
  - pull-requests
  - code-review
  - hygiene
  - ilm
inputs:
  - name: TARGET
    description: A PR URL, a bare PR number, or a branch name. Defaults to the current branch.
    required: false
    example: "1234"
  - name: PROPOSE_ONLY
    description: Emit the findings JSON array and nothing else; makes the run read-only.
    required: false
    example: "--propose-only"
permissions:
  - cli:gh:read
  - cli:git:read
  - github:contents:read
  - local:files:write
created_at: 2026-08-14
updated_at: 2026-08-14
---

# Skill: PR Hygiene

Find low-value comments, logging noise, and small code-hygiene issues in the lines a PR adds or changes, propose concrete before→after edits, and — unless `--propose-only` is set — apply the edits the author approves to the working tree. This skill is narrow: it does **hygiene only**. Correctness, security, performance and design belong to a full code review, not here.

## Invocation

```
/pr-hygiene [PR url | PR number | branch] [--propose-only]
```

Both arguments are optional. With no target, the current branch is used.

## Modes

Parse the arguments for the flag `--propose-only` (strip it before resolving the target):

- **Default (interactive)** — scan, present the triage table, ask which fixes to apply, then edit the working tree.
- **`--propose-only`** — scan and emit the **findings JSON array** (schema under `--propose-only` mode: emit JSON, below) and nothing else. No table, no questions, no edits. This is the mode for programmatic callers — a wrapper command, a script, a CI step — so keep the output a clean machine-readable array with no prose around it.

## Step 1 — Resolve the target and the diff

Target resolution is deterministic, so it lives in a script rather than in this prose. Run it from the repo under review and read its `key=value` output:

```bash
bash "$SKILL_DIR/resolve-target.sh" "<target>"      # target may be empty
```

It prints `is_pr`, `number`, `url`, `base`, `head_ref`, `head_oid`, `diff_from`, `diff_to`. Do not re-derive any of this by hand — the script already handles the cases that make hand-rolling wrong:

- **It follows the resolved head, not the local `HEAD`.** Otherwise `/pr-hygiene 1234` run from another checked-out branch silently scans *that* branch, reports it as PR 1234, and in default mode edits those files.
- **It refuses a PR from a different repository.** A PR URL resolves anywhere; the diff can only come from this clone. Mismatched owner/repo is a hard stop.
- **It fetches a fork PR's head from the fork**, which is not on `origin`.
- **It resolves `head_oid` even with no PR**, so a branch-only run still has something for the apply gate to compare against.

Then capture the diff over that range:

```bash
git --no-pager diff "$diff_from".."$diff_to"
```

If the range is empty, stop — in default mode say so plainly; under `--propose-only` emit `[]` and nothing else.

**Before applying anything in Step 4**, require `git rev-parse HEAD` to equal `head_oid`. If it differs, report the findings and refuse to edit: the working tree is not what was scanned. This holds for branch-only runs too, where `head_oid` is the named branch's commit.

## Step 2 — Scan added/changed lines only

**Read scope and flag scope are different things.** Read the whole file freely — several checks cannot be decided otherwise: Check 3 needs the method's existing doc comment to know an added inline comment restates it, Check 5 needs the import block and types in scope to rule out a simple-name collision, Check 8 needs the adjacent annotation. But only ever **flag** lines the diff adds or modifies (the `+` hunks), and only ever **edit** those lines. A pre-existing line is never a finding and never an edit target; when the fix would land outside the diff, report the finding as advisory with no proposed edit.

**Read that context from the scanned commit, never the working tree** — `git show "$diff_to":<path>`. The working tree is only required to match `head_oid` at Step 4, so during the scan it can be a different branch entirely, or not contain the file at all when the PR adds it. Deciding "does the doc comment already say this" or "is the simple name collision-free" against the wrong revision produces findings that are wrong or silently missing, while the output still looks authoritative.

Be **language-aware** for comment and log syntax across the languages present in the diff (JS/TS, Java/Kotlin, Go, Python, shell, C#, SQL, YAML, etc.). Classify each added line against the checks below:

| # | Category | What to flag |
|---|----------|--------------|
| 1 | **Internal / planning refs** (`internal-ref`) | Planning and process residue leaking into shipped code or comments: paths into design, spec or plan documents; internal wiki, tracker or chat URLs; agent and tooling chatter; conversational leftovers ("as discussed", "per the plan", "see my comment above"); and references to any directory or repository that is not part of the deployed artifact. The test: a reader outside this team, reading only the code, could not act on it. |
| 2 | **Debug / excessive logging** (`debug-log`) | Leftover debug prints — `console.log`/`console.debug`, `println`, `System.out.print*`, `fmt.Print*`, bare `print(...)`, `printf` used for tracing — added during development; commented-out log lines; obviously verbose trace spam. |
| 3 | **Obvious / redundant comments** (`obvious-comment`) | Comments that restate the code (`// increment i`, `// constructor`), auto-generated boilerplate comment stubs, docstrings that add no information beyond the signature, and inline comments that merely restate what the method's own Javadoc/docstring already says. Also **step narration** over self-explanatory code — `// 1. validate` / `// 2. save` walking through statements that already read clearly. In tests, a comment above assertions that restates the **test method's own name** (`// the v1 fields survive` above `assertEquals` blocks in `v1FieldsSurvive...`) is the same finding — the descriptive name and the assertion messages are the label; the comment must add what they cannot, or go. Inline comments are for the non-obvious; each one this PR adds should have to earn its place, and well-named code usually needs none. |
| 4 | **Dead code & noise** (`dead-code`) | Commented-out code blocks, `TODO`/`FIXME` **introduced by this PR**, scratch markers (`XXX`, `DEBUG`, `REMOVE ME`), and runs of **3 or more** consecutive blank lines added by the diff. Two blank lines are never a finding - PEP 8 mandates exactly two between top-level Python definitions and `black` enforces it, so a 2-line threshold would flag every conforming Python file and its fix would break the repo's own format check. |
| 5 | **FQN instead of import** (`fqn-instead-of-import`) | A fully-qualified type name used inline in code — `java.util.List<String>`, `com.foo.Bar.baz()` in Java/Kotlin, fully-qualified refs in C#/TS — where **the same file already imports that exact type** and other references to it use the simple name. That is the objective condition: the file is inconsistent with itself, not that one form reads better. An FQN in a file that does not import the type is a legitimate choice and never a finding. **Always advisory** (see the guardrail): the fix needs an import line the diff does not contain, which this skill may not add. |
| 6 | **Decision / history narration** (`decision-narration`) | Comments that record a decision or change-history instead of explaining the code — "changed from X to Y", "was previously…", "per review / as agreed / decided to…", changelog-in-code. The substance belongs in the commit message, PR, or design doc, not the code. |
| 7 | **Verbose doc comments** (`verbose-doc`) | Javadoc/JSDoc/docstrings/XML-doc **added by this PR** whose summary runs past roughly two sentences into implementation narration, prose restatements of the parameter list, or multi-paragraph essays. A doc comment should open with one or two plain sentences saying what the thing does; detail belongs in the tags. The fix is always **tighten, never delete** — see the guardrail. |
| 8 | **Duplication & rot across doc surfaces** (`doc-duplication`) | The same fact stated in more than one doc surface of the same element — method doc comment restating an adjacent machine-read annotation's prose (`@Operation`/`@Schema` descriptions, OpenAPI summaries, assertion messages), or behavior described in method doc, annotation, *and* a type-level overview. The surface that **ships** (annotation, wire schema) is authoritative; the doc comment keeps only what the annotation cannot carry (rationale, cross-references, implementer warnings) or it goes. Also **counted claims** — "eleven controllers already page this way", "all twenty types live under v2" — where the number rots silently the day the next one lands: flag the count, keep the claim. |

### Guardrails — never propose removing these

- **License / copyright / SPDX headers** — leave untouched, always.
- **Pre-existing TODO/FIXME** — only flag TODO/FIXME that this PR's diff *adds*. If the marker predates the diff, ignore it.
- **Intentional logging** — leveled/structured logging (`logger.info` / `.warn` / `.error` / `.debug` through a real logger, structured event logs) is signal, not noise. Only flag *raw* debug prints (Check 2). When unsure whether a log is intentional, mark it **low confidence**, do not auto-apply it.
- **Test / example / fixture files** — `print`/`console.log`/`println` in test, spec, example, demo, or fixture files is frequently intentional (asserting output, illustrating usage). Mark any Check-2 print in such paths **low confidence** at most — never auto-apply.
- **Program output is not debug noise (Check 2)** — in shell scripts, and in CLI entry points or `main`/`__main__` paths in any language, `echo`/`printf`/`print` *is* the program's interface. Flag only lines that are plainly diagnostic (variable dumps, `here`, `got to X`, a value printed with no surrounding message). Outside an obvious debug leftover, cap confidence at **medium**.
- **Public-API doc comments (soft guard)** — Javadoc/JSDoc/docstrings/XML-doc on exported/public symbols are contracts. Flag one only when it is *clearly* redundant (pure restatement of the signature), and even then propose tightening over deletion. Never strip a doc comment that documents params, returns, throws, or behavior. For the Check-3 Javadoc-restatement case, the target is the *redundant inline comment that duplicates the doc*, not the authoritative doc comment — remove the restatement, leave the Javadoc/docstring.
- **Verbose doc comments are tightened, never deleted (Check 7)** — the only permitted fix is rewriting the prose down to one or two simple sentences. Every `@param`, `@return`, `@throws`, `@see`, `@deprecated` and equivalent tag survives verbatim, and so does any sentence carrying a constraint, gotcha, thread-safety note, or unit — length is the finding, information is not. Show the proposed short version as `before → after` so the author can judge what was dropped. Cap confidence at `medium`: brevity is a judgment call, so this is a **suggest**, never an auto-apply. A long doc comment that is dense with real contract detail is not a finding. The same tighten-never-delete rule covers **wire-facing annotation prose** (`@Schema`/`@Operation` descriptions): the annotation keeps a short consumer-facing summary and every constraint a consumer relies on; implementer-facing detail (aggregation rules, safety obligations, synthesis notes) moves to the doc comment, which does not ship. Never move a consumer-relevant constraint off the wire.
- **Check 5 is advisory-only and is never applied** — never flag a fully-qualified name that is *required*: a simple-name collision (two imported types share the same simple name), `{@link}`/doc-reference contexts where an FQN is conventional, reflection/string usage, generated code, or a file that deliberately uses FQNs as house style. Even when the finding is sound, **report it and stop there**: the fix replaces the usage *and* needs an import line that is not part of the diff, and editing outside the diff is forbidden. Emit it with `advisory: true`, cap confidence at `medium`, drop to `low` when a collision can't be ruled out, and exclude it from every apply path including selection by number. Word the `suggestion` as "add `import <FQN>` and use the simple name".
- **Duplication findings (Check 8)** are always **suggest**, capped at `medium` — deciding which copy is authoritative is a judgment call, and deleting the wrong copy can strip the only surface a given reader sees (IDE hover reads Javadoc; generated clients read annotations). Propose which copy survives and why.
- **Check 8 never edits a surface the diff did not touch** — when a PR adds an `@Operation`/`@Schema` annotation beside a doc comment that already existed, the duplicate is pre-existing and out of bounds. Report it as advisory with no proposed edit. The same applies to the Check-3 Javadoc-restatement case when the doc comment predates the diff: only the added line can be edited.
- **Genuine WHY comments (Check 6)** — do **not** flag a comment that explains *why the current code is the way it is* (a constraint, gotcha, or non-obvious reason) — those are valuable and stay. Only flag *history / decision-event* narration (what the code used to be, when/why/who changed it, ticket/PR/review references). When a comment mixes rationale and history, propose trimming the history and keeping the rationale — do not delete the whole comment.
- **A tracker reference that names a constraint is rationale, not history (Checks 1 and 6)** — `// workaround for interfaces#798: AA_COMPROMISE maps to the wrong CRLReason` explains why the code exists and stays, even though it contains an issue reference. Only *bare provenance* carries no reason and goes: "per review #12", "see PR 340", "added in ticket X". This overrides **Check 1 in its entirety**, not just its tracker-URL clause: a cross-repo issue reference also matches Check 1's "references a repository that is not part of the deployed artifact" clause, and without a whole-check override that clause would flag - and `apply all` would delete - the very comment this guardrail exists to protect.

For each finding decide a **confidence**: `high` (clear debug print, obvious comment, internal ref), `medium`, `low` (judgment call).

**"Auto-apply" means applying a finding the author did not select individually** — the `apply all` and `apply high-confidence only` bulk options. Anything at `low` confidence, and the suggest-only Checks 7 and 8, are excluded from both bulk options and can be applied only by explicit selection by number.

**Advisory findings are never applied at all**, by any route: Check 5 always, and any Check 7 annotation-move or Check 8 finding whose authoritative copy sits outside the diff. Their fix would touch a line the diff does not contain, which Step 2 forbids. Report them, mark them `advisory: true`, and leave them to the author.

## Step 3 — Default mode: triage table

Present findings grouped by category, sorted high→low confidence:

A compact table: `# | Cat | Conf | Location (file:line) | Issue | Suggested edit`. Keep cells short. `Conf` is the finding's confidence — the bulk apply options act on it, so it must be visible before the author chooses. Mark findings by how they may be applied, and say so beneath the table:

- `*` **suggest-only** (Checks 7 and 8, and anything at `low` confidence) — excluded from the bulk options, selectable by number.
- `!` **advisory** (Check 5 always; any Check 7 annotation-move or Check 8 finding whose authoritative copy sits outside the diff) — **not applicable at all**. Omit these rows from the selection and edit prompts entirely, so no number the author can type maps to one. A half-applied advisory fix leaves the file broken: dropping an FQN to its simple name without adding the import does not compile.

Below the table, for any non-trivial edit, a one-line before/after block so the user sees exactly what changes.

Then use **`AskUserQuestion`** to offer: **apply all** / **apply high-confidence only** / **pick a subset by number** / **edit a suggestion** / **none**, matching the house preview -> confirm/cancel/**edit** convention.

**edit a suggestion** takes a finding number and a revised replacement, re-renders that row, and returns to this gate — the author can revise as many as they like before anything is written. It matters most for Check 7, where the proposed doc rewrite is a judgment call the author will often want to word differently. Before writing anything, echo the exact finding numbers about to change.

If the diff is empty or yields no findings, say so plainly and stop.

## Step 4 — Default mode: apply

Apply the chosen edits to the working tree with `Edit`. Re-read the current file content before editing — diff line numbers may not match the working tree exactly; match on the line's text, not its number.

Handle the cases where matching by text fails, and never guess:

- **Text absent** (branch moved on, or the working tree changed since the scan): skip the edit and report it as not applied, with the reason.
- **Text matches more than once** — the common case for a repeated `console.log("here")`: disambiguate with surrounding context lines so the `Edit` target is unique. Never fall back to `replace_all`.
- **Working tree already dirty** before applying: say so up front, so the author can tell your edits apart from their own.

After applying, report a short summary: N edits applied across M files, by category, plus anything skipped and why. **Do not** commit, push, or stage — the author reviews the diff and commits separately. Never edit anything outside the repository under review.

## `--propose-only` mode: emit JSON

Skip Steps 3–4 entirely. Emit **only** this JSON array, one object per finding — no prose, no table, no questions, no edits. **When there are no findings (or the diff is empty), emit `[]`** — never prose; the caller parses this output.

**Failures also keep stdout clean.** If target resolution fails — repo mismatch, PR not found, fetch error — write the reason to **stderr** and exit non-zero. Never print an explanation on stdout: the caller parses stdout as JSON and prose there is a parse error rather than a diagnosable failure.

```json
[{ "category": "internal-ref|debug-log|obvious-comment|dead-code|fqn-instead-of-import|decision-narration|verbose-doc|doc-duplication",
   "file": "path", "line": 0, "line_text": "the exact added line, verbatim",
   "issue": "one-sentence description",
   "suggestion": "concrete before→after or 'remove line'",
   "advisory": false,
   "confidence": "high|medium|low" }]
```

Contract notes for callers:

- **`line`** is the line number in the **post-image** of the diff (the `+` side), as `git diff` reports it, and it **always stays on an added line** — it is safe for a caller to anchor an inline PR review comment to the `RIGHT` side at this number.
- **`target_file` / `target_line`** (optional, advisory findings only) name the out-of-diff location the finding is *about* — the pre-existing doc comment beside a newly added `@Operation`, or the Check-8 authoritative copy. They are context for a human, never an anchor: posting a review comment there would fall outside the diff hunk and be rejected.
- **`line_text`** carries that line verbatim. Because working-tree line numbers can drift from diff line numbers, this is the reliable anchor — prefer it over `line` when re-locating the finding.
- **`advisory: true`** marks a finding whose fix cannot be expressed as a single-line edit and must not be applied mechanically: the two-part Check-5 fix (replace the usage *and* add the import), the Check-7 annotation-to-doc-comment move, and any Check-8 finding whose authoritative copy sits outside the diff. Callers should surface these for a human and never auto-apply them.

## Constraints

- Hygiene only — never report correctness, security, performance, or style-preference findings. Those belong to a full code review.
- Added/changed lines only. Never touch pre-existing lines.
- Honor every guardrail above. When a guardrail and a check disagree, the guardrail wins.
- No commit, no push, no staging. No edits outside the repository under review.
- Empty diff / no findings: default mode says so plainly and stops; `--propose-only` emits `[]`.
