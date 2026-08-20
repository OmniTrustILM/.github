# shellcheck shell=bash
# Shared helpers for the pr-agent-review action. SOURCE this; do not run it.

# Logs go to stderr because several scripts here return data on stdout, and a
# stray log line would end up parsed as that data.
log() { printf 'pr-agent-review: %s\n' "$*" >&2; }
die() { log "$*"; exit 1; }

set_output() { printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"; }

# fingerprint FILE CATEGORY WHAT
# Stable identity for a finding across runs of this reviewer.
#
# Computed here rather than asked of the model: an LLM cannot compute a hash,
# and would emit six plausible hex characters that satisfy the pattern and mean
# nothing - which silently breaks suppression, dedup and carry-over while
# looking like it works.
#
# The line number is deliberately not an input. A finding keeps its identity
# when the code around it moves, which is exactly what a re-review needs.
#
# SHA-256 rather than SHA-1. The use is not cryptographic - this is a dedup key,
# and truncating either to six hex characters gives the same collision odds - but
# there is no reason to reach for a broken primitive, and this repository's own
# review prompts tell the agent to flag exactly that on a PKI platform.
fingerprint() {
  local file="$1" category="$2" what="$3" norm
  norm=$(printf '%s' "$what" | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ' \
         | sed 's/^ //; s/ $//')
  printf '%s|%s|%s' "$file" "$category" "$norm" | sha256sum | cut -c1-6
}
