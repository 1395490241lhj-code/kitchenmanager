# Phase 2C-2 Validation — Crash Reporting + Basic Monitoring

Status: **implemented, offline-tested, and hosted-development validated.
Not production-configured. Not production-enabled. Monitoring is not live.**

## 1. Git gate

At start: `HEAD == origin/main == c67e78be29bf4aaf7a096c949a8af562f68e7075`
(Phase 2C-1's final commit), workspace clean, `.env.development.local` and
`ios-native/Kitchen Manager/Config/Local.xcconfig` both correctly
ignored/untracked, no stray zip/DerivedData/xcresult/log/screenshot/credential
artifacts.

**Note on unrelated concurrent changes**: during this phase's session, an
unrelated, clearly deliberate documentation restructuring of `AGENTS.md`,
`CLAUDE.md`, `CODING_RULES.md`, `PROJECT_GUIDE.md`, `PROJECT_GUIDE.zh.md`,
`PROJECT_WORKFLOW.md`, `README.md`, `TESTING_RULES.md`, `.cursorrules`,
`package.json`'s description field, and new files under `scripts/*.md` /
`scripts/package.json` appeared in the working tree (dated 2026-07-16,
today). This was **not** made by this Phase 2C-2 work and is left completely
untouched and uncommitted — only the specific files this phase created or
intentionally modified were staged. `PROJECT_STATUS.md` and `AI_CONTEXT.md`
were also touched by that same concurrent restructuring; this phase's edits
to both were written to match their new (already-changed) structure rather
than assuming the prior verbose-narrative format.

## 2. Pre-implementation audit findings

### iOS

- No `OSLog`/`Logger` usage anywhere in `KitchenManager/` — only ad-hoc
  `print()` statements in a handful of files.
- No crash-reporting SDK, no `Package.resolved` entry for one (only
  `supabase-swift` and its own transitive dependencies).
- No uncaught-exception/fatal-crash capture, no breadcrumbs, no
  user/session correlation id, no redaction policy, no diagnostics export
  beyond the existing dogfood-gated `InventorySyncDiagnosticsView` (business
  data, not crash data), no release/build/environment tag, no dedicated
  network/sync error tracking beyond the app's own typed `SyncError`/UI
  state, no Guest-merge/rollback telemetry beyond in-memory `@Published`
  state, no consent/opt-out mechanism, no debug-only logging layer.

### Backend

- `console.log`/`console.warn`/`console.error` used directly, unstructured,
  in `server.js` and `src/server/sync/routes.js` — no JSON shape, no request
  id, no consistent fields.
- No request id anywhere (`req.get('x-request-id')` was never read; no
  response ever set one).
- No metrics of any kind — no counters, no latency observations.
- No `/health` or `/ready` endpoint existed.
- No alert provider integration.

### Privacy boundary (before this phase)

The existing `sendSyncError` helper already avoided leaking SQL/Supabase
upstream bodies/tokens/Authorization headers in its 5xx logging (a Phase 2A
decision carried forward), but there was no structural allowlist — a future
call site could have logged anything by accident. No prior code path logged
email, full UUID, household id, inventory names, or receipt content, but this
was never enforced by any shared mechanism prior to this phase's
`ALLOWED_LOG_FIELDS`/`CrashReportingMetadata` allowlists.

## 3. Provider selection

See `docs/CRASH_REPORTING.md` §2–3 for the full comparison table.
**Sentry** is selected as the Stage-2 candidate provider (best nonfatal +
breadcrumb + same-vendor-Node-SDK + self-hosting fit); **not integrated**
this phase — only `NoOpCrashReporter` ships.

## 4. What was implemented

- Backend: `src/server/observability/{logger,metrics,request-id,http-logging,health}.js`;
  wired into `server.js` (global request-id + access-log middleware, `/health`,
  `/ready`) and `src/server/sync/{version-gate,rate-limit,routes}.js`
  (optional `metrics`/`logger` injection, on by default via
  `registerSyncRoutes(app, { observability })`).
- iOS: `KitchenManager/Observability/CrashReporting.swift` (protocol,
  `CrashReportingEvent`, `CrashReportingMetadata`, `NoOpCrashReporter`,
  `CrashReportingConfiguration`, `CrashReportingFactory`); `SyncError`
  conformance to `CrashReportableError`; `GuestMergeController` gained a
  `crashReporter:` init parameter (default no-op) and breadcrumb/nonfatal
  calls at the start/success/failure points of `preparePreview`,
  `confirmMerge`, `rollback`, and `syncNow`.
- Config: `CRASH_REPORTING_ENABLED/DSN/ENVIRONMENT/SAMPLE_RATE` added to
  `Config/Shared.xcconfig` and `Config/Local.example.xcconfig` (all
  placeholder/`NO`/empty), and the matching `KM_CRASH_REPORTING_*` keys in
  `Info.plist`.

## 5. Offline test results

- **Node**: `test/sync-phase2c2-observability.test.mjs` — 28 new tests
  (request id generation/validation/correlation; logger allowlist/redaction;
  426/429/5xx metric emission; sync success + mutation-status metrics;
  `/health` no-DB-access; `/ready` config-failure/connectivity-failure/success/no-leak-on-throw;
  no-double-logging; concurrent-request correlation; logger/metrics failure
  resilience; deterministic fake-clock rate limiting; 6 Node semantic
  guards). Full suite: **939/939 passed** (up from the Phase 2C-1 baseline of
  911; 0 failures).
- **iOS Unit**: `KitchenManagerTests/CrashReportingTests.swift` (14 tests:
  disabled/missing/incomplete-config no-op fallback, a real-`Bundle`
  fail-safe-default check, metadata allowlist/forbidden-key-drop, sample-rate
  clamping, count/duration bucketing, no-op-provider-never-throws,
  singleton-instance, event-category exhaustiveness, `SyncError` stable-code
  distinctness) + 6 new `GuestMergeTests` cases (fake-provider injection,
  `sync_failed` breadcrumb with a safe code, 426→`sync_upgrade_required`
  +`merge_confirm_failed`, 429→`sync_rate_limited`+`rollback_failed`,
  successful-flow started/completed-only breadcrumbs, nonfatal reporting
  with a safe code not a raw description). Full suite: **621/621 passed**
  (up from the Phase 2C-1 baseline of 601). `GuestMergeTests` alone:
  **138/138** (up from 132).
- **iOS UI**: `Phase2C2ObservabilityUITests.swift` (1 credential-free test:
  app launches normally with crash reporting disabled, Guest inventory
  usable, no DSN/provider-endpoint string ever appears in visible text) —
  same scoping precedent as `Phase2C1VersionAndRateLimitUITests`, no
  Debug-only mock-injection backdoor added for signed-in-only states. Full
  serial suite: **8/8 passed** (up from the Phase 2C-1 baseline of 7).
- Debug and Release clean builds: **0 errors** (verified via `xcodebuild`
  with `DEVELOPER_DIR` pointed at the machine's installed Xcode-beta
  toolchain, since `xcode-select`'s system-wide default was not changed).
- `npm audit --omit=dev --audit-level=high`: **0 vulnerabilities**.

## 6. Hosted development validation

Performed against a **locally-run instance of the new code** (nothing was
pushed/deployed — this validates the same code that would eventually be
deployed, not the actual live Render service), using real
`.env.development.local` Supabase dev credentials and a real dev test
account's password-grant JWT (never printed to any log or terminal output
captured in this document).

- **A — structured logging / correlation**: `/health` and `/ready` each
  produced exactly one `http_request` JSON log line with a `requestId` that
  matched the `X-Request-ID` response header exactly.
- **B — `/health` / `/ready` semantics**: `/health` → `200 {"status":"ok",...}`
  immediately, no DB access. `/ready` → `200` with all four checks (
  `auth_config`, `version_gate_config`, `rate_limiter_config`,
  `supabase_connectivity`) `true` against the real dev Supabase project.
- **C — 426 + metric**: with `SYNC_VERSION_ENFORCEMENT_ENABLED=true` and an
  intentionally unreachable minimum (`99.0.0`/build `999`), a real
  authenticated `bootstrap` request with current-but-below-minimum version
  headers returned `426 CLIENT_UPGRADE_REQUIRED`, and the server emitted a
  matching `sync_upgrade_required` structured log line (route + requestId +
  result code only — no user identity).
- **D — 429 + rate limit boundary**: with the real hardcoded read limit
  (120 requests / 5 min / user), 120 consecutive authenticated `bootstrap`
  requests all returned `200`; the 121st returned `429 SYNC_RATE_LIMITED`
  with a correct `retryAfterSeconds` and matching `Retry-After` response
  header, and the server emitted a matching `sync_rate_limited` structured
  log line.
- **E — privacy grep**: the real test account's email address, and the
  string `Authorization`/`Bearer`, were grepped for across all three hosted
  server-log captures from this validation round — **zero matches** in
  every case.
- **Cleanup**: all three local server processes were killed
  (`pkill`/verified via `lsof -i :3737` returning empty); the temporary token
  file and response-capture scratch files were deleted; `SYNC_VERSION_ENFORCEMENT_ENABLED`
  and the artificially-low minimum version were only ever set as one-off
  environment variables for the spawned local process, never written to any
  tracked file; no `.env.development.local` content was modified. Only
  read/list operations (GET `bootstrap`, GET `/health`/`/ready`) were
  performed against the real dev Supabase-backed database — the 120
  successful requests were plain reads, and every 426/429/401 rejection was
  refused before ever reaching a mutation path, so **zero rows were written**
  to any table by this validation round.

## 7. What this phase does NOT claim

- Crash reporting is not live in production; no real crash/nonfatal event
  has ever been sent to a third-party service.
- Monitoring/alerting is not active; no alert provider is wired up; no
  alert has ever fired.
- The production backend was never touched, paused, or reconfigured.
- No production Supabase project decision was made.
- No pgTAP/migration work was performed.
- No TestFlight/App Store build was created.
- Nothing was pushed.
