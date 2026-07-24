---
name: connector-v3-design
version: 1.0.0
description: >
  Use when designing, implementing, or reviewing ANY OmniTrust ILM connector
  (Authority Provider and/or Discovery Provider) — a new connector for a
  CA/PKI/certificate/secrets backend, a connector design document, connector
  Go code, or a review of either. Authority Provider v3 is the CURRENT
  interface and it is STATELESS — no database, no persistent connector-side
  state — but only two v3 connectors exist, so models reliably drift into
  v2-shaped stateful designs (Postgres tables, authority CRUD, poll loops,
  dedup stores). Consult this skill BEFORE sketching any connector
  architecture, even when the request doesn't say "v3" — that is exactly
  when the drift happens.
tags:
  - connector
  - authority-provider
  - discovery-provider
  - ilm
  - go
permissions:
  - cli:gh:read
  - github:contents:read
inputs:
  - name: TARGET
    description: The backend being integrated (CA / PKI / secrets platform), if known.
    required: false
    example: "DigiCert CertCentral"
created_at: 2026-07-24
updated_at: 2026-07-24
---

# Skill: Connector v3 Design — stateless Authority Provider v3

## Why this skill exists

Authority Provider **v3** replaced v2's stateful model in 2026, and the
public ecosystem (docs, examples, most existing connectors) is still
v2-flavored — so a model asked to "design a connector" tends to reproduce
v2 patterns: a database with an `authority_instance` table, connector-side
polling loops with timeout attributes, dedup/inflight stores, `getCrl`
returning null. **All of these are wrong in v3.** Only two v3 connectors
exist as precedent; treat them (and the spec) as the source of truth, not
your priors.

The single load-bearing fact: **a v3 connector holds no persistent state of
any kind.** No SQL, no files, no embedded KV. Everything the connector needs
arrives inside every request; everything Core needs back travels in the
response. If a design includes a schema, a migration, or a "persist X" step,
it is a v2 design.

## Sources of truth (read before designing)

| Source | Where | Use it for |
|---|---|---|
| **AP v3 OpenAPI spec** | `OmniTrustILM/connector-factory` → `specs/_local-docs/authority-provider-v3.yaml` (OpenAPI 3.1). NOT on docs.otilm.com — the public site 404s for v3 | authoritative for paths + request DTOs (incl. which requests carry `meta`). Known gap: it omits the 200-response schemas for crl/caCertificates — the go-sdk generated models pin those |
| **go-sdk** | `OmniTrustILM/go-sdk` → `connector/provider/authority/v3/provider.go` (the 14-method `authority.Provider`), `connector/provider/discovery/v1/`, `connector/examples/disco-v1/store.go` | the Go contract, error types, the in-memory discovery store pattern |
| **dlm-connector** | `OmniTrustILM/dlm-connector` | the REST-backend template: repo layout, attribute registry, retryability classification, synchronous issue, 501/404 vocabulary for unsupported ops |
| **otpki-connector** | `OmniTrustILM/otpki-connector` | the async template: 202 + meta handles, one-read-per-status-call, per-authority client cache (in-memory LRU), register implemented |

Java interface contracts also live in `OmniTrustILM/interfaces` (package
`...connector/v3/`), but for Go work the go-sdk is the contract.

For code-verified details of every pattern below (file references, verified
quotes, DTO field lists), read `references/v3-patterns.md` in this skill.

## The stateless laws

1. **No persistence.** Neither reference connector has a database, KV store,
   or file-writing code. The only in-process state allowed: an in-memory
   discovery store (see law 8) and an optional client/token cache that is
   purely a latency optimization — safe to lose at any moment.
2. **Credentials arrive in every request.** There is no "create authority"
   CRUD — `POST /v3/authorityProvider/authorities` is a stateless
   *connection check* (probe the backend, return 204 or
   `ErrConnectionFailed` → 503, persist nothing). API keys/tokens are
   `resource` attributes referencing an ILM Secret; Core dereferences and
   inlines them into `authorityAttributes` on each call. Extract by UUID,
   validate strictly (422 on missing/duplicate/mixed-version), never store
   or log the secret. Scope Core's secret picker with a filter-only
   callback (`SECRET_TYPE EQUALS <type>`).
3. **Issue/renew return 200 or 202+meta — never block-and-poll.** The go-sdk
   contract is `Issue(ctx, req) (resp, accepted bool, err)`: sync result →
   `(resp, false, nil)` = 200 with the certificate; async → `(resp, true,
   nil)` = 202 where `resp.Meta` carries the tracking handle (plain string
   META attributes, e.g. the backend's order/request id). At most one
   immediate upstream status read before deciding — never a loop, an
   interval, or a timeout attribute. **Core owns polling cadence and
   timeouts.** (Sync `Revoke` success is a bare 204: `(nil, false, nil)`.)
4. **Status = one upstream read per call.** `IssueStatus`/`RevokeStatus`/
   `RegisterStatus` read the handle from `req.Meta` (missing → 422), rebuild
   the client from `req.AuthorityAttributes`, perform exactly one backend
   read, map to inProgress/completed/failed. Put the backend's own state
   into the progress message — that is how users see "waiting for approval /
   domain validation". Unknown backend states fail fast, never poll-to-timeout.
5. **No dedup machinery.** No inflight/idempotency store exists in any v3
   connector. The substitute is the retryability contract: mutating calls
   run **exactly once** (never internally retried); once a mutating call may
   have reached the backend, mark every outward failure **non-retryable** so
   Core will not re-drive it; pre-transmission failures (dial/TLS) stay
   retryable (503). Reads may retry internally with bounded backoff.
6. **Authority-level ops receive NO meta.** `CrlRequestDtoV3` and
   `CaCertificatesRequestDtoV3` carry only `authorityAttributes` +
   `raProfileAttributes` (+ a `delta` bool on CRL). A design that feeds
   certificate meta (a remembered "last issued cert", a stored CRL URL) into
   getCrl/getCaCertificates is structurally impossible — derive everything
   live from attribute-selected context, or return 501. The CRL response
   field (`crl`, base64 DER) is **required**: "return null" is spec-invalid;
   the honest alternatives are a live fetch or `OPERATION_NOT_SUPPORTED`.
7. **Unsupported ≠ absent.** All 14 provider methods are implemented; the
   vocabulary for saying no: **501** `OPERATION_NOT_SUPPORTED` (never
   supported), **404** for missing async handles — as go-sdk
   `ErrOperationNotFound` (`OPERATION_NOT_FOUND`: an async-capable connector
   got an unknown/expired handle) or `OPERATION_NOT_TRACKED` (a wholly
   synchronous connector: nothing is ever tracked — the dlm answer for all
   its status/cancel methods) — and **422** `ErrCancelRefused` (past the
   point of no return). The `…/attributes` endpoints of unsupported
   operations still return `200 []`. Register = pre-create a certificate
   identity at the CA **without a CSR** (a later issue references it via
   meta) — implement it only if the backend has such a concept; otherwise
   501/404 per the above. Advertise feature flags honestly: `stateless`
   always; `certificateRegistration` only if register is actually
   implemented.
8. **Discovery state is in-memory and loss is accepted.** Discovery
   Provider v1: `DiscoverCertificate` may run synchronously or return
   `inProgress` (a goroutine fills the store); `GetDiscovery(uuid, req)`
   pages results out of a `sync.RWMutex`-guarded map keyed by a
   server-generated discovery uuid (go-sdk `examples/disco-v1/store.go`);
   `DeleteDiscovery` drops the entry. Restart loses in-flight discoveries →
   Core gets 404 (`ErrDiscoveryNotFound`); re-running the discovery is
   Core's/the operator's job (an inference, not code-verified — see
   references §6). Do not "fix" this with a table. Note: discovery v1 uses
   the v1 error shape (`shared.WriteV1Error`), not RFC 9457 problem+json.
9. **Attribute names + UUIDs are frozen forever.** Core matches definitions
   by UUID across connector versions. Keep a const registry, fail-fast on
   duplicates at startup, and when an attribute dies, move its UUID to a
   "retired — never reuse" ledger instead of deleting it silently.

## v2 traps → v3 replacements

Run this table over any design you produce or review; each left-column item
is an automatic red flag:

| v2-shaped element | v3 replacement |
|---|---|
| PostgreSQL / any DB, Flyway/JPA, schema section | delete — state model is "none" (+ in-memory discovery map) |
| `authority_instance` row, "persist on create" | connection check only; attributes replayed by Core per request |
| inflight/dedup/idempotency table, request-hash resume | retryability contract (law 5); Core owns re-drives |
| connector-side poll loop, `*_timeoutHours` attribute | 202 + meta handle; Core polls `…/status` (laws 3–4) |
| `getCrl` → `crlData: null` | live CRL fetch (base64 DER) or 501 — null is spec-invalid |
| meta consumed by authority-level ops | impossible — no meta field on those requests (law 6) |
| callbacks/attribute lists pre-baked at startup from stored creds | attribute callbacks executed per request from request attributes |
| Java/Spring framing, `spiVersion: v2` controllers | Go + go-sdk, single binary, dlm-connector layout |
| silent removal of an operation | typed 501/404/422 vocabulary (law 7) |

## Repo layout (dlm-connector is the template)

```
cmd/<name>-connector/      main.go (env config, slog, tracing) +
                           connector.go (wire client + attr registry +
                           provider into go-sdk shared.Connector; /v2/info)
internal/
  attr/                    frozen name+UUID consts, schema builders,
                           extraction (by UUID → 422), meta builders
  callback/                attribute-callback dispatcher (option lists,
                           secret-picker filter)
  <backend>/               backend HTTP client; typed errors WITH
                           retryability classification; <backend>test/
                           fixture server
  problem/                 RFC 9457 problem+json (retryable /
                           retryAfterSeconds extensions)
  provider/                authority.Provider impl + unsupported.go
  config/ logging/ tlstrust/ tracing/ version/
test/                      harness + integration
```

## Design self-check (before presenting anything)

- [ ] Zero persistence anywhere? (grep your own design for "table",
      "persist", "database", "migration")
- [ ] Every operation's inputs limited to what its v3 request DTO actually
      carries? (check the yaml — especially crl/caCertificates)
- [ ] Issue/renew async path returns 202 + meta, no loop, no timeout attr?
- [ ] Status ops = one backend read; backend state → progress message?
- [ ] Mutating calls exactly-once + non-retryable-after-mutation?
- [ ] Unsupported ops answered with 501/404/422, attributes with `200 []`?
- [ ] Attribute UUIDs frozen, retired ones ledgered?
- [ ] Discovery (if implemented) in-memory with restart-loss accepted?
- [ ] Cited the spec yaml + go-sdk + a reference connector for each
      contract claim, not memory?

When any box is unclear, read `references/v3-patterns.md` — it contains the
code-verified detail (exact DTO fields, verified quotes, file paths) for
every law above.
