# How a stateless Authority Provider v3 connector is actually built

Ingest digest, 2026-07-24. Sources read directly from GitHub (`gh api` /
shallow clones at HEAD):

- `OmniTrustILM/otpki-connector` (Go, AP v3, Connect-RPC backend)
- `OmniTrustILM/dlm-connector` (Go, AP v3, REST backend — closest analog to
  DigiCert CertCentral)
- `OmniTrustILM/go-sdk` — the connector framework both use
  (`connector/provider/authority/v3`, `connector/provider/discovery/v1`,
  `connector/examples/disco-v1`)
- `OmniTrustILM/connector-factory:specs/_local-docs/authority-provider-v3.yaml`
  (OpenAPI 3.1, 3529 lines)

Structured in nine sections, with a worked example at the end. File references are `repo:path`.

---

## 1. Persistence: none. Verified.

Full `require` blocks of both go.mod files inspected
(`otpki-connector:go.mod`, `dlm-connector:go.mod`):

- **No** `database/sql`, gorm, sqlite, bbolt, badger, redis, pgx, boltdb —
  nothing persistence-shaped, direct or indirect.
- dlm-connector's direct deps are essentially: go-sdk, testify,
  testcontainers + moby/moby/api (test infra only), otel. otpki adds
  connectrpc, protobuf, go-ldap, uuid, and `hashicorp/golang-lru/v2` — which
  is an **in-memory** expirable LRU used as a per-authority HTTP-client/token
  cache (see Q2), not persistence.
- `grep` over all production Go code in both repos for
  `database/sql|gorm|sqlite|bbolt|badger|redis|pgx|os.WriteFile|os.Create|os.OpenFile`:
  **zero matches**. No on-disk state of any kind. The only "state" either
  process holds is the LRU transport cache and it is explicitly safe to lose.

The dlm provider package doc says it outright
(`dlm-connector:internal/provider/provider.go`):

> v3 is stateless (spec §6/§8): every operation carries its authority and
> RA-profile identity as request attributes, so Provider itself holds no
> per-authority state — only the shared DLM client, the attribute registry,
> the callback dispatcher, and a logger.

Both connectors advertise the `stateless` feature flag on their /v2/info
authority interface entry: dlm exactly `Features: ["stateless"]`
(`dlm-connector:cmd/dlm-connector/connector.go`
`authorityRegistrable.Interface()`); otpki
`["stateless", "certificateRegistration"]` because it implements Register
(`otpki-connector:cmd/otpki-connector/connector.go`; typed FeatureFlag enum
in go-sdk). A connector that rejects register advertises
`["stateless"]` only.

## 2. Stateless request model: credentials parsed from EVERY request

Every v3 request DTO carries `authorityAttributes` + `raProfileAttributes`
(required in every schema in authority-provider-v3.yaml). Handlers begin by
extracting the backend connection from them; nothing is looked up by uuid.

**dlm pattern** (`dlm-connector:internal/attr/extract.go`): pure functions
over `[]mdl.RequestAttribute`:

```go
func (p *Provider) Issue(ctx, req *mdl.CertificateSignRequestDtoV3) (...) {
    conn, err := attr.AuthorityConn(req.AuthorityAttributes) // base URL + JWT
    vals, err := attr.RAProfile(req.RaProfileAttributes)     // group/keyspace/profile/ACL
    ...
}
```

`AuthorityConn` resolves `data_baseUrl` (string content, re-validated
server-side via `dlm.ParseBaseURL`) and `data_jwtSecret` — a **resource
attribute** whose content must be `ResourceObjectContent → 
ResourceSecretContentData → JwtTokenSecretContent`; Core dereferences the
Secret and inlines the token into the request, the connector never stores it.
Extraction is by **UUID, not name** (`requireSingleV3`: exactly one
occurrence, v3 schema version enforced, exactly one content item, violations
→ 422 VALIDATION_FAILED).

**otpki pattern** (`otpki-connector:internal/otpki/factory.go`): a
`Factory.Build(ctx, req.AuthorityAttributes)` call at the top of every
handler builds (or fetches from an in-memory expirable LRU, 64 entries / 1h
TTL, keyed by a composite of the resolved connection fields — base URL, token
URL, client id, sha256-prefix of the secret, plus scope/audience/TLS-trust/
deadline tuning) a
client bundle: OAuth2 client-credentials token flow, per-authority TLS trust
overlay, per-authority deadline/retry tuning — all of it **from the request
attributes**. Cache eviction/restart is harmless: the next request rebuilds
the entry and re-acquires a token. The cache is a latency optimization
(avoids a token round-trip per request), never a source of truth.

The same extraction runs even on attribute-listing endpoints:
`RAProfileAttributes(ctx, authorityAttrs)` validates/uses the authority
attributes Core passes as context
(`dlm-connector:internal/provider/attributes.go`,
`otpki-connector:internal/provider/authority.go` — otpki even calls the
backend there to populate cascading options).

## 3. Async issue lifecycle: `(resp, accepted bool, err)` — meta is the whole tracking handle

The go-sdk contract (`go-sdk:connector/provider/authority/v3/provider.go`):

```go
Issue(ctx, req) (resp *CertificateDataResponseDtoV3, accepted bool, err error)
```

- `(resp, false, nil)` → **200** with `resp.CertificateData` (base64 DER).
- `(resp, true, nil)` → **202**; `resp.Meta` MUST carry the tracking handle
  "Core replays on IssueStatus / CancelIssue". Spec confirms:
  `CertificateDataResponseDto.meta` — "Present on async 202 as the tracking
  handle Core replays on subsequent /status and /cancel calls; optional on
  200 responses" (authority-provider-v3.yaml).

**dlm issues synchronously — explicitly.** Its whole pipeline (import CSR →
submit → approve → download) runs inline within a 100s operation deadline and
returns `(resp, false, nil)` (`dlm-connector:internal/provider/issue.go`).
Its `IssueStatus`/`CancelIssue` (and all six status/cancel methods) return
`problem.CodeOperationNotTracked` → 404: "DLM operations are synchronous;
there is no tracked async operation"
(`dlm-connector:internal/provider/unsupported.go`). Sync + meta on 200 is a
legitimate v3 shape.

**otpki does both** (`otpki-connector:internal/provider/certificate.go`):

- Issue/renew may perform **one** immediate upstream status read
  (`pollIfNeeded`) when the submit response isn't settled, before deciding
  200 vs 202 — a single read, never a loop or sleep.
- If the enrollment is settled with an inline cert (no approval workflow) →
  `enrollmentToResponse` yields 200, `accepted=false`, cert + meta.
- Otherwise → 202, `accepted=true`, **meta only**. Meta entries are plain
  META/string attributes (`buildMeta`), names namespaced with the connector
  prefix: `otpki.endEntityId`, `otpki.endEntityLoginId`,
  `otpki.enrollmentRequestId`, `otpki.issuanceRequestId`,
  `otpki.certificateId`, `otpki.endEntityProfileId`,
  `otpki.certificateProfileId`, `otpki.caId`, `otpki.caFingerprint`,
  `otpki.issuedAt`
  (`otpki-connector:internal/attr/metakeys.go`, each with a frozen UUID —
  "Core dedups on these"). contentType is `string` throughout; the
  `resource`/secret content type is **not** used for meta — secrets only ever
  arrive inbound via `authorityAttributes` resource attributes.
- `IssueStatus` consumes `req.Meta`: reads `otpki.enrollmentRequestId` +
  `otpki.endEntityLoginId` out of the replayed meta, re-builds the client
  from `req.AuthorityAttributes`, and **polls the upstream once per call**
  (`GetEnrollmentByRequestID`). Always 200 with status
  `inProgress|completed|failed`; `completed` carries `certificateData`;
  missing meta keys → 422 VALIDATION_FAILED ("Meta is missing …").
  **Core owns the poll loop cadence — the connector never sleeps/loops.**
- `CancelIssue` returns `authority.ErrCancelRefused` → 422 (OTPKI has no
  cancel). One status probe per Core request; no timer anywhere.

## 4. Core re-drive / double-submit: NO dedup machinery

There is **no inflight-order store, no idempotency key, no request hash** in
either connector. The model is: **each issue call = one backend order; Core
owns retries.** What the connectors do instead is make retryability an
explicit part of the **error contract**:

- otpki (`otpki-connector:internal/otpki/factory.go`): `CallReadOnly` retries
  reads (re-auth once on UNAUTHENTICATED; bounded exponential backoff on
  UNAVAILABLE/DEADLINE_EXCEEDED). `CallMutating` "runs a mutating RPC exactly
  ONCE … It NEVER retries — re-issuing a mutation after a partial success can
  duplicate end-entities or double-revoke."
- dlm (`dlm-connector:internal/provider/issue.go`): a `mutated` flag flips to
  true once any mutating call may have reached DLM; from then on every
  outward failure is forced **non-retryable** (`finalizeOutcome` →
  `problem.NonRetryable`) so Core will not re-drive an operation that might
  already have placed the order. Pre-transmission failures (dial/TLS never
  completed) keep their retryable classification.

So double-submit protection is achieved by telling Core *whether a retry is
safe*, not by remembering orders. The dlm connector's problem+json renderer
carries `retryable` / `retryAfterSeconds` extensions
(`dlm-connector:internal/problem/`).

## 5. caCertificates + crl: attributes-only requests, derived on the fly

Exact request schemas, confirmed from
`connector-factory:specs/_local-docs/authority-provider-v3.yaml`:

```yaml
CrlRequestDtoV3:
  properties:
    authorityAttributes: [RequestAttribute]   # required
    raProfileAttributes: [RequestAttribute]   # required
    delta: boolean (default false)            # "delta CRL where supported"
  required: [authorityAttributes, raProfileAttributes]

CaCertificatesRequestDtoV3:
  properties:
    authorityAttributes: [RequestAttribute]   # required
    raProfileAttributes: [RequestAttribute]   # required
  required: [authorityAttributes, raProfileAttributes]
```

**No `meta` field on either. No certificate payload. No CRL "type" field
beyond the `delta` boolean.** The connector must derive everything from the
authority + RA-profile attributes alone. (Note: the spec yaml omits the 200
response schemas for these two paths — only 401/404/500 are listed — but the
go-sdk model pins them: `CrlResponseDtoV3{ crl string }` = base64 DER, "Core
parses nextUpdate, issuer, and revoked-entry data from the CRL itself";
`CaCertificatesResponseDtoV3{ certificates []CertificateDataResponseDtoV3 }`,
convention "issuing CA first, root last" —
`go-sdk:connector/model/authority/v3/model_crl_response_dto_v3.go`,
`…model_ca_certificates_response_dto_v3.go`.)

How the connectors implement them
(`otpki-connector:internal/provider/authority.go`):

- `GetCrl`: take the CA id from the RA-profile attributes'
  `certificateAuthority` selection (missing → 422), build the client from
  `authorityAttributes`, call the backend's `GetLatestCRL(caID)`, base64 the
  DER, done. No cached CRL, no CRL URL meta.
- `GetCaCertificates`: same CA-id extraction, backend
  `GetCertificateAuthorityCertificates(caID)`, flatten leaf + chain into
  `[]CertificateDataResponseDtoV3`. No "representative last-issued cert"
  needed — the chain comes from a CA-scoped backend call selected purely by
  RA-profile attributes.
- dlm implements **neither** and that is also a valid answer: both return
  `problem.CodeOperationNotSupported`
  (`dlm-connector:internal/provider/unsupported.go`) — CRL "DLM exposes no
  CRL endpoint"; chain "uploaded to the ILM inventory manually".

## 6. Discovery with no DB: in-memory map keyed by discovery uuid; restart loses it — accepted

**Neither otpki-connector nor dlm-connector implements the Discovery
Provider** (grep for `DiscoveryProvider`/discovery handlers: zero production
matches in both repos). The authoritative Go pattern is the go-sdk itself:

- Interface (`go-sdk:connector/provider/discovery/v1/provider.go`):
  `DiscoverCertificate(ctx, req)` (may run sync or return `inProgress`),
  `GetDiscovery(ctx, uuid, req)` (paginated results), `DeleteDiscovery(ctx,
  uuid)`.
- Reference implementation (`go-sdk:connector/examples/disco-v1/store.go`):
  a `Store` with `sync.RWMutex` + `map[string]*entry` keyed by a
  **server-generated uuid**; entry holds status, the discovered
  `[]DiscoveryProviderCertificateDataDto`, meta, and the original request
  attributes. `GetDiscovery` pages out of that map; `DeleteDiscovery` removes
  the entry; unknown uuid → `ErrDiscoveryNotFound` (404).
- **On restart the map is gone and that is the accepted contract**: Core's
  next `GetDiscovery` gets a 404 and treats the discovery as failed/unknown.
  That a new discovery then gets (re-)triggered by Core or the operator is an
  **inference, not code-verified** — none of the four sources includes Core;
  confirm against Core once. Nothing in the SDK or examples persists
  discovery state. (A multi-provider example
  `go-sdk:connector/examples/multi-v1/discovery_store.go` follows the same
  in-memory pattern.)

For a new connector: discovery results live in an in-process map from "start
discovery" until Core has paged them (or the entry is deleted/TTL'd);
re-running a discovery after a connector restart is Core's job, not a
connector-DB job.

## 7. Attribute definitions: frozen name+UUID constants + tiny typed builders

The pattern (both connectors identical in spirit):

- One package (`dlm-connector:internal/attr/registry.go`,
  `otpki-connector:internal/attr/uuids.go`) holding **frozen const pairs** —
  "chosen once, never regenerated, because Core matches attribute definitions
  across connector restarts and versions by UUID":

```go
const (
    NameDataBaseURL = "data_baseUrl"
    UUIDDataBaseURL = "8f2e7db9-78d5-4f17-927e-b809a2cfa96d"
    ...
)
```

(otpki uses a shared `uuidPrefix` + short suffix scheme with a "retired —
never reuse" comment block for removed UUIDs.)

- Small builder funcs wrapping the generated go-sdk model constructors, e.g.
  (`dlm-connector:internal/attr/registry.go`):

```go
func stringDataAttribute(uuid, name, label, description string, required bool) mdl.BaseAttributeDto {
    d := mdl.NewDataAttributeV3(uuid, name, 3, mdl.ATTRIBUTETYPE_DATA,
        mdl.ATTRIBUTECONTENTTYPE_STRING,
        *mdl.NewDataAttributeProperties(label, true, required, false, false, false, false),
        mdl.ATTRIBUTEVERSION_V3)
    d.Description = &description
    return asBaseAttributeDto(mdl.DataAttributeV3AsBaseAttributeDtoV3(d))
}
```

plus regexp constraints attached UI-side only (server re-validates
independently), `infoAttribute` markdown guidance panels, filter-only
callbacks to scope Core's Secret picker (`SECRET_TYPE.EQUALS` →
e.g. `jwtToken` / `basicAuth`), and a fail-fast `NewRegistry()` that aborts
startup on duplicate UUID/name. Meta attributes get the same treatment with
`overwrite: true` properties (`dlm-connector:internal/attr/meta.go`).

## 8. Register: a first-class Provider method; "not supported" = typed error, not absence

`Register` is part of the mandatory 14-method `authority.Provider` interface
(`go-sdk:connector/provider/authority/v3/provider.go`) — you always implement
the method; you choose its behavior:

- **otpki implements it** (`otpki-connector:internal/provider/certificate.go`):
  pre-creates the end entity from `subjectDn`/`subjectAltName` (no CSR),
  returns sync 200 with meta identifying the registration; a later `Issue`
  that carries that meta takes the registered-end-entity path.
- **dlm rejects it** (`dlm-connector:internal/provider/unsupported.go`):
  `problem.New(problem.CodeOperationNotSupported, …)` → HTTP 501. Same for
  Revoke/GetCrl/GetCaCertificates. Status/cancel of never-async ops use the
  distinct `CodeOperationNotTracked` → 404. Cancel of a real but
  uncancellable op uses `authority.ErrCancelRefused` → 422.

So the signal vocabulary is: **501 OPERATION_NOT_SUPPORTED** (connector never
does this), **404 OPERATION_NOT_TRACKED / ErrOperationNotFound** (no such
async handle), **422 ErrCancelRefused** (past point of no return). The
`…/attributes` schema endpoints of unsupported ops still answer 200 with `[]`
(`dlm-connector:internal/provider/attributes.go`).

## 9. Repo layout worth mirroring

dlm-connector (REST backend — the closer template for CertCentral):

```
cmd/dlm-connector/          main.go (env config, slog, tracing, run loop)
                            connector.go (buildConnector: wire client+registry+
                              provider into shared.Connector; /v2/info interfaces;
                              problem+json fallback route)
internal/
  attr/                     frozen UUIDs, schema builders, request-attribute
                            extraction (extract.go), response meta builders (meta.go)
  callback/                 attribute-callback dispatcher + handlers (cascading
                            option lists), pagination
  config/                   env config + sanitize
  dlm/                      backend HTTP client: conn.go (Conn{BaseURL,Token}),
                            endpoints, typed errors w/ retryability classification,
                            dlmtest/ (recorded fixtures + fake server)
  problem/                  RFC 9457 problem+json codes + renderer
  provider/                 authority.Provider impl: provider.go (shell),
                            issue.go / renew.go / identify.go / attributes.go,
                            unsupported.go (the 501/404 table), csr.go, acl.go
  logging/  tlstrust/  tracing/  version/
test/harness + test/integration   (testcontainers against real backend)
```

otpki differs only where the backend does (gen/ protobuf stubs, factory.go
per-authority client cache, passwd/ derivation, attrdefs/). Both are a single
`main` binary, HTTP server from `go-sdk`'s `shared.Connector`
(`shared.New(shared.WithLogger…, shared.Register(authorityRegistrable{…}))`),
120s WriteTimeout sized to the worst-case synchronous upstream chain.

---

## Applying this to a new connector

The nine sections above are the contract. When they were first applied to a
real design draft (the DigiCert CertCentral connector), the draft — written
from v2-era priors — violated them in six ways, all listed in the SKILL.md
"v2 traps" table: a full PostgreSQL layer, an inflight-order dedup table, a
connector-side poll loop with a timeout attribute, `getCrl` returning null,
certificate meta consumed by authority-level operations, and Java/Spring
framing. Every one of those is the *default* output of a model that has not
read this file. Check any new design against the SKILL.md self-check list,
and when in doubt, read the actual source: the spec yaml for DTO shapes,
go-sdk for the Go contract, dlm-connector for a REST backend, otpki-connector
for async issuance.

Verification note: this digest was written from the four sources at HEAD
(2026-07-24); prose quotes are verbatim, code snippets may be lightly
condensed, file paths are exact as of that date.
