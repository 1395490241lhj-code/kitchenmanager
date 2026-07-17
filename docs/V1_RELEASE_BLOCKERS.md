# V1 Release Blockers

Phase 2D-3A static audit output. Every item below is grounded in a
concrete code/config observation (see "Current Evidence"), not a vague
aspiration. This document is a **static** audit product: it does not
create a production project, integrate any provider, or change release
state. It is the authoritative checklist for what stands between the
current code and each release stage.

Baseline: `HEAD = origin/main = 0b162ba`, workspace clean, all
sync/merge/dogfood/diagnostics/smoke/crash flags `NO` in every committed
configuration.

## Severity / stage legend

- **P0 — Blocks Internal TestFlight** (also blocks everything downstream).
- **P1 — Blocks External TestFlight.**
- **P1 — Blocks App Store Submission** (a superset of External TestFlight).
- **P2 — Strongly Recommended Before GA / Production Enablement.**
- **P3 — Post-Launch.**

"Status" is one of: `OPEN`, `IN-PROGRESS`, `DONE`, `USER-ACTION` (requires
an account-level or manual action outside this repository).

---

## P0 — Blocks Internal TestFlight

### APP-ICON-001 — No app icon / no asset catalog exists
- **Severity**: P0
- **Affected Stage**: Internal TestFlight, External TestFlight, App Store.
- **Current Evidence**: `find ios-native -iname "*.xcassets"` returns
  nothing; `scripts/ios-archive-guard.mjs` `appIconPresence` fails with
  "no AppIcon.appiconset found at all (no Assets.xcassets/asset catalog
  exists yet)". There is no `Assets.xcassets` in the project.
- **Exact Risk**: App Store Connect rejects any build during Processing
  without a 1024×1024 marketing icon — this blocks even Internal
  TestFlight, which still uploads a processed build.
- **Required Action**: Create real, user-approved icon artwork (1024×1024
  + derived sizes) in a new `Assets.xcassets/AppIcon.appiconset`. Do not
  fabricate or use a placeholder solid-color image.
- **Verification Method**: `npm run ios:archive:guard` reports
  `appIconPresence` PASS (the check requires a ≥512×512 real PNG, not a
  trivial placeholder — see the regression tests in
  `test/phase2d1-ios-release-scripts.test.mjs`), then a signed archive's
  Organizer "Validate App" passes.
- **Fallback / Rollback**: None — an icon is mandatory. No rollback needed
  (additive asset).
- **Status**: OPEN (needs design/artwork — USER-ACTION for the artwork
  itself).
- **Dependency**: None.

### SIGN-DIST-001 — Distribution-class signed archive never validated
- **Severity**: P0
- **Affected Stage**: Internal TestFlight, External TestFlight, App Store.
- **Current Evidence**: `docs/PHASE2D1_VALIDATION.md` §4 records that a
  Release archive was produced with **development-class** signing
  (embedded entitlement `get-task-allow = true`), never a distribution
  (Apple Distribution + App Store provisioning profile) archive.
- **Exact Risk**: TestFlight/App Store only accept a distribution-signed
  build; a dev-signed archive cannot be uploaded. Whether Automatic
  Signing can resolve a distribution certificate + App Store profile on
  the configured team is unverified.
- **Required Action**: With the account signed into Xcode and an App Store
  Connect app record present (see APPSTORE-CONNECT-001), produce a
  Release, Generic iOS Device archive and confirm Organizer resolves a
  distribution profile.
- **Verification Method**: Xcode Organizer "Distribute App → App Store
  Connect" reaches the upload step (do not upload during audit phases);
  the embedded entitlements no longer contain `get-task-allow = true`.
- **Fallback / Rollback**: None applicable.
- **Status**: OPEN.
- **Dependency**: APPSTORE-CONNECT-001, APP-ICON-001.

### APPSTORE-CONNECT-001 — No App Store Connect app record / Apple Developer prerequisites
- **Severity**: P0
- **Affected Stage**: Internal TestFlight, External TestFlight, App Store.
- **Current Evidence**: No repository artifact references an app record;
  `docs/TESTFLIGHT_ROLLOUT_PLAN.md` §3 lists this as an unmet manual
  prerequisite.
- **Exact Risk**: Without a registered Bundle ID
  (`com.lianghongjing.kitchenmanager`), an App Store Connect app record,
  and current Agreements/Tax/Banking, no build can be uploaded or
  processed.
- **Required Action** (all account-level, outside this repo): active
  Apple Developer Program membership; register the Bundle ID; create the
  App Store Connect app record; complete Agreements/Tax/Banking.
- **Verification Method**: The app record exists in App Store Connect and
  accepts a build. (Cannot be verified from this repository.)
- **Fallback / Rollback**: None.
- **Status**: USER-ACTION.
- **Dependency**: None.

### DEPLOY-SERVICEROLE-001 — Missing Auth Admin configuration must not start account deletion
- **Severity**: P0 (resolved in code; hosted end-to-end validation remains
  separately tracked by AUTH-DELETE-HOSTED-001).
- **Affected Stage**: Internal TestFlight (and downstream).
- **Current Evidence**: Every account-deletion route now passes through
  `createAccountDeletionAvailabilityGuard` before preview, ownership
  handling, nonce issuance, or `request_account_deletion`. The guard checks
  the server-only Admin capability and returns a stable 503
  `ACCOUNT_DELETION_UNAVAILABLE` when it is absent. No deletion ledger row,
  business-data cleanup, sync freeze, or Auth Admin request can occur first.
- **Exact Risk Addressed**: A backend lacking `SUPABASE_SERVICE_ROLE_KEY`
  can no longer reach the saga's irreversible first step. The signed-in iOS
  user sees a plain "账号删除服务暂时不可用，请稍后再试。" error rather than a
  false confirmation or a partial deletion.
- **Operational Note**: Configure the server-only key on a deployed backend
  before expecting account deletion to succeed. The key remains forbidden in
  iOS/PWA/configuration committed to Git. Missing configuration intentionally
  disables only account deletion; `/health` and ordinary Guest/authenticated
  features remain available.
- **Verification Method**: Node regression covers missing configuration
  before any repository/Admin call, recovery after configuration becomes
  available, and response redaction. Hosted completion is still covered by
  AUTH-DELETE-HOSTED-001.
- **Status**: DONE (safe fail-closed behavior implemented).
- **Dependency**: AUTH-DELETE-HOSTED-001 for hosted completion only.

---

## P1 — Blocks External TestFlight

### AUTH-REAUTH-001 — Real account-deletion reauthentication
- **Severity**: P1 (resolved in code; hosted deletion validation remains
  separately tracked by AUTH-DELETE-HOSTED-001).
- **Current Evidence**: iOS re-enters the active email/password credential
  directly with Supabase. Express verifies Supabase's signed `amr.password`
  timestamp is recent and not older than the deletion preview, then issues a
  five-minute, user-and-preview-bound, single-use proof. Access-token refresh
  cannot satisfy the AMR check. Passwords never reach Express.
- **Provider Scope**: email/password is the only currently enabled provider;
  there is no Apple, Google, magic-link, OTP, or other OAuth entry point.
- **Verification Method**: focused Node/iOS tests cover stale sessions,
  proof TTL/single-use/replay/cross-user/fingerprint rejection, safe failure,
  and successful continuation. Hosted deletion remains untested.
- **Status**: DONE.

### AUTH-DELETE-HOSTED-001 — Account deletion never validated against a hosted backend
- **Severity**: P1
- **Affected Stage**: External TestFlight, App Store.
- **Current Evidence**: `docs/PHASE2D2_VALIDATION.md` §5: the full saga
  (including the Auth Admin API delete) was exercised only against a local
  Docker Supabase; the real hosted development project has no
  `SUPABASE_SERVICE_ROLE_KEY` configured in this environment, so the Admin
  API step was never run against a hosted GoTrue.
- **Exact Risk**: The Admin API delete + `mark_account_deletion_finalized`
  path is unverified against real hosted GoTrue behavior (rate limits,
  error shapes, session invalidation timing). A local simulation is not a
  hosted validation.
- **Required Action**: On a dedicated, disposable hosted test account (not
  a shared fixture), run preview → confirm → Admin delete → finalize end
  to end and confirm `completed` with zero residue and that the old JWT is
  rejected afterward.
- **Verification Method**: Hosted run reaches `completed`; a subsequent
  authenticated request with the deleted user's prior token is rejected by
  Supabase.
- **Fallback / Rollback**: None; this is a validation gap, not a code
  defect.
- **Status**: OPEN.
- **Dependency**: DEPLOY-SERVICEROLE-001.

### BACKEND-PROD-001 — No separate production/staging backend for an external cohort
- **Severity**: P1
- **Affected Stage**: External TestFlight, App Store.
- **Current Evidence**: `docs/IOS_RELEASE_PIPELINE.md` §1 and
  `docs/SUPABASE_ENVIRONMENT_TOPOLOGY.md`: only one backend/Supabase
  environment exists; External TestFlight is "blocked by default" until a
  separate production/staging backend exists.
- **Exact Risk**: A broad external cohort sharing the dev backend can
  pollute or depend on dev data and lacks the "small known cohort"
  property that makes sharing acceptable for Internal testing.
- **Required Action**: Provision and deploy a production (or at least
  staging) backend for the external cohort; point the External build at
  it via the release-time config substitution described in
  `docs/IOS_RELEASE_PIPELINE.md` §1.
- **Verification Method**: External build resolves the production host;
  extend `scripts/ios-archive-guard.mjs` per the planned fail-closed host
  check (documented follow-up).
- **Fallback / Rollback**: Keep External blocked; Internal continues on
  dev.
- **Status**: OPEN.
- **Dependency**: DB-PROD-001.

### DB-PROD-001 — Production Supabase project not provisioned
- **Severity**: P1
- **Affected Stage**: External TestFlight, App Store, Production.
- **Current Evidence**: `PROJECT_STATUS.md` "Remaining rollout
  conditions" #3; only the development project exists. Migrations replay
  cleanly locally (131/131 pgTAP) but have never been applied to a
  production project.
- **Exact Risk**: An App Store / external audience must not share a
  database with dev/test accounts, smoke markers, and unvalidated data.
- **Required Action**: Provision a separate production Supabase project;
  apply the 3 migrations; re-run RLS/pgTAP parity checks against it.
- **Verification Method**: Migration list + remote-verify scripts pass
  against the production project (read-only where possible); pgTAP parity
  confirmed.
- **Fallback / Rollback**: A production migration is forward-only; take a
  snapshot before applying.
- **Status**: OPEN (requires explicit provisioning approval).
- **Dependency**: None.

### PRIVACY-POLICY-001 — No live Privacy Policy URL
- **Severity**: P1
- **Affected Stage**: External TestFlight (Beta App Review), App Store.
- **Current Evidence**: `docs/APP_STORE_METADATA_TEMPLATE.md` lists the
  Privacy Policy URL as a placeholder ("not yet created").
- **Exact Risk**: Beta App Review and App Store submission require a live
  privacy policy that accurately reflects the App Privacy answers
  (account email + household/inventory content for signed-in sync; no
  tracking).
- **Required Action**: Publish a privacy policy at a stable URL matching
  `docs/APP_STORE_METADATA_TEMPLATE.md` §"App Privacy answers"; note the
  backup-retention honesty from `docs/ACCOUNT_DATA_LIFECYCLE.md` §3.
- **Verification Method**: URL is live and reachable; content matches the
  declared data practices.
- **Fallback / Rollback**: None.
- **Status**: USER-ACTION.
- **Dependency**: None.

### SUPPORT-URL-001 — No live Support URL
- **Severity**: P1
- **Affected Stage**: External TestFlight (Test Information), App Store.
- **Current Evidence**: `docs/APP_STORE_METADATA_TEMPLATE.md` Support URL
  is a placeholder. `docs/ACCOUNT_DATA_LIFECYCLE.md` §3 notes it is also
  the only channel for a user to "request further deletion," and it is not
  yet live.
- **Exact Risk**: Required field for External Testing information and App
  Store submission; also the user-facing support/deletion-request contact.
- **Required Action**: Publish a live support URL.
- **Verification Method**: URL live and reachable.
- **Fallback / Rollback**: None.
- **Status**: USER-ACTION.
- **Dependency**: None.

---

## P1 — Blocks App Store Submission (in addition to all External TestFlight blockers)

### APPSTORE-METADATA-001 — App Store listing metadata / review answers not finalized
- **Severity**: P1
- **Affected Stage**: App Store.
- **Current Evidence**: `docs/APP_STORE_METADATA_TEMPLATE.md` and
  `docs/APP_STORE_REVIEW_CHECKLIST.md` contain drafts/placeholders only:
  screenshots not captured (no automation exists), description/keywords
  draft, age rating / export compliance / content rights / app privacy
  answers / demo-account decision not finalized.
- **Exact Risk**: App Store submission is rejected or blocked without
  complete, accurate metadata and questionnaire answers.
- **Required Action**: Capture real screenshots per
  `docs/APP_STORE_REVIEW_CHECKLIST.md` §1 (fictional sample data, no debug
  UI, no TestFlight badge); finalize description/keywords/subtitle; answer
  age rating, export compliance, content rights, and App Privacy in App
  Store Connect; decide demo-account provisioning.
- **Verification Method**: All required App Store Connect fields complete;
  screenshots reviewed for accidental real data.
- **Fallback / Rollback**: None.
- **Status**: OPEN / USER-ACTION.
- **Dependency**: APP-ICON-001 (some captures need the shipped app),
  PRIVACY-POLICY-001.

### APP-META-VERSION-001 — Marketing version / build number are placeholders
- **Severity**: P1 (release-time action; low effort)
- **Affected Stage**: App Store (and any real upload).
- **Current Evidence**: `MARKETING_VERSION = 1.0`,
  `CURRENT_PROJECT_VERSION = 1` (valid but placeholder — see
  `docs/IOS_RELEASE_PIPELINE.md` §3). The build-number ledger
  (`release-build-ledger.json`) starts at 1.
- **Exact Risk**: TestFlight rejects a reused build number; shipping a
  deliberate SemVer marketing version matters for the min-version gate
  alignment.
- **Required Action**: Bump deliberately via `npm run ios:release:bump-build`
  before each real upload; set a deliberate `MARKETING_VERSION`.
- **Verification Method**: `npm run ios:release:check` passes; ledger
  reflects the new build number.
- **Fallback / Rollback**: The bump scripts support `--dry-run`; never
  auto-commit.
- **Status**: OPEN (release-time).
- **Dependency**: None.

---

## P2 — Strongly Recommended Before GA / Production Enablement

### OBS-CRASH-001 — No real crash-reporting provider integrated
- **Severity**: P2
- **Affected Stage**: Production Enablement.
- **Current Evidence**: `docs/CRASH_REPORTING.md`; the iOS `CrashReporting`
  protocol has only a no-op provider; `CRASH_REPORTING_ENABLED = NO`, no
  DSN, no real event ever sent.
- **Exact Risk**: No crash visibility in production.
- **Required Action**: Integrate the selected provider (Sentry), wire the
  DSN via secure config, and update the Privacy Manifest / App Privacy for
  the new third-party data recipient (see
  `docs/ACCOUNT_DATA_LIFECYCLE.md` and `PrivacyInfo.xcprivacy`).
- **Verification Method**: A test crash appears in the provider dashboard;
  privacy declarations updated.
- **Fallback / Rollback**: The no-op provider remains the safe default.
- **Status**: OPEN.
- **Dependency**: None.

### OBS-ALERT-001 — No alerting provider / dashboard connected
- **Severity**: P2
- **Affected Stage**: Production Enablement.
- **Current Evidence**: `docs/MONITORING_ALERTING_STAGE1.md`: alert rules
  documented, no provider/dashboard connected, nothing pages anyone.
- **Exact Risk**: Production incidents go unnoticed.
- **Required Action**: Connect an alert provider to the documented rules
  and `/health`/`/ready`.
- **Verification Method**: A simulated failure pages the on-call channel.
- **Fallback / Rollback**: N/A.
- **Status**: OPEN.
- **Dependency**: BACKEND-PROD-001.

### RATE-SHARED-001 — Sync/account-deletion rate limiters are in-memory (single-instance)
- **Severity**: P2
- **Affected Stage**: Production / GA (multi-instance).
- **Current Evidence**: `src/server/sync/rate-limit.js` uses
  `createMemoryWindowStore()`; `src/server/account/deletion-routes.js`
  uses an in-process `Map`. Both are documented Stage-1 single-instance.
- **Exact Risk**: With more than one backend instance, limits are
  per-instance, weakening protection.
- **Required Action**: Back the limiters with a shared store
  (Redis/Upstash) before horizontal scaling.
- **Verification Method**: Limits hold across instances under test.
- **Fallback / Rollback**: In-memory remains correct for a single
  instance.
- **Status**: OPEN.
- **Dependency**: BACKEND-PROD-001.

### SAGA-RETRY-001 — No automatic retry for a stuck `auth_deletion_pending`
- **Severity**: P2
- **Affected Stage**: External TestFlight / Production (operational).
- **Current Evidence**: `docs/ACCOUNT_DELETION_RUNBOOK.md` §2: recovery is
  a manual/client re-confirm; there is no background worker (by Stage-1
  design).
- **Exact Risk**: A user who abandons the app mid-saga leaves an account
  stuck (business data gone, Auth user present, sync frozen) until manual
  intervention.
- **Required Action**: Either a small scheduled retry/finalize job, or a
  documented operator SOP with monitoring for rows stuck in
  `auth_deletion_pending`.
- **Verification Method**: A deliberately-stuck row is auto- or
  operator-recovered per the SOP.
- **Fallback / Rollback**: The runbook's manual path remains.
- **Status**: OPEN.
- **Dependency**: OBS-ALERT-001 (to detect stuck rows).

### READY-SERVICEROLE-001 — `/ready` exposes Auth Admin capability state
- **Severity**: P2 (resolved in code).
- **Affected Stage**: Production / operational safety.
- **Current Evidence**: `server.js` now adds the boolean
  `checks.account_deletion_configured`, derived from the same Admin
  capability predicate as the deletion routes. A missing key makes `/ready`
  return 503 with that check `false`; its response contains no key, URL,
  token, or stack.
- **Exact Risk Addressed**: Deployment monitoring can distinguish an
  otherwise running service from one whose delete-account capability is
  intentionally unavailable.
- **Verification Method**: Focused Node tests cover the false check,
  response redaction, and the composition-root wiring.
- **Fallback / Rollback**: Additive check; trivially removable.
- **Status**: DONE.
- **Dependency**: None.

---

## P3 — Post-Launch

### CI-ARCHIVE-GATE-001 — Remove `continue-on-error` from the archive-guard CI step once the app icon exists
- **Severity**: P3
- **Affected Stage**: CI hygiene.
- **Current Evidence**: `.github/workflows/ios-release-check.yml:62`
  `continue-on-error: true` on `npm run ios:archive:guard`. It is safe
  today **because** the guard's security-critical checks
  (safe-default flags, no service-role/secrets, shared scheme, signing)
  are independently hard-asserted by the non-soft
  `test/phase2d1-ios-release-scripts.test.mjs` step in the same job
  (lines 208-217). The soft-fail only masks the known app-icon failure.
- **Exact Risk**: Latent fake-green: if someone ever removes those test
  assertions, the soft archive-guard step would no longer surface a new
  security regression.
- **Required Action**: Once APP-ICON-001 is DONE, remove
  `continue-on-error` so the guard self-gates; keep the test-step
  assertions regardless.
- **Verification Method**: A deliberate flag/secret regression turns the
  CI job red.
- **Fallback / Rollback**: Re-add `continue-on-error` if a new legitimate
  soft-fail arises (documented).
- **Status**: OPEN (blocked on APP-ICON-001).
- **Dependency**: APP-ICON-001.

### IPAD-VALIDATION-001 — iPad layout not visually validated
- **Severity**: P3
- **Affected Stage**: App Store quality.
- **Current Evidence**: `docs/APP_STORE_REVIEW_CHECKLIST.md` §1:
  `TARGETED_DEVICE_FAMILY = "1,2"` (iPhone + iPad) but iPad UI has not been
  visually validated.
- **Exact Risk**: Low — cosmetic iPad issues rarely cause rejection, but
  could degrade quality or require an iPad screenshot set.
- **Required Action**: Validate iPad layout, or narrow to `"1"` (iPhone
  only) to reduce launch scope.
- **Verification Method**: iPad simulator/device review.
- **Fallback / Rollback**: Narrowing device family is a one-line pbxproj
  change.
- **Status**: DONE.
- **Dependency**: None.

### LEAVE-HOUSEHOLD-UI-001 — No standalone Leave/Delete-Household UI
- **Severity**: P3
- **Affected Stage**: Post-launch feature completeness.
- **Current Evidence**: `docs/ACCOUNT_DELETION_DESIGN.md` §2: the safe
  leave-household primitive exists in SQL and is exercised by account
  deletion, but no dedicated non-owner "Leave Household" or owner "Delete
  Household" button exists in the UI.
- **Exact Risk**: None for release; a usability/feature gap.
- **Required Action**: Add dedicated UI entry points when prioritized.
- **Verification Method**: UI + tests for the standalone flows.
- **Fallback / Rollback**: N/A.
- **Status**: OPEN.
- **Dependency**: None.

---

## Stage Go / No-Go summary

| Stage | Verdict | Gating blockers |
|---|---|---|
| Internal TestFlight | **No-Go** | APP-ICON-001, SIGN-DIST-001, APPSTORE-CONNECT-001, DEPLOY-SERVICEROLE-001 |
| External TestFlight | **No-Go** | All P0 + AUTH-REAUTH-001, AUTH-DELETE-HOSTED-001, BACKEND-PROD-001, DB-PROD-001, PRIVACY-POLICY-001, SUPPORT-URL-001 |
| App Store Submission | **No-Go** | All External blockers + APPSTORE-METADATA-001, APP-META-VERSION-001 |
| Production Enablement | **No-Go** | All above + OBS-CRASH-001, OBS-ALERT-001, RATE-SHARED-001, DB-PROD-001, SAGA-RETRY-001 |

No stage is Go. The current posture remains **Production Go Candidate
With Conditions** — a code-readiness judgment, never "Production Enabled."
