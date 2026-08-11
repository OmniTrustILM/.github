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
- The network-scanning discovery connector repo is **`ip-discovery-provider`**
  (siblings: `cryptosense-`, `ct-logs-`, `php-api-discovery-provider`); there is
  no `network-discovery-provider` → validate every previewed repo name against
  `cache/repos.json` *before* the confirm gate, not at creation time (a bad name
  fails mid-sequence and forces a resume).
- Core's **FE-facing** web controller interfaces and client DTOs live in the
  `interfaces` repo (`com.otilm.api.interfaces.core.web`), not in `core` → an
  Epic touching Core's REST surface needs an `interfaces` child for the
  definitions plus a `core` child for the implementation.
- New **access-control actions need no `auth`/`auth-opa-policies` child**:
  `ResourceAction` additions (in `interfaces`) plus Core annotations are synced
  to the auth service by `AuthResourceSynchronizer.register()` at startup.

## Decomposition

- Every Epic needs a **Task+qa** child and a **Task+documentation** child, or
  §7.2 triage flags it and testing/docs get forgotten.
- If a proposed Feature under an Epic would itself need sub-issues, the Epic is
  too large (§1) — propose splitting the Epic instead of nesting Features.
- Split a child when its PR would exceed ~2000 LoC **and** a repo-internal
  audience seam exists (e.g. connector-facing contract vs core-web API in
  `interfaces`); merge sequential half-day migrations in one repo instead of
  filing them separately.
- Estimate basis (agent-executed by default, per-child compression factors, Epic
  `Estimate Basis` section, no estimates in child bodies) is specified in
  **§3.5** — follow the methodics, do not re-derive it here.

## Content hygiene

- Keep GitHub-bound bodies **ASCII-safe** (`-` not `—`, `->` not `→`). Even with
  `enrich-epic.sh` exporting `PYTHONIOENCODING=utf-8`, any other tool piping a
  body through a cp1252 stdio on Windows silently writes `U+FFFD`, and a body
  already corrupted that way has to be rewritten by hand.
