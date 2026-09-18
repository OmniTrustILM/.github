#!/usr/bin/env bash
# Decide whether a repo receives the Copilot review instructions.
#
# Usage: copilot-target.sh <repo-name> <path-to-copilot-repos.yml>
# Exit 0 = in scope, 3 = not in scope (caller skips), 2 = real error.
#
# Separate from the sync scripts so the gate can be tested on its own: this is
# the only thing standing between a `target_repos: all` dispatch and Copilot
# instructions landing in every repo in the organisation.
set -euo pipefail

repo="${1:?repo name required}"
cfg="${2:?path to copilot-repos.yml required}"

# Preflight rather than fall through. Without yq, or with an unparseable file,
# every membership test below would return non-zero and read as "not in scope" -
# so a broken config would silently stop the sync for every repo instead of
# failing the run.
command -v yq >/dev/null 2>&1 || { echo "copilot-target: yq not found on PATH" >&2; exit 2; }
yq -e '.' "$cfg" >/dev/null 2>&1 || { echo "copilot-target: cannot parse $cfg" >&2; exit 2; }
yq -e 'has("repos")' "$cfg" >/dev/null 2>&1 || { echo "copilot-target: $cfg has no repos key" >&2; exit 2; }

# An empty list is a legitimate state (every repo opted out), but an empty
# *scalar* where a list belongs is a typo that would otherwise match nothing.
kind=$(yq '.repos | tag' "$cfg")
case "$kind" in
  '!!seq') ;;
  '!!null') exit 3 ;;
  *) echo "copilot-target: repos must be a list, got $kind" >&2; exit 2 ;;
esac

# grep -qx over the rendered list rather than a yq expression with an
# interpolated repo name: a name containing a yq metacharacter would otherwise
# change the expression instead of being compared.
if yq '.repos[]' "$cfg" | grep -qxF -- "$repo"; then
  exit 0
fi
exit 3
