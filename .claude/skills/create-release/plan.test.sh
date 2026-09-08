#!/usr/bin/env bash
# Offline test suite for the create-release plan logic. Run by the Action
# tests workflow (every *.test.sh under .claude/skills/). No network, no gh.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PYTHON="$(command -v python3 || command -v python || true)"
[ -n "$PYTHON" ] || { echo "error: python3 (or python) not found on PATH" >&2; exit 1; }

exec "$PYTHON" "$SKILL_DIR/tests/test_plan.py"
