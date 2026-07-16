# Production Enablement Readiness Review

Read-only review. No production flag was enabled, no production config was
changed, no production backend was switched to, and nothing was pushed as
part of this review. No secret value, token, or full production credential
is reproduced below.

> **Phase 2C-1 update**: two of the six rollout blockers below are now
> **implemented, offline-validated, and hosted-development-validated**:
> minimum-app-version enforcement and `/api/sync/*` rate limiting. Neither
> is production-configured or production-enabled. See
> `docs/MINIMUM_APP_VERSION_ENFORCEMENT.md`, `docs/SYNC_API_RATE_LIMITING.md`,
> and `docs/PHASE2C1_VALIDATION.md`. Four blockers remain: crash
> reporting/monitoring, the production Supabase project decision,
> pgTAP/migration re-verification, and a TestFlight/App Store pipeline.
>
> **Phase 2C-2 update**: crash-reporting/monitoring is now **implemented
> (abstraction + no-op provider; a real provider is selected — Sentry — but
> not integrated) and offline/hosted-development-validated**: structured
> backend logging, request correlation ids, in-process sync metrics,
> `/health`/`/ready`, and documented Stage-1 alert rules. Not
> production-configured (no real DSN, no alert provider, no dashboard). See
> `docs/CRASH_REPORTING.md`, `docs/BACKEND_OBSERVABILITY.md`,
> `docs/MONITORING_ALERTING_STAGE1.md`, and `docs/PHASE2C2_VALIDATION.md`.
> Four items remain: the production Supabase project decision,
> pgTAP/migration re-verification, a TestFlight/App Store pipeline, and a
> shared/multi-instance rate-limit store before GA (carried forward from
> Phase 2C-1's documented Stage-1-only limitation).

## Context

By the end of Phase 2B-9B, every previously-open *feature-correctness*
blocker for Inventory Sync / Guest Merge was closed and verified on real
hardware: Conflict UI (Phase 2B-8/2B-8C), Rollback (Phase 2B-9/2B-9B), and
the production remote-preview blocker (Phase 2B-7B/2B-8). See
`docs/INVENTORY_SYNC_FINAL_GO_NO_GO.md` for that history — its conclusion
is **Production Go Candidate**.

This review asks a different question: is the surrounding *operational*
infrastructure (config, deploy, monitoring, distribution, rollout
mechanics) ready for real production enablement, not just for the feature
itself to be correct. It is not.

## 1. Production configuration readiness

| Item | Status | Detail |
|---|---|---|
| Production API base URL | ⚠️ **Shared with dev** | `APIEnvironment.swift` resolves both `.production` and `.development` to the same literal Render URL (`kitchenmanager-b8px.onrender.com`) — deliberate, documented, not a bug, but means there is currently no environment isolation between "production" and "development" traffic at the backend-URL level. |
| Supabase production project | ❌ **Does not exist** | Exactly one Supabase project is in use anywhere in this codebase's configuration (dev credentials in `.env.development.local` and the gitignored iOS `Local.xcconfig` reference the same host). No second, genuinely-production Supabase project has ever been created. `.env.example` only has a placeholder (`YOUR_PROJECT_REF`). |
| JWT/JWKS | ✅ met | Asymmetric verification via `jose`'s `createRemoteJWKSet` (`src/server/auth/jwt.js`), issuer/audience/JWKS URL all environment-derived (`src/server/config.js`), with a same-origin cross-check between issuer and `SUPABASE_URL`. No hardcoded secret. |
| Redirect URL / bundle ID | N/A | Bundle ID `com.lianghongjing.kitchenmanager`; no OAuth redirect URL exists because no OAuth flow is implemented yet (unchanged from earlier phases). |
| Keychain access group / entitlements | ⚠️ **No entitlements file exists** | No `.entitlements` file anywhere in the iOS project — no explicit keychain-access-group, associated-domains, or push-notification configuration. The app relies entirely on Xcode's implicit default entitlement. Not a defect for today's feature set, but worth an explicit decision before any capability (e.g. push notifications, universal links) is ever added. |
| Info.plist | ✅ met | All 8 `KM_*` flags flow through `Config/Shared.xcconfig` (committed, defaults `NO`) → optional `Local.xcconfig` (gitignored, per-developer) → `Info.plist`. Verified in a real unsigned Archive (Phase 2B-6): all flags `NO`, zero test credentials/markers in the compiled binary. |
| Secrets injection | ✅ met, with one gap | iOS: `Local.xcconfig`, gitignored, generated from `Config/Local.example.xcconfig` via `npm run configure:ios-auth`. Node: `.env.*` gitignored except `.env.example`. **Gap**: no `.env.production` template exists, and no evidence of how Render's own dashboard environment variables are provisioned or audited — that provisioning happens entirely outside this repo. |
| Render/hosting deploy config | ⚠️ **No infrastructure-as-code** | `.github/workflows/deploy.yml` deploys only the static PWA to **GitHub Pages** — it has no reference to Render, Supabase, or any backend secret at all. There is no `render.yaml`/`Procfile` in the repo. The Express backend's deployment to Render is managed entirely through Render's own dashboard/git-connect, invisible to and unaudited by this repository. |
| Rate limits | ✅ **Sync routes now protected (Phase 2C-1)** | `src/server/sync/rate-limit.js` adds a read limiter (bootstrap/changes, 120 req/5min/user) and a mutation limiter (mutations, 40 req + 500 operations per 5min/user), keyed only by JWT subject + route — implemented, offline- and hosted-development-validated. In-memory store only (not multi-instance-safe yet — documented Stage 1 limitation). See `docs/SYNC_API_RATE_LIMITING.md`. AI/import/`/api/me` limits unchanged. |
| Timeout/retry | ⚠️ **Timeout only, no retry** | iOS `APIClient` sets a 60s default timeout, no automatic retry (errors surface directly to the caller, which may retry manually via `syncNow`). Server-to-Supabase calls in `account-data.js` have **no timeout and no retry**; other outbound HTTP (AI/media) does set timeouts, still no retry logic anywhere. |
| Logging/redaction | ✅ **Structured (Phase 2C-2)** | `src/server/observability/logger.js` now emits allowlisted JSON lines (`http_request`, `sync_upgrade_required`, `sync_rate_limited`) with a global request-correlation id (`X-Request-ID`); no request/response body, Authorization header, email, token, full user id, or household id is ever on the allowlist. Offline- and hosted-development-validated (real log capture grepped clean). See `docs/BACKEND_OBSERVABILITY.md`. |
| Crash reporting | ⚠️ **Abstraction only (Phase 2C-2)** | `KitchenManager/Observability/CrashReporting.swift` — a provider-agnostic protocol, event/metadata allowlists, and `NoOpCrashReporter` (the only shipped provider), wired into `GuestMergeController`. Sentry is the selected future provider (see comparison in `docs/CRASH_REPORTING.md`) but **no SDK has been integrated** — `CRASH_REPORTING_ENABLED = NO` everywhere, no real DSN exists. |
| Monitoring | ⚠️ **In-process metrics only (Phase 2C-2)** | `src/server/observability/metrics.js` — named counters/observations (`sync_request_total/success/failure`, `sync_rate_limited`, `sync_upgrade_required`, `sync_mutation_*`, `backend_5xx`, latency), plus `/health`/`/ready`. No metrics backend/dashboard exists; these are queryable via Render's raw log search today. See `docs/BACKEND_OBSERVABILITY.md`. `InventorySyncDiagnosticsSnapshot` remains the only per-device (not fleet-wide) surface. |
| Alerting | ⚠️ **Rules defined, not wired (Phase 2C-2)** | `docs/MONITORING_ALERTING_STAGE1.md` defines P1/P2/P3 rules (source/threshold/window/owner/response/rollback-trigger) computable from the metrics/logs above. No PagerDuty/Opsgenie/Slack-webhook or any alert provider is actually connected; no alert has ever fired. |

## 2. Database & migration readiness

| Item | Status | Detail |
|---|---|---|
| Migration order | ✅ met | Two migrations exist, applied in filename order: `20260713000100_auth_household_foundation.sql`, `20260713000200_sync_business_foundation.sql`. No gaps, no out-of-order files. |
| Migration checksum / remote parity | ⚠️ **Partial** | `docs/AUTH_SYNC_PHASE0_5_VALIDATION.md` verified remote/local parity for the **first** migration only. The second (sync foundation — the one Inventory Sync actually depends on) has never had an equivalent remote-parity check run. This is a pre-existing gap carried forward from Phase 2B-6, **not resolved by this review**. |
| Schema version | ✅ met | `InventorySyncEnrollment.currentSchemaVersion` and the diagnostics snapshot's `schemaVersion` field exist specifically so a future client/server mismatch can be detected — but no explicit migration-compatibility *test* has ever been run beyond the parity check above. |
| RLS policy | ✅ met (as of last audit) | Verified in Phase 2B-2.5 (real two-user isolation, direct-DML denial) and re-exercised every hosted smoke run since, most recently `npm run smoke:sync` during Phase 2B-9/2B-9B (auth/RLS isolation: PASS). |
| Index / unique constraints | ✅ met | Verified as part of the original migration design/RLS audit (Phase 2A-2.5); no index/constraint regression has been introduced since — no schema change has happened since that migration. |
| Change feed | ✅ met | Extensively exercised this Phase 2B-9/2B-9B round via direct raw-change-feed inspection (`operation`/`version`/`deletedAt` fields), confirmed to correctly distinguish `upsert` vs `delete` and to genuinely tombstone on a real delete. |
| Mutation ledger | ✅ met | `sync_mutations` — used directly and repeatedly this round as the ground-truth evidence source for Rollback validation; confirmed idempotency ledger (mutationId+userId primary key), status transitions (`applied`/`conflict`/`rejected`/`duplicate`) all behave as documented. |
| Rollback metadata | ✅ met | `rollbackAvailableUntil`, `createdEntityIds` — both exercised and their edge cases (window expiry, session recovery) understood and fixed this round. |
| Tombstone | ✅ met | Soft-delete only (`deleted_at`), never a physical delete, confirmed via the trigger logic (`private.write_household_sync_change`) and directly observed in the raw change feed this round. |
| pgTAP / migration re-verification | ❌ **Not done** | Docker-based pgTAP has never been executed for either migration in any phase to date (Docker unavailable in every environment this project has run in so far). This remains an **open evidence gap**, carried forward unchanged.

**Because pgTAP/migration re-verification for the sync-foundation migration remains undone, Production Go Candidate status must stay conditional on this point** — it is not a newly discovered defect, but it is a real, unresolved verification gap that should be closed (or explicitly risk-accepted by a human decision-maker) before a broad rollout, per the user's own instruction for this review.

## 3. Client/version compatibility

| Item | Status |
|---|---|
| Min app version enforcement | ✅ **Implemented (Phase 2C-1)** — `src/server/sync/version-gate.js` gates all three `/api/sync/*` routes behind `SYNC_VERSION_ENFORCEMENT_ENABLED` (default off) + `MIN_IOS_APP_VERSION`/`MIN_IOS_BUILD`/`MIN_IOS_CLIENT_SCHEMA`, with the iOS client sending version headers on every sync request. Offline- and hosted-development-validated. **Not yet production-configured** — no minimum values have been decided for a real rollout. See `docs/MINIMUM_APP_VERSION_ENFORCEMENT.md`. |
| Backend backward compatibility | ⚠️ Untested, low risk today | Since dev and prod share one backend (see §1), there is no version-skew scenario to test yet — but this also means the *first* time a real skew scenario exists (e.g. a schema change ships to backend before all clients update), there is no tooling in place to detect or gate it. |
| Old client behavior | Not tested | No test exercises "old client, new backend contract." |
| Schema evolution | Partial | `schemaVersion` field exists for future detection; no automated enforcement. |
| Feature flag compatibility | ✅ met | Every gate (`INVENTORY_SYNC_ENABLED`, `INVENTORY_MERGE_UI_ENABLED`, dogfood, diagnostics) is independent, all default `NO`, and rolling one back never requires a server-side change (`docs/INVENTORY_SYNC_ROLLBACK_PLAYBOOK.md`). |
| Unsupported client rejection | ✅ **Implemented (Phase 2C-1)** — the version gate above returns 426 to any client below the configured minimum, or sending missing/malformed version headers, whenever enforcement is enabled. |
| Rollback strategy | ✅ met | See `docs/PRODUCTION_ROLLBACK_RUNBOOK.md` (new, this review). |
| Phased rollout support | ⚠️ Manual only | No remote-config/percentage-rollout mechanism exists. Every stage in `docs/PRODUCTION_ROLLOUT_PLAN.md` (new, this review) is a build-configuration change for a specific device/cohort — never a server-toggleable flag. |

## 4. Release-distribution readiness (found during this review, not previously documented)

- **No App Store Connect / TestFlight pipeline exists.** Every physical-device validation to date has been via `xcodebuild`/`devicectl` direct install with automatic development signing — explicitly documented as "not TestFlight, not App Store" in `docs/INVENTORY_SYNC_PHYSICAL_DEVICE_RESULTS.md`.
- No fastlane, no `ExportOptions.plist`, no provisioning-profile-for-distribution found anywhere in the repo.
- App version is still at its initial placeholder (`MARKETING_VERSION = 1.0`, `CURRENT_PROJECT_VERSION = 1`).

This means "staged production enablement" in this codebase can only mean **staged enablement of a feature flag for a controlled set of already-installed, developer-signed devices** — it cannot yet mean a real TestFlight/App Store rollout, since that pipeline does not exist.

## Pre-release checklist (Stage 4 / GA — not all applicable to earlier stages)

| Item | Status |
|---|---|
| Code freeze | Not yet declared — no release process exists to freeze against. |
| Release branch | Not used — this project develops directly on `main`; no release-branching convention exists yet. |
| Version/build number | `MARKETING_VERSION 1.0` / `CURRENT_PROJECT_VERSION 1` — still the initial placeholder, never bumped for a real release. |
| App Store build | ❌ Does not exist — no signed distribution build has ever been produced. |
| TestFlight canary | ❌ Does not exist — no App Store Connect app record, no TestFlight group. |
| Backend deploy | ⚠️ Managed outside this repo (Render dashboard) — no in-repo deploy verification step. |
| Migration verification | ⚠️ Partial — see §2 (first migration parity-verified, second is not; pgTAP never run). |
| Smoke tests | ✅ exists and passes — `npm run smoke:sync`, hosted `HostedGuestMergeSmokeTests`, full offline `GuestMergeTests` suite (127/127 as of Phase 2B-9B). |
| Rollback rehearsal | ⚠️ Documented (`docs/PRODUCTION_ROLLBACK_RUNBOOK.md`), drills A–F automated-test-verified, but never rehearsed against a real deployed cohort (none exists). |
| Incident owner | ❌ Not designated — no on-call rotation or named owner exists for this project. |
| Monitoring dashboard | ⚠️ Rules defined (`docs/MONITORING_ALERTING_STAGE1.md`), no dashboard/alert-provider connected — see §1. |
| Support communication plan | ❌ Does not exist — no user-facing status page, no support-ticket triage process referencing this feature. |
| Go/No-Go approval | Documented process exists (`docs/INVENTORY_SYNC_FINAL_GO_NO_GO.md`'s explicit sign-off convention), but only ever exercised for engineering conclusions, not a real business/release decision. |

This checklist is almost entirely unmet for a real GA release — consistent
with the final judgment below. Most rows are relevant starting at Stage 3
(broader dogfood) or Stage 4 (GA); Stage 1–2 do not require an App Store
build, TestFlight, or an incident on-call rotation, since they are
sideloaded, developer-supervised cohorts.

## Final judgment

**B. PRODUCTION GO CANDIDATE WITH CONDITIONS**

Not A: real, concrete operational gaps exist (no separate production Supabase
project, no App Store/TestFlight pipeline, pgTAP/migration-parity gap for
the sync migration, no shared/multi-instance rate-limit store, and — while
crash-reporting/monitoring/rate-limiting/min-version-enforcement are all now
*implemented* — none of them is production-configured, and no real
crash-reporting SDK or alert provider is wired up yet). None of these are
correctness defects in the feature itself — Rollback, Conflict UI, and the
remote-preview blocker are all genuinely fixed and physical-device-verified
— but enabling any flag for real, uncontrolled production users today would
mean doing so with no separate production data store, no way to detect an
incident, and no way to force a bad client off the contract.

Not C: none of these gaps require reopening or redesigning the feature
itself. Every gap above is independently addressable, does not implicate
the Guest-merge/sync engine's correctness, and several (rate limiting,
min-version enforcement) are bounded, well-understood pieces of work. The
existing staged-rollout design (`docs/INVENTORY_SYNC_DOGFOOD_PLAYBOOK.md`,
refined into `docs/PRODUCTION_ROLLOUT_PLAN.md` this review) already assumes
a slow, gated cohort expansion — the conditions below map directly onto
which stage each gap must be resolved by, not a blanket blocker on all
further progress.

### Conditions that must be met before advancing past Stage 1 (internal test accounts only)

1. A decision (not necessarily a new Supabase project) on whether Stage 2+
   cohorts may share the current Supabase project, or whether a genuinely
   separate production project must be provisioned first — this is a
   product/business decision, not a code change, and this review does not
   make it.
2. ~~Rate limiting extended to `/api/sync/*` routes.~~ **Done (Phase 2C-1)**
   — implemented, offline- and hosted-development-validated. See
   `docs/SYNC_API_RATE_LIMITING.md`. Not yet production-configured (no
   shared/multi-instance store decision made — in-memory only).
3. ~~Minimum-app-version enforcement implemented (client + server).~~
   **Done (Phase 2C-1)** — implemented, offline- and
   hosted-development-validated. See
   `docs/MINIMUM_APP_VERSION_ENFORCEMENT.md`. Not yet production-configured
   (no actual minimum version/build/schema values have been decided).
4. ~~At minimum a lightweight crash-reporting integration.~~ **Abstraction
   done (Phase 2C-2)** — `NoOpCrashReporter` is wired into every
   merge/rollback/sync flow and a provider (Sentry) is selected, but a real
   SDK/DSN is **not yet integrated**; a manual crash-log-pull process is
   still what exists in practice until that integration happens. See
   `docs/CRASH_REPORTING.md`.
5. pgTAP or an equivalent remote-parity re-verification for the
   sync-foundation migration specifically.

### Conditions before Stage 3+ (broader dogfood / GA)

6. Real monitoring/alerting on at least: sync success rate, mutation
   failure rate, backend 4xx/5xx rate, and crash rate. **Rules defined
   (Phase 2C-2)** in `docs/MONITORING_ALERTING_STAGE1.md`; **no alert
   provider is wired up and no dashboard exists** — this remains open until
   both a real crash-reporting SDK and an alert provider are chosen and
   connected.
7. A TestFlight (or equivalent) distribution pipeline, since sideloaded
   developer-signed installs do not scale past a handful of known devices.
8. A shared/multi-instance rate-limit store (Redis/Upstash or equivalent) —
   the current in-memory limiter is explicitly Stage-1-only (see
   `docs/SYNC_API_RATE_LIMITING.md`).

See `docs/PRODUCTION_ROLLOUT_PLAN.md` and `docs/PRODUCTION_ROLLBACK_RUNBOOK.md`
for the detailed stage design and disaster-recovery plan this review
produced. No flag was changed and nothing was pushed as part of this
review.
