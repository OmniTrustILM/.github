# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repository Is

This is the **OmniTrustILM `.github` repository** — the organization-wide default configuration repo for the OmniTrustILM GitHub organization. It contains no application code. Everything here is automatically inherited by all repos in the org unless overridden locally.

## Repository Purpose and Contents

- **Issue templates** (`.github/ISSUE_TEMPLATE/`): Bug, Feature, Epic, Release, Task, QA, Documentation, Vulnerability — each with structured YAML forms
- **Labels** (`labels.yml`): Canonical label definitions synced to all org repos via the label-sync workflow
- **Label sync workflow** (`.github/workflows/label-sync.yml`): Uses a GitHub App token to push labels from `labels.yml` to every non-archived repo in the org
- **Project triage rules** (`project-triage-rules.yml`): Staleness thresholds, required/recommended fields per issue type, and consistency rules consumed by external triage automation
- **Release notes config** (`release.yml`): Auto-generated changelog categories mapped to labels
- **Renovate config** (`renovate.json`): Inherited dependency update settings
- **Community health files**: CONTRIBUTING.md, CODE_OF_CONDUCT.md, SECURITY.md, SUPPORT.md, FUNDING.yml
- **Org profile** (`profile/README.md`): Org landing page at github.com/OmniTrustILM — uses dark/light responsive logo from the `ilm` repo via raw GitHub URLs, curated key repos table, and links to docs/community

## Key Conventions

### Issue Types and Their Constraints (from `project-triage-rules.yml`)
- **Bug**: requires `severity`. Recommended: module, priority, version, estimate, assignee.
- **Feature**: requires `acceptance_criteria`. Recommended: module, priority, version, estimate, assignee.
- **Epic**: requires `user_story`, `use_cases`, `acceptance_criteria`. Once past Planning status, also requires `complexity`, `estimate`, `start_date`, `end_date`. Epics without sub-issues or without a QA sub-issue are flagged.
- **Release**: requires `version`. Past Planning: requires `start_date`, `end_date`.

### Labels
Labels are the source of truth for release note categorization. The label set in `labels.yml` is synced org-wide. When adding/changing labels, edit `labels.yml` — the workflow propagates changes automatically on push to `main`.

### Commit Format
Imperative mood, capitalized, max 50-char summary, blank second line, optional body wrapped at 72 chars. Include a `Link:` line referencing the GitHub issue.

### Branching
GitHub flow — feature branches from `main`, merged back via pull requests.

### Versioning
Semantic Versioning (semver.org).

## Workflow: Label Sync

The only CI workflow in this repo. Triggered on push to `main` when `labels.yml` changes, or manually via `workflow_dispatch`. Uses a GitHub App (`ILM_PROJECT_BOT_APP_ID` / `ILM_PROJECT_BOT_PRIVATE_KEY` secrets) to authenticate and sync labels across all org repos.

## External References

- Website: https://www.omnitrust.com
- Platform docs: https://docs.otilm.com
- Discussions: https://github.com/orgs/OmniTrustILM/discussions
- Contact: ilm@omnitrust.com
- Org name for API calls and authorization checks: `OmnitrustILM`
