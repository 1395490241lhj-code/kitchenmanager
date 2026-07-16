# Sync API Rate Limiting (Phase 2C-1)

Status: **implemented, offline-validated, hosted-development-validated**
(against a locally-run instance of the new backend code, pointed at the
real development Supabase project — nothing has been pushed or deployed
this phase). **Not production-configured. Not production-enabled.**

## Goal

Protect `/api/sync/*` from a single account's runaway usage without ever
breaking a normal client's ordinary batch-sync, reconnect, merge, or
rollback flow.

## Identity used for rate-limit keys

Every bucket key is built only from the **authenticated JWT subject**
(`req.auth.userId`, a stable UUID) plus the route path or scope — never
email, never the raw `Authorization` header/token, never a device name, and
never IP alone (a shared NAT/office network would otherwise collide
unrelated users together). A request that never authenticated (rejected by
`auth`/`role` before reaching the limiter) never touches any bucket at all
— verified directly (`sync-phase2c1-version-and-rate-limit.test.mjs` test
24, and semantic guard "rate-limit bucket keys are built only from
req.auth.userId and route/path").

## Two limiter categories

`src/server/sync/rate-limit.js`:

- **Read limiter** (`createReadRateLimiter`) — `GET /api/sync/bootstrap` and
  `GET /api/sync/changes`. Keyed by `userId + route path`, so a burst of
  `changes` pagination pages can never starve a later `bootstrap` call.
- **Mutation limiter** (`createMutationRateLimiter`) — `POST
  /api/sync/mutations`. Two independent budgets per user, either one
  tripping is a 429:
  - request count (how many `mutations` POST calls)
  - operation count (total mutations across those requests — a single
    request can batch up to 100)

There is **no separate "merge confirm" or "rollback" limiter category**.
The server has no field distinguishing "this batch is a confirm" from
"this batch is a rollback" from "this batch is an ordinary CRUD sync" — all
three travel through the identical `POST /api/sync/mutations` endpoint and
payload shape. One mutation limiter covers all of them uniformly. This is a
deliberate scoping decision, not an oversight — verified directly (tests
28/29 in the Node test file, both hitting the same limiter through
differently-shaped-but-identically-routed request bodies).

## Initial thresholds (starting point, not empirically tuned)

Hardcoded constants in `src/server/config.js` (matching the existing
`AI_RATE_LIMIT_MAX` precedent — not env-configurable; the storage backend,
not these numbers, is what's designed to be swappable):

| Limiter | Window | Limit |
|---|---|---|
| Read (per user, per route) | 5 min | 120 requests |
| Mutation requests (per user) | 5 min | 40 requests |
| Mutation operations (per user) | 5 min | 500 operations |

These are a documented starting point audited against this project's own
existing call patterns (a single hosted smoke run exercises dozens of calls
in quick succession; ordinary manual "立即同步库存" usage is nowhere close to
these numbers) — **not** tuned against real production traffic, since no
production cohort exists yet. Revisit once Stage 2+ usage data exists (see
`docs/PRODUCTION_ROLLOUT_PLAN.md`).

No separate IP-based fallback limiter was added this phase. Every sync
route requires authentication before reaching any rate-limit check at all
(a request without a valid JWT gets a 401 from the existing `auth`/`role`
middleware, never reaching the limiter or consuming any bucket) — so the
"anonymous flood" concern this class of limiter usually addresses doesn't
apply to `/api/sync/*` specifically the way it does to a public endpoint.
Protecting against a flood of *invalid-token* attempts (which do reach the
server, just get rejected before the limiter) is an infrastructure-level
concern (Render/Cloudflare edge protection), not addressed by this
application-layer change.

## Storage strategy

`createMemoryWindowStore()` — a plain in-memory, per-process fixed-window
counter (a `Map`), injected into both limiter factories.

**This is deliberately not safe across multiple Render instances or a
process restart** — each instance/restart starts every bucket back at
zero. This is an accepted, explicit limitation for **Stage 1 only** (a
small, known set of internal test accounts on what is today a single
backend instance) — not disguised as multi-instance-safe. Scaling to more
than one backend instance requires a shared store (Redis/Upstash) behind
the exact same `store` interface used here (`consume`/`consumeBy`); no new
npm dependency was introduced this phase, since none was necessary for
Stage 1.

## Response contract

`429 Too Many Requests`:

```json
{
  "error": "rate_limited",
  "code": "SYNC_RATE_LIMITED",
  "message": "Too many sync requests. Please try again shortly.",
  "retryAfterSeconds": 296
}
```

Plus a `Retry-After` header matching `retryAfterSeconds`. Never includes
the limiter key, user id, IP, or any internal bucket detail.

## Middleware order and idempotency interactions

`auth → role → versionGate → rateLimiter → handler`. Audited explicitly:

- A rejected old client (426) never reaches the rate limiter at all in
  either direction that matters — a 426 doesn't consume a rate-limit bucket
  (it returns before the limiter runs), and a rate-limited (429) request
  never reaches the version gate's own state either, since version gate
  runs first.
- An invalid/missing token never reaches or consumes any per-user bucket —
  `auth`/`role` reject it with 401 first.
- An idempotent retry (same `mutationId` resent) still consumes one
  request-count unit and its mutation's share of the operation-count
  budget — retries are not free, by design, since a legitimate retry after
  a transport blip should behave identically to any other request for
  rate-limiting purposes. The existing idempotency ledger
  (`sync_mutations`, primary key `(user_id, mutation_id)`) still guarantees
  the retry itself is safe (no duplicate business effect) regardless of
  rate-limit accounting.
- A 426 or 429 never reaches the handler, so neither can ever write a
  `PendingMutation` server-side effect or a `sync_mutations` ledger row —
  enforced by placement in the chain (verified directly: test 25).
- The existing `MAX_BATCH_SIZE = 100` per-request mutation cap
  (`src/server/sync/validation.js`) is completely independent of and
  unaffected by the new operation-count rate limit — a batch can still be
  rejected as too large by validation regardless of whether the account has
  rate-limit budget remaining (verified: test 23).

## iOS client behavior

`SyncError.rateLimited(retryAfterSeconds: TimeInterval?)` (mapped from HTTP
429, carrying the server's own `retryAfterSeconds` when present).
`GuestMergeController.rateLimitedRetryAfter: Date?` is the resulting
absolute deadline (server value, or a conservative 30-second fallback if
the server didn't include one), shown as "同步请求过于频繁，请稍后再试。" in the
account/sync status view. Unlike `clientUpgradeRequired`, a rate-limited
rollback stays fully retryable (its own session status logic already
reverts to `.completed`/rollback-eligible regardless of failure reason) —
rate limiting is unrelated to version compatibility and must never also
disable the rollback button.

No client-side automatic backoff/retry loop was added this phase — the
existing architecture only ever calls `SyncCoordinator.runOnce` from an
explicit user action (`confirmMerge`/`rollback`/`syncNow`), never
automatically, so there is no automatic retry loop to jitter or back off in
the first place; a 429 simply surfaces the wait-time message and the user
retries manually (or via the same explicit action) once ready.

## What this phase did NOT do

- Did not introduce a shared/distributed store (Redis/Upstash) — explicitly
  deferred to whenever a second backend instance actually exists.
- Did not add a new npm dependency.
- Did not tune thresholds against real production traffic (none exists).
- Did not implement per-IP emergency fallback limiting.
