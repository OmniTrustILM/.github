#!/usr/bin/env bash
# Pure helpers of the epic-scaffold action — no GitHub calls, so they can
# be exercised by scaffold.test.sh. Sourced by scaffold.sh.

# scaffold_wanted <issue type> <labels JSON array> <title>
# Prints "yes" when the issue is a product Epic that gets the standard
# tasks, otherwise the reason it is skipped. Tech epics and the release
# collectors (Bugs x.y.z, Closed bugs, Reported SaaS bugs) are skipped —
# they hold other issues' work and have no analysis or documentation of
# their own.
scaffold_wanted() {
  local type="$1" labels="$2" title="$3"
  if [ "$type" != "Epic" ]; then
    echo "not an Epic (type: ${type:-none})"
    return
  fi
  if printf '%s' "$labels" | jq -e 'index("tech-epic") != null' >/dev/null 2>&1; then
    echo "tech-epic"
    return
  fi
  if printf '%s' "$title" | grep -Eiq '^(Bugs|Closed bugs|Reported SaaS bugs|Documentation)\b'; then
    echo "release collector"
    return
  fi
  echo "yes"
}

# doc_title <epic title> — the documentation task's title.
doc_title() {
  printf 'Doc: %s' "$1"
}

# has_analysis_task <sub-issues JSON array of {title}> — "yes" when a
# sub-issue already is the analysis task (recognised by its title, as the
# dashboard and the triage skill recognise it).
has_analysis_task() {
  printf '%s' "$1" | jq -e '
    map(.title | ascii_downcase)
    | any(test("analys") and test("breakdown|estimat"))' >/dev/null 2>&1 \
    && echo "yes" || echo "no"
}

# has_doc_task <sub-issues JSON array of {title, labels}> — "yes" when a
# sub-issue already is a documentation task (label `documentation`, or a
# title starting with "Doc:").
has_doc_task() {
  printf '%s' "$1" | jq -e '
    any(
      ((.labels // []) | index("documentation") != null)
      or ((.title | ascii_downcase) | startswith("doc:"))
    )' >/dev/null 2>&1 \
    && echo "yes" || echo "no"
}

# analysis_body — the analysis task's body.
analysis_body() {
  cat <<'EOF'
### Description

Analysis, breakdown and estimates of the Epic (Methodics §2.5 Epic preparation): the Epic Owner works this task while the Epic is in **Analysis** — acceptance criteria, technical analysis, the breakdown into sub-issues (`/epic-breakdown` helps) and the estimates — and closes it when the analysis is complete (the automation moves it to Testing; QA or the Epic Owner moves it to Done). This task is the gate of the Epic's Status: the Epic stays in Planning / Analysis until the task is closed and can be Open only afterwards.

### Definition of Done

- [ ] Analyzed — acceptance criteria and technical analysis written into the Epic
- [ ] Broken down — the sub-issues exist (development, documentation, at least one testing task)
- [ ] Estimated — every sub-issue and the Epic carry an Estimate
EOF
}

# doc_body <epic repo owner/name> <epic number> <epic title> — the
# documentation task's body; the epic is named so that the task stays
# traceable when it is moved.
doc_body() {
  local repo="$1" number="$2" title="$3"
  cat <<EOF
### Description

Documentation for ${repo}#${number} (${title}). Placeholder owned by the Epic: the documentation scope is defined during the Epic's analysis; when several documentation tasks are needed, they are nested under this task.

### Documentation Type

Platform Documentation

### Related Feature

${repo}#${number}
EOF
}
