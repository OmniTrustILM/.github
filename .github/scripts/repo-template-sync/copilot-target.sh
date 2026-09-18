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

# Reject unknown top-level keys, as render-codeowners.sh does for the same
# reason. A maintainer mirroring the CODEOWNERS lever writes `exclude:` here,
# gets no error and no effect, and the repo stays in scope still receiving the
# file.
while IFS= read -r key; do
  case "$key" in
    repos) ;;
    *) echo "copilot-target: unknown top-level key '$key' in $cfg" >&2; exit 2 ;;
  esac
done < <(yq 'keys | .[]' "$cfg")

# `repos: []` is the legitimate "everyone opted out" state and reaches the match
# below with no candidates. A bare `repos:` with no value parses as null and is
# indistinguishable from a truncated or half-saved file, so it errors rather
# than silently skipping every repo in the org.
kind=$(yq '.repos | tag' "$cfg")
case "$kind" in
  '!!seq') ;;
  '!!null') echo "copilot-target: repos has no entries; write 'repos: []' to opt every repo out" >&2; exit 2 ;;
  *) echo "copilot-target: repos must be a list, got $kind" >&2; exit 2 ;;
esac

# Entries must be plain repo names. `- name: core` parses cleanly, renders as
# text no repo name matches, and would skip that repo with no signal.
bad=$(yq '.repos[] | tag' "$cfg" | grep -v '^!!str$' || true)
[ -z "$bad" ] || { echo "copilot-target: repos entries must be plain repo names, got $bad" >&2; exit 2; }
# Counted, not rendered: an empty entry renders as an empty line, which command
# substitution strips, so the check would pass on exactly the input it guards.
blank=$(yq '[.repos[] | select(. == "")] | length' "$cfg")
[ "$blank" -eq 0 ] || { echo "copilot-target: repos contains an empty entry" >&2; exit 2; }

# Rendered to a variable rather than piped: under `set -o pipefail` a `grep -q`
# that exits on its first match can hand the pipeline yq's SIGPIPE status, and
# any mid-stream yq failure would read as "not in scope" - the silent skip the
# preflight above exists to prevent. grep -qxF, so a name carrying a regex or
# yq metacharacter is compared rather than interpreted.
listed=$(yq '.repos[]' "$cfg")
if grep -qxF -- "$repo" <<<"$listed"; then
  exit 0
fi
exit 3
