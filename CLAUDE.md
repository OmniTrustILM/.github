# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repository Is

This is the **OmniTrustILM `.github` repository** — the organization-wide default configuration repo for the OmniTrustILM GitHub organization. It contains no application code. Everything here is automatically inherited by all repos in the org unless overridden locally.

## Repository Purpose and Contents

- **Issue templates** (`.github/ISSUE_TEMPLATE/`): Bug, Feature, Epic, Release, Task, QA, Documentation, Vulnerability — each with structured YAML forms
- **Labels** (`templates/labels.yml`): Canonical label definitions synced to all org repos via the label-sync workflow
- **Label sync workflow** (`.github/workflows/label-sync.yml`): Uses a GitHub App token to push labels from `templates/labels.yml` to every non-archived repo in the org
- **Project triage rules** (`config/project-triage-rules.yml`): Staleness thresholds, required/recommended fields per issue type, and consistency rules consumed by external triage automation
- **Release notes template** (`templates/release.yml`): Auto-generated changelog categories mapped to labels; synced to `.github/release.yml` in every org repo by the release-yml-sync workflow
- **Release.yml sync workflow** (`.github/workflows/release-yml-sync.yml`): Manually-dispatched workflow that opens PRs in target repos to adopt the shared `templates/release.yml`
- **Renovate config** (`renovate.json`): Inherited dependency update settings
- **Community health files**: CONTRIBUTING.md, CODE_OF_CONDUCT.md, SECURITY.md, SUPPORT.md, FUNDING.yml
- **Org profile** (`profile/README.md`): Org landing page at github.com/OmniTrustILM — uses dark/light responsive logo from the `ilm` repo via raw GitHub URLs, curated key repos table, and links to docs/community

## Key Conventions

### Directory Layout

- `templates/` — files synced OUT to every org repo (labels, release notes config)
- `config/` — files consumed HERE or by external automation (triage rules)
- `.github/workflows/` — GitHub Actions workflows (required path)
- `.github/ISSUE_TEMPLATE/` — issue forms (required path)

### Issue Types and Their Constraints (from `config/project-triage-rules.yml`)
- **Bug**: requires `severity`. Recommended: module, priority, version, estimate, assignee.
- **Feature**: requires `acceptance_criteria`. Recommended: module, priority, version, estimate, assignee.
- **Epic**: requires `user_story`, `use_cases`, `acceptance_criteria`. Once past Planning status, also requires `complexity`, `estimate`, `start_date`, `end_date`. Epics without sub-issues or without a QA sub-issue are flagged.
- **Release**: requires `version`. Past Planning: requires `start_date`, `end_date`.

### Labels
Labels are the source of truth for release note categorization. The label set in `templates/labels.yml` is synced org-wide. When adding/changing labels, edit `templates/labels.yml` — the workflow propagates changes automatically on push to `main`.

### Commit Format
Imperative mood, capitalized, max 50-char summary, blank second line, optional body wrapped at 72 chars. Include a `Link:` line referencing the GitHub issue.

### Branching
GitHub flow — feature branches from `main`, merged back via pull requests.

### Versioning
Semantic Versioning (semver.org).

## Workflows

All CI workflows in this repo use a GitHub App (`ILM_PROJECT_BOT_APP_ID` / `ILM_PROJECT_BOT_PRIVATE_KEY` secrets) for authentication.

- **Label Sync** (`label-sync.yml`) — push to `main` on `templates/labels.yml` changes, or manual. Syncs labels to all non-archived org repos.
- **Release.yml Sync** (`release-yml-sync.yml`) — manual dispatch. Opens PRs in target repos to adopt `templates/release.yml`.

## External References

- Website: https://www.omnitrust.com
- Platform docs: https://docs.otilm.com
- Discussions: https://github.com/orgs/OmniTrustILM/discussions
- Contact: ilm@omnitrust.com
- Org name for API calls and authorization checks: `OmnitrustILM`
