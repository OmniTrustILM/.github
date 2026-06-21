# epic-breakdown lessons

Curated, human-readable notes the skill reads at the start of every run and
applies when relevant. This is the skill's only "memory" — explicit and
reviewable, not opaque state.

**How entries are added:** when a user corrects the skill during an edit loop,
the skill *offers* to append a one-line lesson here and only writes it after the
user approves. Never auto-write. Keep each entry one line, factual, and tied to a
concrete signal (a Module, a repo, an existing issue, a decision rule).

## Module / repo mapping

- Machine-certificate enrollment / Kerberos-authenticated API issuance → **Auth**
  module (`auth`, `auth-opa-policies`, `keycloak-theme`) **plus core** for the
  RA-profile / request-attribute path. Existing precedents: #131 "Custom
  certificate request attributes" (RDN/SAN/regex on the profile), #145
  "Dedicated authentication stack for TSP protocol" (per-endpoint auth method).
- A **device-side agent** has no home in the current Module map (the "Agent"
  module is the MCP/AI server, not a device agent) → treat "build a local agent"
  as a **scope signal / new-component decision**, not a sub-task.

## Decomposition

- Every Epic needs a **Task+qa** child and a **Task+documentation** child, or
  §7.2 triage flags it and testing/docs get forgotten.
- If a proposed Feature under an Epic would itself need sub-issues, the Epic is
  too large (§1) — propose splitting the Epic instead of nesting Features.
