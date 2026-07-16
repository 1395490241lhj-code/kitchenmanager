# Phase 2C-1 Validation (Minimum App Version Enforcement + Sync API Rate Limiting)

No production flag was enabled, no production config was changed, no
production backend was switched to, and nothing was pushed as part of this
phase. No secret, token, password, or full production credential is
reproduced below.

## Scope

Only the first two of the six hard rollout blockers identified in
`docs/PRODUCTION_ENABLEMENT_READINESS.md` were addressed this phase:
minimum-app-version enforcement and `/api/sync/*` rate limiting. The
remaining four (crash reporting/monitoring, the production Supabase project
decision, pgTAP/migration re-verification, and a TestFlight/App Store
pipeline) were explicitly out of scope and were not attempted.

## Offline validation

**Backend (Node, `test/sync-phase2c1-version-and-rate-limit.test.mjs`)**:
47 tests, all passing — version-comparator safety (numeric SemVer, build,
schema parsing with malformed/negative/overflow/leading-zero inputs),
config fail-safe behavior (disabled by default, misconfigured-fails-closed),
the full version-gate middleware matrix (valid/old version/old
build/old schema/missing headers/malformed headers, 426 body shape, no
leaked internals), integration tests via `registerSyncRoutes` (sync
read/mutation blocked, non-sync routes unaffected), and the full rate-limit
matrix (under/at/over limit, Retry-After, per-user and per-route bucket
isolation, read/mutation bucket independence, operation-count quota,
existing batch-size cap unaffected, failed-auth never consumes a bucket,
426/429 never reach the handler, fake-clock window reset, no email/token in
bucket keys, the single shared mutation-limiter covering
confirm/rollback-shaped requests identically, deterministic repeated runs)
plus 8 Node semantic guards (route wiring order, no service-role, no
production flag flipped on, key construction never uses IP/headers/email,
stable error codes, documented named-constant thresholds, no Shopping/Plan/
Recipe scope creep).

**iOS (XCTest)**:
- `SyncTransportTests`: 4 new tests — every sync request carries the four
  version headers with identical values across bootstrap/changes/mutations;
  426 maps to `.clientUpgradeRequired` carrying `minimumVersion`/
  `minimumBuild`; 429 maps to `.rateLimited` carrying `retryAfterSeconds`.
- `GuestMergeTests`: 5 new tests — a 426 during confirm sets the
  upgrade-required flag and preserves local Guest data and
  `createdEntityIds`; the flag clears on a fresh successful attempt (after
  "the app is updated"); a merge-preview 426 never shows a misleading
  "家庭云端库存 0 条"; a 429 during rollback stays retryable
  (`.completed`, never falsely `.rolledBack`) and records a retry-after
  deadline without disabling the rollback button; neither failure mode ever
  produces a duplicate create on retry.
- `Phase2C1VersionAndRateLimitUITests`: 1 new credential-free UI test —
  local-only (Guest) inventory usage is completely unaffected and none of
  the new merge/sync-specific UI leaks before sign-in. Following the same
  established boundary as the existing `GuestMergeUIPhase2B3UITests`, the
  signed-in-only states (upgrade-required banner, disabled confirm/
  rollback, rate-limit message) are not exercised by a real UI test this
  phase — no Debug-only mock-injection backdoor was built for it, since
  that would need a new permanent test-only wiring point in the app's
  composition root, judged out of scope. Those states are instead fully
  covered by the offline `GuestMergeTests`/`SyncTransportTests` above.

**Full regression** (all baselines met or exceeded, none shrank):

| Suite | Before | After |
|---|---|---|
| GuestMergeTests | 127 | 132 |
| iOS Unit (full) | 592 | 601 |
| iOS UI (full, serial) | 6 | 7 |
| Node (full) | 864 | 911 |

Debug and Release clean builds both succeeded. `npm audit --omit=dev
--audit-level=high`: 0 vulnerabilities (no new dependency was added).
`git diff --check`: clean. Secret scan of the full diff and all new files:
clean.

## Hosted-development validation

**Important scoping note**: nothing was pushed or deployed this phase, so
the live Render deployment (`kitchenmanager-b8px.onrender.com`) still runs
the pre-Phase-2C-1 code and was not usable to validate the new backend
logic. Instead, the new backend code was run **locally** (`node server.js`
on `127.0.0.1`, sourced with the real development Supabase project's
credentials from the gitignored `.env.development.local`) — a real
authenticated JWT, real RLS, and the real development database, with only
the network hop itself being local rather than through Render. This is
explicitly documented as *not* equivalent to validating the actual deployed
service, only the same code that would eventually be deployed.

**A. Version enforcement disabled (default)** — `npm run smoke:sync`
against the local server: PASS (auth/RLS isolation, CRUD/conflict/
idempotency/feed/pagination, 8 representative entity families, real Express
sync contract) — identical to the existing baseline, confirming the new
code is a no-op when the flag is off.

**B. Version enforcement enabled, current version headers** —
`GET /api/sync/bootstrap` with `X-Kitchen-App-Version: 9.9.9` /
`X-Kitchen-App-Build: 999` / `X-Kitchen-Client-Schema: 1` against a server
configured with `MIN_IOS_APP_VERSION=1.0.0`/`MIN_IOS_BUILD=1`/
`MIN_IOS_CLIENT_SCHEMA=1`: **200**, request allowed. PASS.

**C. Simulated old version** — the same request with
`X-Kitchen-App-Version: 0.1.0`: **426**, body
`{"error":"client_upgrade_required","code":"CLIENT_UPGRADE_REQUIRED",...,"minimumVersion":"1.0.0","minimumBuild":1}`.
A request with the version headers omitted entirely also returned **426**.
A `POST /api/sync/mutations` attempt with the same old-version headers
(entity name `__phase2c1_should_never_be_created__`) also returned **426**;
a before/after read-only count of this user's own `sync_mutations` ledger
rows (authenticated `select`, RLS-scoped, no service-role) was identical
(304 → 304), confirming the rejected mutation never reached the RPC or
wrote a ledger row. A follow-up read-only scan of live inventory items
found **0** entities matching the `__phase2c1` marker prefix — the create
was never applied. PASS.

**D. Rate limit** — using the real `SYNC_READ_RATE_LIMIT_MAX = 120`
threshold (not a lowered test-only value — the real configured limit was
exercised directly) against a freshly-started server (clean in-memory
bucket) with valid current-version headers: exactly **120** consecutive
`GET /api/sync/bootstrap` requests succeeded, the **121st** returned 429
with body `{"error":"rate_limited","code":"SYNC_RATE_LIMITED",...,"retryAfterSeconds":296}`
and a matching `Retry-After: 296` header. Window-reset-after-wait was
**not** re-verified with a real 5-minute wait this round — that specific
behavior is already verified deterministically via the fake-clock offline
test (`sync-phase2c1-version-and-rate-limit.test.mjs` test 26) and re-
confirming it here would only add a real 5-minute delay without adding new
evidence. PASS (trip behavior); window-reset PASS via offline fake-clock
test only.

**E. Cleanup** — no test data was ever created this round (every write
attempt was correctly rejected before reaching the RPC), so there was
nothing to clean up: a read-only scan confirmed 0 live entities matching
any test marker prefix. The local server process was stopped and confirmed
not listening on its port afterward. `SYNC_VERSION_ENFORCEMENT_ENABLED` and
the `MIN_IOS_*` variables used for this validation were shell-local
exports for the local server process only — never written to any tracked
file, `.env.development.local`, or `Local.xcconfig`; both remain untouched
and `git check-ignore`-confirmed ignored. All four iOS feature flags in
`Local.xcconfig` remain `NO`, unchanged by this phase (no physical-device
step was needed this round, since all new behavior is server/transport-
layer and fully covered by the XCTest suite plus this hosted check).

## Conclusion

Both this phase's targets — minimum-app-version enforcement and
`/api/sync/*` rate limiting — are **implemented, offline-validated, and
hosted-development-validated**. Neither is **production-configured** (no
`MIN_IOS_*`/`SYNC_VERSION_ENFORCEMENT_ENABLED` value has been decided or
set anywhere outside this validation round) nor **production-enabled**. See
`docs/PRODUCTION_ENABLEMENT_READINESS.md` for the updated condition
checklist — four rollout blockers remain: crash reporting/monitoring, the
production Supabase project decision, pgTAP/migration re-verification, and
a TestFlight/App Store pipeline.
