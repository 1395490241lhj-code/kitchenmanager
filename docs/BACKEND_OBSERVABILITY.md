# Backend Observability (Phase 2C-2)

Status: **implemented and offline/hosted-development validated; not
production-configured or production-enabled**. Covers structured logging,
request correlation ids, in-process sync metrics, and `/health` `/ready`.
See `docs/MONITORING_ALERTING_STAGE1.md` for alert rules and
`docs/CRASH_REPORTING.md` for the separate iOS crash-reporting layer.

## 1. Structured logging

`src/server/observability/logger.js` exports `createLogger(...)`. Every call
writes exactly one JSON line to `process.stdout` (Render's own log collector
picks this up — no log-shipping dependency was added):

```json
{"timestamp":"2026-07-16T02:48:32.090Z","level":"info","event":"http_request","environment":"development","release":"...","requestId":"...","method":"GET","route":"/health","status":200,"durationMs":3,"authState":"anonymous"}
```

### Allowlist, not a denylist

`ALLOWED_LOG_FIELDS` is the *only* set of field names ever written:

```
requestId, method, route, status, durationMs, authState, userHash,
routeCategory, mutationCountBucket, resultCode, metric, value,
retryAfterSeconds, minimumVersion, minimumBuild, checks, reason
```

Anything else passed to `log(event, fields)` is silently dropped — this is
deliberately stricter than redacting known-bad field names (a denylist only
protects against names already thought of; an allowlist protects against
names nobody thought of yet, including a future accidental `{ email }` or
`{ body: req.body }`).

`hashUserId(userId)` produces a 16-character truncated SHA-256 digest — an
irreversible, stable-per-user, short identifier for log correlation, never
the raw UUID and never reversible back to it. It is available but not yet
wired into any log call (no log line currently needs to distinguish users);
documented here since `userHash` is already on the allowlist for that future
need.

## 2. Request correlation id

`src/server/observability/request-id.js`, installed globally in `server.js`
(before CORS/routes, so *every* response — including a 401/403/404/429/426 —
gets one):

- Accepts a caller-supplied `X-Request-ID` header only if it matches
  `^[A-Za-z0-9._-]{1,100}$` (no whitespace, no control characters, capped
  length) — otherwise generates a fresh `crypto.randomUUID()`. An
  attacker-controlled header is never trusted verbatim.
- Always echoed back as the `X-Request-ID` response header.
- `req.requestId` is available to every downstream handler/middleware for
  its own log lines.

## 3. Sync metrics

`src/server/observability/metrics.js` — an in-process counter/observation
registry (`createMetricsRegistry()`), not Prometheus/OTel. This is a
documented starting point: `increment(name, amount, labels)` and
`observe(name, value, labels)` calls, with stable names in
`SYNC_METRIC_NAMES`:

```
sync_request_total, sync_request_success, sync_request_failure,
sync_rate_limited, sync_upgrade_required, sync_mutation_operations,
sync_mutation_conflict, sync_mutation_rejected, sync_mutation_applied,
sync_mutation_duplicate, sync_read_latency, sync_write_latency, backend_5xx
```

Wired in:

- `version-gate.js`'s 426 path → `sync_upgrade_required` (+ a `sync_upgrade_required`
  log event, route/requestId only, no user identity).
- `rate-limit.js`'s 429 path (both the read and mutation limiters) →
  `sync_rate_limited` (+ a matching log event with `routeCategory` `read`/`mutation`).
- `routes.js`'s `createSyncHandlers` wraps `bootstrap`/`changes`/`mutations`:
  records `sync_request_total`/`success`/`failure` and a latency observation
  per call, and — for `mutations` specifically — `sync_mutation_operations`
  (the batch size) plus one increment per result status
  (`applied`/`conflict`/`rejected`/`duplicate`).
- `http-logging.js`'s access-log middleware increments `backend_5xx` for any
  response `>= 500`, across every route (not just sync).

### Explicitly out of scope this phase

`rollback_attempt/success/failure`, `stale_preview_rejected`,
`orphaned_session_detected`, and `consistency_check_failure` (all listed as
suggested backend metrics in the Phase 2C-2 instructions) are **not**
independently observable server-side: every mutation — confirm, rollback,
retry — arrives as an identically-shaped `POST /api/sync/mutations` request
with no field distinguishing "this is a rollback." This is the same
architectural fact already documented in Phase 2C-1's single mutation
rate-limiter design (`docs/SYNC_API_RATE_LIMITING.md`). Those four events are
instead captured client-side as `CrashReportingEvent` breadcrumbs (see
`docs/CRASH_REPORTING.md` §5), which do know which flow triggered the call.

### Label safety

Every label is route/status/result-shaped (`route`, `routeCategory`) —
never a raw user id, IP, or mutation id. No label is ever derived from
request/response body content.

## 4. `/health` and `/ready`

`src/server/observability/health.js`.

- `GET /health` — process-alive only. No DB/network access, no config
  checks, always fast. `{"status":"ok","version":"...","environment":"..."}`.
- `GET /ready` — runs a list of named `{ name, run: async () => boolean }`
  checks (each wrapped with a 2s timeout; a throwing/timed-out check counts
  as a failure, never crashes the endpoint) and returns 200 only if every
  check passes, else 503. Response: `{"status":"ready"|"not_ready","version":"...","environment":"...","checks":{"auth_config":true,...}}`.
  Never a URL, key, project ref, or stack trace in the body.

`server.js` wires four checks into `/ready`:

1. `auth_config` — `SUPABASE_AUTH_CONFIG_ERRORS` is empty (existing
   startup-time Supabase config validation, unchanged from before this
   phase).
2. `version_gate_config` — the Phase 2C-1 version-enforcement config is
   either disabled or, if enabled, not misconfigured.
3. `rate_limiter_config` — the three Phase 2C-1 rate-limit thresholds are
   positive integers.
4. `supabase_connectivity` — a `GET` to `SUPABASE_JWKS_URL` with a 2s
   timeout; read-only, no writes, no credentials sent beyond what's already
   a public JWKS endpoint.

Verified during hosted development validation (see
`docs/PHASE2C2_VALIDATION.md`) against the real development Supabase
project: `/health` → 200 in ~3ms; `/ready` → 200 with all four checks
`true`.

## 5. Security / privacy summary

- No log line, metric label, or `/health` `/ready` body has ever contained:
  an email, an Authorization header, a raw access token, a full user id, a
  household id, an IP address, a request body, an inventory item name, a
  receipt string, or a Supabase URL/key. Verified both by the allowlist's
  construction and by a hosted-development grep of real captured log output
  (`docs/PHASE2C2_VALIDATION.md`).
- No service-role key is used or referenced anywhere in this observability
  code.
- A logger or metrics failure can never crash or block the request it was
  observing — both are called from a `try/catch` in the access-log
  middleware, and the sync-handler instrumentation only ever calls
  duck-typed optional methods (`metrics?.increment(...)`).
