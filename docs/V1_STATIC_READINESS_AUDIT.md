# V1 Static Readiness Audit (Phase 2D-3A)

A **static** production-readiness audit: code/config reading and grep
classification only. No full regression was run, no production project
created, no provider integrated, nothing uploaded, nothing pushed. The
actionable output is `docs/V1_RELEASE_BLOCKERS.md`; this document records
the evidence behind it.

## 1. Git baseline

- `git status --short`: clean.
- `HEAD` = `origin/main` = `0b162ba`; ahead count 0.
- `git diff --check`: clean.
- Committed `ios-native/Kitchen Manager/Config/Shared.xcconfig`: every
  `SYNC_ENABLED` / `SYNC_SMOKE_ENABLED` / `INVENTORY_SYNC_ENABLED` /
  `INVENTORY_MERGE_UI_ENABLED` / `GUEST_MERGE_SMOKE_ENABLED` /
  `INVENTORY_SYNC_DOGFOOD_ENABLED` / `INVENTORY_SYNC_DIAGNOSTICS_ENABLED`
  / `CRASH_REPORTING_ENABLED` = `NO`.

## 2. iOS findings

Scope: `ios-native/Kitchen Manager/KitchenManager/` (production Swift).

- **fatalError / preconditionFailure / assertionFailure**: none. ✅
- **`try!`**: one — `SyncModels.swift:49`
  `static let zero = try! SyncCursorValue("0")`. **Acceptable**:
  `isValid("0")` explicitly returns `true`, so this can never throw on a
  compile-time-constant literal (idiomatic Swift static constant).
- **Force cast (`as!`)**: none in production. ✅
- **`print(`**: 32 occurrences, **all inside `#if DEBUG`** (verified by a
  per-line DEBUG-region scan) — none reach Release. ✅
- **localhost / 127.0.0.1**: only in `APIEnvironment.swift` inside the
  `isLoopbackHost` denylist (`["127.0.0.1", "localhost", "::1",
  "0.0.0.0"]`) — a safety check, not a live endpoint. **False positive.**
- **Debug UI in Release**: `SyncSmokeController` and the two smoke
  harnesses (`SyncSmoke.swift`, `GuestMergeSmoke.swift`) are entirely
  `#if DEBUG` (verified: `#if DEBUG` at file top, `#endif` at file end);
  every `ContentView` reference is `#if DEBUG`-guarded; the UI-test seed
  hook is doubly guarded (`#if DEBUG` + `UITEST_SEED_INVENTORY` launch
  arg). The inventory-sync **diagnostics screen** is runtime-flag-gated
  (`showsDiagnosticsScreen = isDogfoodEnabled && diagnosticsEnabled`,
  from Info.plist keys backed by the two `NO` xcconfig flags), and the
  archive guard hard-asserts those flags are `NO`. **Acceptable** —
  default-off, config-controlled, guard-enforced.
- **Fake/Mock/Stub in production path**: none. The only `Simulated`
  symbol is `sessionRecoveredAfterSimulatedRestart` inside the
  fully-DEBUG-gated `GuestMergeSmoke.swift`. `Unavailable*` matches were
  SwiftUI `ContentUnavailableView` (empty states); the real
  `UnavailableAuthService`/`UnavailableAccountService`/
  `UnavailableAccountDeletionService` are fail-closed fallbacks used by
  the assembly only when config fails to load. **Acceptable.**
- **Account-deletion UX distinction**: `AccountViews.swift` presents
  "退出登录" (footer: does not delete local data) and "删除账号" (footer:
  permanently deletes identity, distinct from sign-out) as separate
  entries; the delete flow is recoverable (failure/pending preserve
  account + local data and force a fresh preview). **Clear separation** —
  confirmed. One operational risk noted: the delete entry is
  unconditional for signed-in users → DEPLOY-SERVICEROLE-001.
- **App icon**: **no `Assets.xcassets` / `AppIcon.appiconset` at all** →
  **APP-ICON-001 (P0)**.
- **PrivacyInfo.xcprivacy**: present at
  `KitchenManager/PrivacyInfo.xcprivacy`. ✅
- **Test credentials in bundle**: no hard-coded secret/token/password
  literals in production Swift; hosted-smoke credentials are read from
  `Local.xcconfig` (gitignored) and tests `XCTSkip` when absent. ✅

## 3. Backend findings

Scope: `src/server/`, `server.js`.

- **console.log/error/warn/debug**: none. ✅
- **process.exit**: none. ✅
- **Empty catch blocks**: 5 — all with explanatory comments and
  deliberate best-effort semantics (`config.js:149` re-parse already
  reported; `jwt.js:101/102` non-decodable-JWT diagnostic context;
  `jwt.js:120` "logging must never break the auth response path";
  `deletion-routes.js:178` best-effort finalize status, retry re-attempts).
  **Acceptable** — none are silent swallows of a control-flow error.
- **Raw error / stack to client**: none — no `res.json/send` returns
  `error.message`/`.stack`. Errors map to stable codes (`SyncError`,
  `AccountDeletionError`) with generic messages. ✅
- **Auth header / bearer / token / `req.headers` logging**: none. ✅
- **Raw email / raw userId logging**: none — only `userHash` (sha256
  prefix) via the `ALLOWED_LOG_FIELDS` allowlist logger. ✅
- **Hard-coded dev URL**: none. The only hard-coded backend URL is the
  env-overridable `OPENAI_BASE_URL` default (`config.js:10`); Supabase
  URLs come from env. ✅
- **Service-role usage**: `SUPABASE_SERVICE_ROLE_KEY` referenced only in
  `config.js` (parse) and `deletion-repository.js`
  `createSupabaseAccountDeletionAdmin` (Auth Admin API delete + finalize
  RPC). Never in the user-scoped repository/routes, never in iOS/PWA/logs/
  CI/docs (name only, no value). ✅
- **Missing env → fail closed**: the JWT verifier throws
  `auth_temporarily_unavailable` when `configErrors.length > 0`
  (`jwt.js:150`); the version gate returns
  `SYNC_VERSION_ENFORCEMENT_MISCONFIGURED` on misconfig. ✅
- **accountDeletionGuard state machine**: reviewed in the Phase 2D-2
  pre-push review — freezes `/api/sync/*` only on
  `requested`/`business_data_cleaned`/`auth_deletion_pending`, fails open
  on transient errors (never blocks other users), persists across restart
  via the ledger row, and does not intercept `/health`/`/ready` or the
  deletion endpoints themselves.
- **Saga resumption**: `account_deletion_requests` persists status, so a
  restart mid-saga is resumable by a client re-confirm; there is **no
  automatic retry worker** → SAGA-RETRY-001 (P2).
- **`/ready` gap**: does not assert service-role presence →
  READY-SERVICEROLE-001 (P2) / DEPLOY-SERVICEROLE-001 (P0 operational).

## 4. Database / RLS findings

Scope: `supabase/migrations/`, `supabase/tests/`.

- **Migration count / immutability**: exactly 3 migrations; the two
  historical ones (`20260713000100`, `20260713000200`) were last touched
  only by their original creating commits — **not modified** by any
  Phase 2D-2 commit. The Phase 2D-2 migration is additive. ✅
- **SECURITY DEFINER search_path**: all **15** SECURITY DEFINER functions
  set `search_path` in their header (per-function scan). ✅
- **Public execute grants**: no function grants `execute` to `public` or
  `anon`; privileged functions revoke from `public/anon` and grant only to
  `authenticated` or `service_role`. ✅
- **RLS completeness, cross-household isolation, zero-owner invariant,
  ownership-transfer atomicity, deletion ledger, anonymization residue**:
  validated by pgTAP in Phase 2D-2 (131/131 across two independent reset
  rounds; `db diff` no drift; residue checks 0). Not re-run here (static
  phase) — referenced from `docs/PHASE2D2_VALIDATION.md`.
- **Production bootstrap**: no production Supabase project exists →
  DB-PROD-001 (P1).

## 5. CI / release findings

Scope: `.github/workflows/`, `scripts/`.

- **Workflows**: `deploy.yml` (PWA static deploy) and
  `ios-release-check.yml` (release validation).
- **`continue-on-error`**: one, on the `ios:archive:guard` step
  (`ios-release-check.yml:62`). **Safe today**: the guard's
  security-critical checks (safe-default flags, no service-role/secrets,
  shared scheme, signing) are independently **hard-asserted** by the
  non-soft `test/phase2d1-ios-release-scripts.test.mjs` step in the same
  job. The soft-fail only masks the known app-icon failure. Latent
  fake-green risk documented as CI-ARCHIVE-GATE-001 (P3).
- **Secrets**: no `secrets.` reference in any workflow. ✅
- **Upload / distribution / TestFlight / App Store Connect**: none (only a
  comment stating the workflow never uploads). ✅
- **Absolute local paths (`/Users/`)**: none. ✅
- **Manual archive job**: `unsigned-archive-validation` runs only on
  `workflow_dispatch`, uses `CODE_SIGNING_ALLOWED=NO`, needs no Apple
  secret, and its failure would be visible (it is not `continue-on-error`).
  ✅
- **Archive guard effectiveness**: `ios-archive-guard.mjs` genuinely
  fails on the missing app icon and would fail on a service-role/secret
  leak into the committed config; the app-icon check rejects trivial
  placeholder images (dimension check). ✅

## 6. Security / privacy findings

- **Hard-coded secret/token/password literals**: none in production code.
- **Skipped/disabled tests**: only the credential-gated hosted-smoke
  tests (`HostedGuestMergeSmokeTests`, `HostedSyncSmokeUITests`) that
  `XCTSkip` when credentials are absent — the source of the 5 skipped iOS
  Unit + 1 skipped UI results seen throughout. Legitimate, not
  failure-hiding.
- **PII in logs**: none (userHash only, allowlist logger).
- **Secrets in CI/docs**: only env-var names, never values.
- **Service-role isolation**: single privileged call site; iOS
  runtime-rejects any key containing `"service_role"`
  (`AuthConfiguration.swift`).

## 7. Internal TestFlight readiness

**No-Go.** Blockers: APP-ICON-001, SIGN-DIST-001, APPSTORE-CONNECT-001,
DEPLOY-SERVICEROLE-001. The app itself builds Debug/Release green and
passes all release-tooling checks except the app icon; the remaining
blockers are artwork, distribution signing, the App Store Connect record,
and ensuring the deployed backend can complete account deletion.

## 8. External TestFlight readiness

**No-Go.** All Internal blockers plus AUTH-REAUTH-001,
AUTH-DELETE-HOSTED-001, BACKEND-PROD-001, DB-PROD-001, PRIVACY-POLICY-001,
SUPPORT-URL-001. Real reauthentication and a hosted-validated,
production-backed account-deletion flow are the substantive engineering
gaps.

## 9. App Store readiness

**No-Go.** All External TestFlight blockers plus APPSTORE-METADATA-001
(screenshots, metadata, age rating, export compliance, content rights,
app privacy answers, demo account) and APP-META-VERSION-001 (deliberate
version/build bump).

## 10. Production readiness

**No-Go / Not Enabled.** Beyond the App Store blockers: OBS-CRASH-001,
OBS-ALERT-001, RATE-SHARED-001, DB-PROD-001 provisioning, SAGA-RETRY-001.
Posture remains **Production Go Candidate With Conditions** — a
code-readiness judgment, explicitly not "Production Enabled." No
production Supabase project, backend, monitoring, or distribution has been
created or validated.

## 11. Exact next action

Highest-leverage, lowest-dependency next steps (in order):

1. **APP-ICON-001** — produce real 1024×1024 app-icon artwork and add
   `Assets.xcassets/AppIcon.appiconset`. This unblocks the archive guard,
   distribution signing validation, and screenshot capture, and is the
   single gate common to every stage.
2. **APPSTORE-CONNECT-001** (USER-ACTION) — register the Bundle ID and
   create the App Store Connect app record; complete Agreements/Tax/
   Banking. Prerequisite for SIGN-DIST-001.
3. **DEPLOY-SERVICEROLE-001** — configure `SUPABASE_SERVICE_ROLE_KEY` on
   the deployed backend (or gate the delete-account UI) before any build
   with the deletion flow reaches a tester; optionally land
   READY-SERVICEROLE-001 as a small `/ready` guard so misconfiguration is
   visible.

None of these are started in this audit-only phase.
