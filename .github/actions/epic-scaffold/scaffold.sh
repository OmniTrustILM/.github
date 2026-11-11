#!/usr/bin/env bash
# When a product Epic is opened, create its two standard sub-issues
# (RM rule 2026-10-23, Methodics §1 Epic anatomy and §2.5 Epic preparation):
#   - "Analysis, breakdown, estimations" — a Task in the Epic's own repo
#   - "Doc: <Epic title>"                 — a Task with the `documentation`
#                                           label in the documentation repo
# Both are born as sub-issues of the Epic (createIssue parentIssueId), so
# the version-propagation action running on their own `opened` event copies
# the Epic's Version and Module. Both get the Epic's assignees (the Epic
# Owner). Idempotent: a task that already exists under the Epic is not
# created again. Tech epics and the release collectors are skipped.
#
# Reads: GH_TOKEN, ISSUE_URL, ISSUE_NODE_ID, ISSUE_NUMBER, ISSUE_TITLE,
#        ISSUE_TYPE, ISSUE_LABELS (JSON), ISSUE_ASSIGNEE_IDS (JSON),
#        ISSUE_REPO (owner/name), DOC_REPO (owner/name), ANALYSIS_TITLE
set -euo pipefail

# shellcheck source=scaffold-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/scaffold-lib.sh"

echo "Issue: $ISSUE_URL"

wanted="$(scaffold_wanted "$ISSUE_TYPE" "$ISSUE_LABELS" "$ISSUE_TITLE")"
if [ "$wanted" != "yes" ]; then
  echo "Skipped: $wanted."
  exit 0
fi

# The Epic's current sub-issues — the idempotency guard.
SUBS=$(gh api graphql -f query='
  query($id: ID!) {
    node(id: $id) {
      ... on Issue {
        subIssues(first: 100) {
          nodes { title labels(first: 20) { nodes { name } } }
        }
      }
    }
  }' -f id="$ISSUE_NODE_ID" \
  --jq '[.data.node.subIssues.nodes[] | {title, labels: [.labels.nodes[].name]}]')

# repo_ids <owner/name> — "<repository id> <Task issue type id>" of a repo.
repo_ids() {
  local owner="${1%%/*}" name="${1##*/}"
  gh api graphql -f query='
    query($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) {
        id
        issueTypes(first: 20) { nodes { id name } }
      }
    }' -f owner="$owner" -f name="$name" \
    --jq '.data.repository | "\(.id) \((.issueTypes.nodes[] | select(.name == "Task") | .id) // "")"'
}

# label_id <owner/name> <label> — the label's id, empty when the repo lacks it.
label_id() {
  local owner="${1%%/*}" name="${1##*/}"
  gh api graphql -f query='
    query($owner: String!, $name: String!, $label: String!) {
      repository(owner: $owner, name: $name) { label(name: $label) { id } }
    }' -f owner="$owner" -f name="$name" -f label="$2" \
    --jq '.data.repository.label.id // empty'
}

# create_task <repository id> <type id> <title> <body> <label id or empty>
# Creates the Task as a sub-issue of the Epic with the Epic's assignees and
# prints its URL.
create_task() {
  local repo_id="$1" type_id="$2" title="$3" body="$4" label="$5"
  local labels='[]'
  [ -n "$label" ] && labels="$(jq -cn --arg l "$label" '[$l]')"
  gh api graphql \
    -f query='
      mutation($input: CreateIssueInput!) {
        createIssue(input: $input) { issue { url } }
      }' \
    --input <(jq -cn \
      --arg repo "$repo_id" --arg type "$type_id" --arg title "$title" \
      --arg body "$body" --arg parent "$ISSUE_NODE_ID" \
      --argjson labels "$labels" --argjson assignees "$ISSUE_ASSIGNEE_IDS" \
      '{query: $ARGS.named.query, variables: {input: ({
          repositoryId: $repo, title: $title, body: $body, parentIssueId: $parent,
          labelIds: $labels, assigneeIds: $assignees}
          + (if $type == "" then {} else {issueTypeId: $type} end))}}' \
      --arg query '
      mutation($input: CreateIssueInput!) {
        createIssue(input: $input) { issue { url } }
      }') \
    --jq '.data.createIssue.issue.url'
}

created=()

if [ "$(has_analysis_task "$SUBS")" = "yes" ]; then
  echo "Analysis task already present."
else
  read -r repo_id type_id <<<"$(repo_ids "$ISSUE_REPO")"
  [ -z "$type_id" ] && echo "::warning::Repository $ISSUE_REPO has no Task issue type; creating without a type."
  url="$(create_task "$repo_id" "$type_id" "$ANALYSIS_TITLE" "$(analysis_body)" "")"
  echo "Created analysis task: $url"
  created+=("$url")
fi

if [ "$(has_doc_task "$SUBS")" = "yes" ]; then
  echo "Documentation task already present."
else
  read -r repo_id type_id <<<"$(repo_ids "$DOC_REPO")"
  [ -z "$type_id" ] && echo "::warning::Repository $DOC_REPO has no Task issue type; creating without a type."
  label="$(label_id "$DOC_REPO" documentation)"
  [ -z "$label" ] && echo "::warning::Repository $DOC_REPO has no 'documentation' label; creating without it."
  url="$(create_task "$repo_id" "$type_id" "$(doc_title "$ISSUE_TITLE")" \
        "$(doc_body "$ISSUE_REPO" "$ISSUE_NUMBER" "$ISSUE_TITLE")" "$label")"
  echo "Created documentation task: $url"
  created+=("$url")
fi

if [ "${#created[@]}" -gt 0 ] && [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### Epic scaffold — $ISSUE_URL"
    for u in "${created[@]}"; do echo "- $u"; done
  } >> "$GITHUB_STEP_SUMMARY"
fi
