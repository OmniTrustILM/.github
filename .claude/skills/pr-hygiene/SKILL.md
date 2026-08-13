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
  - name: --propose-only
    description: Emit the findings JSON array and nothing else; makes the run read-only.
    required: false
---

## Invocation

```
/pr-hygiene [PR url | PR number | branch] [--propose-only]
```

Both arguments are optional. With no target, the current branch is used.


The job: find low-value comments, logging noise, and small code-hygiene issues in the lines a PR adds or changes, propose concrete before→after edits, and — unless `--propose-only` is set — apply the edits the user approves to the working tree. This command is narrow: it does **hygiene only**. Correctness, security, performance and design belong to a full code review, not here.

## Modes

Parse the arguments for the flag `--propose-only` (strip it before resolving the target):

- **Default (interactive)** — scan, present the triage table, ask which fixes to apply, then edit the working tree.
- **`--propose-only`** — scan and emit the **findings JSON array** (the format under "Output for `--propose-only`" below) and nothing else. No table, no questions, no edits. This is the mode for programmatic callers — a wrapper command, a script, a CI step — so keep the output a clean machine-readable array with no prose around it.

## Step 1 — Resolve the target and the diff

Parse the remaining target argument:

- **Empty** → current branch. Detect an associated PR with `gh pr view --json number,url,baseRefName,headRefName,headRefOid 2>/dev/null`.
- **PR URL or bare number** → a PR. `gh pr view <arg> --json number,url,baseRefName,headRefName,headRefOid`.
- **Branch name** → `gh pr list --head <arg> --json number,url,baseRefName,headRefName,headRefOid`. This returns a JSON **array** — read `.[0]`, not as an object. If empty, treat as a branch-only review.

Set the **diff base**: for a PR, `baseRefName`; otherwise the repository's default branch (`main` in most repos - substitute `master` or `develop` where that differs). Use the merge-base so unrelated upstream commits don't pollute the diff:

```bash
git fetch origin <base> --quiet
git --no-pager diff $(git merge-base HEAD origin/<base>)...HEAD
```

Capture the per-file unified diff. If the diff is empty, stop and say so.

## Step 2 — Scan added/changed lines only

Work **only on added lines** — the `+` hunks of the diff (and lines modified by the PR). Never flag pre-existing context lines; the PR is not responsible for them.

Be **language-aware** for comment and log syntax across the languages present in the diff (JS/TS, Java/Kotlin, Go, Python, shell, C#, SQL, YAML, etc.). Classify each added line against the checks below:

| # | Category | What to flag |
|---|----------|--------------|
| 1 | **Internal / planning refs** | Planning and process residue leaking into shipped code or comments: paths into design, spec or plan documents; internal wiki, tracker or chat URLs; agent and tooling chatter; conversational leftovers ("as discussed", "per the plan", "see my comment above"); and references to any directory or repository that is not part of the deployed artifact. The test: a reader outside this team, reading only the code, could not act on it. |
| 2 | **Debug / excessive logging** | Leftover debug prints — `console.log`/`console.debug`, `println`, `System.out.print*`, `fmt.Print*`, bare `print(...)`, `printf` used for tracing — added during development; commented-out log lines; obviously verbose trace spam. |
| 3 | **Obvious / redundant comments** | Comments that restate the code (`// increment i`, `// constructor`), auto-generated boilerplate comment stubs, docstrings that add no information beyond the signature, and inline comments that merely restate what the method's own Javadoc/docstring already says. Also **step narration** over self-explanatory code — `// 1. validate` / `// 2. save` walking through statements that already read clearly. In tests, a comment above assertions that restates the **test method's own name** (`// the v1 fields survive` above `assertEquals` blocks in `v1FieldsSurvive...`) is the same finding — the descriptive name and the assertion messages are the label; the comment must add what they cannot, or go. Inline comments are for the non-obvious; each one this PR adds should have to earn its place, and well-named code usually needs none. |
| 4 | **Dead code & noise** | Commented-out code blocks, `TODO`/`FIXME` **introduced by this PR**, scratch markers (`XXX`, `DEBUG`, `REMOVE ME`), and runs of 2+ consecutive blank lines added by the diff. |
| 5 | **FQN instead of import** (`fqn-instead-of-import`) | Fully-qualified type names used inline in code — `java.util.List<String>`, `com.foo.Bar.baz()` in Java/Kotlin, fully-qualified refs in C#/TS — in a language with an import system, where importing the type and using its simple name reads better *and* the simple name is collision-free. |
| 6 | **Decision / history narration** (`decision-narration`) | Comments that record a decision or change-history instead of explaining the code — "changed from X to Y", "was previously…", "per review / as agreed / decided to…", changelog-in-code. The substance belongs in the commit message, PR, or design doc, not the code. |
| 7 | **Verbose doc comments** (`verbose-doc`) | Javadoc/JSDoc/docstrings/XML-doc **added by this PR** whose summary runs past roughly two sentences into implementation narration, prose restatements of the parameter list, or multi-paragraph essays. A doc comment should open with one or two plain sentences saying what the thing does; detail belongs in the tags. The fix is always **tighten, never delete** — see the guardrail. |
| 8 | **Duplication & rot across doc surfaces** (`doc-duplication`) | The same fact stated in more than one doc surface of the same element — method doc comment restating an adjacent machine-read annotation's prose (`@Operation`/`@Schema` descriptions, OpenAPI summaries, assertion messages), or behavior described in method doc, annotation, *and* a type-level overview. The surface that **ships** (annotation, wire schema) is authoritative; the doc comment keeps only what the annotation cannot carry (rationale, cross-references, implementer warnings) or it goes. Also **counted claims** — "eleven controllers already page this way", "all twenty types live under v2" — where the number rots silently the day the next one lands: flag the count, keep the claim. |

### Guardrails — never propose removing these

- **License / copyright / SPDX headers** — leave untouched, always.
- **Pre-existing TODO/FIXME** — only flag TODO/FIXME that this PR's diff *adds*. If the marker predates the diff, ignore it.
- **Intentional logging** — leveled/structured logging (`logger.info` / `.warn` / `.error` / `.debug` through a real logger, structured event logs) is signal, not noise. Only flag *raw* debug prints (Check 2). When unsure whether a log is intentional, mark it **low confidence**, do not auto-apply it.
- **Test / example / fixture files** — `print`/`console.log`/`println` in test, spec, example, demo, or fixture files is frequently intentional (asserting output, illustrating usage). Mark any Check-2 print in such paths **low confidence** at most — never auto-apply.
- **Public-API doc comments (soft guard)** — Javadoc/JSDoc/docstrings/XML-doc on exported/public symbols are contracts. Flag one only when it is *clearly* redundant (pure restatement of the signature), and even then propose tightening over deletion. Never strip a doc comment that documents params, returns, throws, or behavior. For the Check-3 Javadoc-restatement case, the target is the *redundant inline comment that duplicates the doc*, not the authoritative doc comment — remove the restatement, leave the Javadoc/docstring.
- **Verbose doc comments are tightened, never deleted (Check 7)** — the only permitted fix is rewriting the prose down to one or two simple sentences. Every `@param`, `@return`, `@throws`, `@see`, `@deprecated` and equivalent tag survives verbatim, and so does any sentence carrying a constraint, gotcha, thread-safety note, or unit — length is the finding, information is not. Show the proposed short version as `before → after` so the author can judge what was dropped. Cap confidence at `medium`: brevity is a judgment call, so this is a **suggest**, never an auto-apply. A long doc comment that is dense with real contract detail is not a finding. The same tighten-never-delete rule covers **wire-facing annotation prose** (`@Schema`/`@Operation` descriptions): the annotation keeps a short consumer-facing summary and every constraint a consumer relies on; implementer-facing detail (aggregation rules, safety obligations, synthesis notes) moves to the doc comment, which does not ship. Never move a consumer-relevant constraint off the wire.
- **Required FQNs (Check 5)** — never flag a fully-qualified name that is *required*: a simple-name collision (two imported types share the same simple name), `{@link}`/doc-reference contexts where an FQN is conventional, reflection/string usage, generated code, or a file that deliberately uses FQNs as house style. The fix is two-part (replace the usage *and* add the import), so this is a **suggest**, never an auto-apply — cap confidence at `medium`, drop to `low` when a collision can't be ruled out. Word the `suggestion` as "add `import <FQN>` and use the simple name".
- **Duplication findings (Check 8)** are always **suggest**, capped at `medium` — deciding which copy is authoritative is a judgment call, and deleting the wrong copy can strip the only surface a given reader sees (IDE hover reads Javadoc; generated clients read annotations). Propose which copy survives and why.
- **Genuine WHY comments (Check 6)** — do **not** flag a comment that explains *why the current code is the way it is* (a constraint, gotcha, or non-obvious reason) — those are valuable and stay. Only flag *history / decision-event* narration (what the code used to be, when/why/who changed it, ticket/PR/review references). When a comment mixes rationale and history, propose trimming the history and keeping the rationale — do not delete the whole comment.

For each finding decide a **confidence**: `high` (safe to auto-apply — clear debug print, obvious comment, internal ref), `medium`, `low` (judgment call — surface but never auto-apply).

## Step 3 — Default mode: triage table

Present findings grouped by category, sorted high→low confidence:

A compact table: `# | Cat | Location (file:line) | Issue | Suggested edit`. Keep cells short. The "Suggested edit" is the concrete change — for a removal say `remove line`; for an edit show `before → after`.

Below the table, for any non-trivial edit, a one-line before/after block so the user sees exactly what changes.

Then use **`AskUserQuestion`** to offer: **apply all** / **apply high-confidence only** / **pick a subset by number** / **none**.

If the diff is empty or yields no findings, say so plainly and stop.

## Step 4 — Default mode: apply

Apply the chosen edits to the working tree with `Edit`. Re-read the current file content before editing — diff line numbers may not match the working tree exactly; match on the line's text, not its number. After applying, report a short summary: N edits applied across M files, by category. **Do not** commit, push, or stage — the author reviews the diff and commits separately. Never edit anything outside the repository under review.

## `--propose-only` mode: emit JSON

Skip Steps 3–4 entirely. Emit **only** this JSON array, one object per finding — no prose, no table, no questions, no edits. **When there are no findings (or the diff is empty), emit `[]`** — never prose; the caller parses this output.

```json
[{ "category": "internal-ref|debug-log|obvious-comment|dead-code|fqn-instead-of-import|decision-narration|verbose-doc|doc-duplication",
   "file": "path", "line": 0,
   "issue": "one-sentence description",
   "suggestion": "concrete before→after or 'remove line'",
   "confidence": "high|medium|low" }]
```

## Constraints

- Hygiene only — never report correctness, security, performance, or style-preference findings. Those belong to a full code review.
- Added/changed lines only. Never touch pre-existing lines.
- Honor every guardrail above. When a guardrail and a check disagree, the guardrail wins.
- No commit, no push, no staging. No edits outside the repository under review.
- Empty diff / no findings: default mode says so plainly and stops; `--propose-only` emits `[]`.
