#!/usr/bin/env bash
# Render a repo's .github/CODEOWNERS from config/repo-domains.yml.
#
# Usage: render-codeowners.sh <repo-name> <path-to-repo-domains.yml>
# Prints the CODEOWNERS content to stdout.
# Exit 3 = repo is excluded (caller must skip, leaving any existing file
#          untouched). Any other non-zero = real error.
#
# Resolution order:
#   1. repo in `exclude`              -> exit 3 (skip)
#   2. repo in any domain core/ui/go/infra -> @OmniTrustILM/maintainers-<domain>
#      (a repo may match SEVERAL domains -> all those teams become owners)
#   3. repo in `qa`                   -> + @OmniTrustILM/qa
#   4. anything else (common repos)   -> @OmniTrustILM/maintainers (DEFAULT)
#
# All owners for `*` are emitted on ONE line. When several owners share a
# line, an approving review from ANY ONE of them satisfies the code-owner
# requirement (OR, not AND). They must share the SAME line because only the
# LAST matching pattern applies — separate `*` lines would drop all but the
# last team as owners.
set -euo pipefail

repo="${1:?repo name required}"
map="${2:?path to repo-domains.yml required}"

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/codeowners-sentinel.sh"

# Preflight: fail loudly rather than falling through to the default owner. If yq
# were missing or the map unparseable, every `yq -e` lookup below would return
# non-zero (read as "no match"), owners[] would stay empty, and EVERY repo would
# silently get the default owner — a wrong, org-wide ownership downgrade. Abort
# instead so the caller (sync-all/diff-all) surfaces the error.
command -v yq >/dev/null 2>&1 || { echo "render-codeowners: yq not found on PATH" >&2; exit 2; }
yq -e '.' "$map" >/dev/null 2>&1 || { echo "render-codeowners: cannot parse map: $map" >&2; exit 2; }

# Reject unknown top-level keys — a typo'd domain (e.g. `fe:` instead of `ui:`)
# would otherwise match nothing and silently fall through to the default owner.
while IFS= read -r key; do
  case "$key" in
    core|ui|go|infra|qa|exclude) ;;
    *) echo "render-codeowners: unknown top-level key '$key' in $map" >&2; exit 2 ;;
  esac
done < <(yq -r 'keys | .[]' "$map")

# 1. Excluded → signal skip (no `exclude` key defined today; harmless if absent).
if yq -e ".exclude[] | select(. == \"$repo\")" "$map" >/dev/null 2>&1; then
  exit 3
fi

owners=()

# 2. Domain team(s) — accumulate ALL matching domains (a repo may be in more
#    than one, e.g. proxy in core+go). Order core,ui,go,infra for stable output.
for d in core ui go infra; do
  if yq -e ".${d}[] | select(. == \"$repo\")" "$map" >/dev/null 2>&1; then
    owners+=("@OmniTrustILM/maintainers-$d")
  fi
done

# 3. QA-owned repos.
if yq -e ".qa[] | select(. == \"$repo\")" "$map" >/dev/null 2>&1; then
  owners+=("@OmniTrustILM/qa")
fi

# 4. Default owner for common / cross-cutting repos.
if [ "${#owners[@]}" -eq 0 ]; then
  owners+=("@OmniTrustILM/maintainers")
fi

echo "$CODEOWNERS_SENTINEL"
echo "# Owner = domain maintainer team (OmniTrustILM permissions model)."
echo "*  ${owners[*]}"
