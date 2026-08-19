#!/usr/bin/env bash
# Shared marker: the first line of every CODEOWNERS this sync generates.
# render-codeowners.sh emits it; sync-all.sh and diff-all.sh match line 1 on it
# to tell a sync-managed file from a hand-curated one. Sourced by all three
# (and render-codeowners.test.sh) so the string lives in exactly one place —
# reword it here and producer, both guards, and the test stay in lockstep.
# shellcheck disable=SC2034  # sourced by sibling scripts; not used in this file
CODEOWNERS_SENTINEL="# Synced by repo-template-sync — do not edit by hand."
