---
name: session-protocol
version: 1.0.0
description: >
  Use when starting or resuming implementation work in Claude Code - to scope
  the session to one stage of the work (design, one plan phase, ship, or PR
  feedback), keep the main context small, delegate verbose work to subagents,
  and end the session with a handoff note instead of carrying the conversation
  forward. Keeps usage and context size bounded on long-running work without
  lowering the quality gates.
tags:
  - claude-code
  - workflow
  - ilm
inputs:
  - name: STAGE
    description: One of design, execute, ship, feedback.
    required: true
    example: "execute"
  - name: TARGET
    description: >
      An issue for design, a plan file and phase for execute, a branch for
      ship, a PR number for feedback.
    required: false
    example: "plans/managed-keycloak.md phase 2"
permissions:
  - cli:gh:read
  - cli:git:read
  - local:files:write
created_at: 2026-11-10
updated_at: 2026-11-10
---

# Skill: Session Protocol

Run one stage of the work per session. The plan file carries state between sessions; the conversation does not. Every request re-sends the whole conversation, so a session that spans several phases pays for all earlier phases on every turn.

## Invocation

```
/session-protocol design   [issue]
/session-protocol execute  <plan file> <phase>
/session-protocol ship     [branch]
/session-protocol feedback <PR number>
```

## Rules for every stage

- Do the named stage only. When it is done, say so and stop; the author starts the next stage in a fresh session.
- Read the plan and the handoff notes first. Do not re-explore what they already answer.
- Ask open questions before starting work, in one batch.
- Run tests, scanners, builds and other verbose commands in a subagent that returns failures only.
- Do not change model or effort inside the session. Delegate instead.
- If the session has to continue past its stage, say why before continuing.

## Stage: design

1. Clarify the requirement with the author.
2. Write the plan to a local, gitignored plan file, split into phases.
3. Give each phase its scope, the files it is expected to touch, and its gates.
4. Stop when the author accepts the plan.

A phase is sized to finish in one session: one coherent change that can be verified on its own.

## Stage: execute

1. Read the plan, the named phase and any handoff notes from earlier phases.
2. Implement the phase through subagents, one task at a time.
3. Check each task against the plan once. Leave code review to the ship stage.
4. Run the phase gates. Fix failures; escalate a task to the main model only after a subagent attempt fails a gate.
5. Append a handoff note to the plan, at most five lines: what was done, what deviated from the plan, what the next phase must know.
6. Stop.

## Stage: ship

1. Run one independent review on the branch diff together with the uncommitted changes, and fix the valid findings.
2. Run `/pr-hygiene` on the branch and `/pr-hygiene --worktree` on the uncommitted changes.
3. Run the repository quality gates on the whole branch after all edits: tests and coverage, duplication, static analysis. Fix failures and re-run until they pass.
4. Prepare the commit and the PR description.
5. Wait for the author's approval before any push or pull request.

## Stage: feedback

1. Fetch open review comments and new static-analysis issues for the PR with `gh`.
2. Fix the valid ones.
3. Run the repository quality gates on the changed code. Fix failures and re-run until they pass.
4. Commit the fixes as follow-up commits.
5. List what was skipped and why. Nitpicks that only add code or reduce readability are skipped.
6. Wait for the author's approval before pushing.

## Constraints

- One stage per session. No push and no pull request without the author's approval.
- Code edits follow the plan the author accepted in the design stage; that acceptance is their preview. Show each commit message and wait for the author's confirmation before committing.
- Plan files and handoff notes stay local and are never committed or referenced from code.
- This skill sets the working order only. Quality thresholds come from the repository and the author's own rules.
