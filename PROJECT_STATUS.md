# Kitchen Manager — Current Project Status

Last updated: 2026-07-21

This is the single current-state snapshot for humans and AI agents. It is
not a changelog and must remain concise. Implementation detail, test-count
history, device-validation narratives, and bug investigations belong in
`CHANGELOG.md` and the focused documents under `docs/`.

## Current release state

- **Production Go Candidate With Conditions.** Feature-correctness blockers
  for Inventory Sync / Guest Merge are closed and physical-device-validated;
  the surrounding operational readiness is not.
- All sync/merge/dogfood/diagnostic/smoke feature flags remain `NO` in
  every committed configuration and every Release build.
- **Not Production Enabled** — no production cohort, no production Supabase
  project, no production monitoring, and no distribution pipeline exist yet.

## Completed

- Native iOS SwiftUI app with SwiftData persistence for the core kitchen
  modules (inventory, shopping, today plan, consumption, weekly plan, user
  recipes), alongside the original Web/PWA surface (no build pipeline,
  `localStorage`-backed).
- Guest-first email/password auth, Keychain session restore, and
  authenticated `/api/me` household loading (Supabase + Express); sign-in
  never clears/uploads/reassigns local Guest data.
- Inventory sync foundation: authenticated bootstrap/pull/mutation APIs,
  household/user scope separation, idempotency ledger, optimistic version
  conflicts, soft-delete tombstones and change feed.
- Guest inventory merge: remote preview, explicit per-conflict choices,
  identity forking for keep-both, manual sync, rollback, diagnostics, and a
  bounded mutation queue.
- Conflict UI and Rollback both re-validated against a physical device.
- Minimum-app-version enforcement gate for `/api/sync/*` (server + iOS
  client), fail-closed on misconfiguration.
- `/api/sync/*` rate limiting (read + mutation limiters, per-user), backed
  by an in-memory store explicitly scoped to Stage-1 single-instance use.
- Crash-reporting abstraction (iOS `CrashReporting` protocol, event/metadata
  allowlists, no-op default provider) and basic backend observability
  (structured JSON logging, request-correlation id, in-process sync
  metrics, `/health` and `/ready`), all offline-tested and validated against
  a locally-run instance of the code pointed at the real development
  Supabase project.
- Production Supabase topology decision: separate dev+prod project
  recommended; shared project accepted for Stage 1 only (no production
  project created). Migration history and schema/RLS/RPC shape re-verified
  read-only against the development project; environment-misconnection
  safety guards added on both iOS and backend.
- Local Docker-based migration replay and pgTAP execution now pass (2
  independent rounds, 96/96 assertions, zero schema drift) — closes a
  verification gap open since Phase 0.5. No production project involved.
- iOS release pipeline designed and locally validated: shared Xcode
  scheme, unintended macOS/visionOS platform footprint removed, version/
  build-number tooling, pre-archive safety guard, `PrivacyInfo.xcprivacy`,
  App Store metadata/review/TestFlight-workflow templates, and a manual
  CI validation workflow. A real Release archive was built and signed
  locally (development-class signing) — not a distribution-class signed
  archive, no App Store Connect app record exists, nothing was uploaded.
  See `docs/IOS_RELEASE_PIPELINE.md`, `docs/IOS_SIGNING_AND_ARCHIVE.md`,
  `docs/TESTFLIGHT_ROLLOUT_PLAN.md`, `docs/PHASE2D1_VALIDATION.md`. A
  missing app icon remains a real, unresolved blocker for any real
  archive/upload.
- Account deletion implemented and locally validated (Docker-based
  Supabase): server-side identity deletion with household-ownership
  transfer/resolution, business-data anonymization, and an iOS
  Settings/Account/Delete Account flow. Its backend now fails closed before
  any deletion state is created when the server-only Auth Admin capability
  is absent; `/ready` reports that capability without exposing a secret.
  Real email/password reauthentication is required before deletion; the
  backend verifies Supabase-signed recent password AMR metadata and consumes
  a short-lived, single-use proof. Hosted/production validation remains open. See
  `docs/ACCOUNT_DELETION_DESIGN.md`, `docs/ACCOUNT_DATA_LIFECYCLE.md`,
  `docs/PHASE2D2_VALIDATION.md`.
- iOS Home Dashboard Phase 1 now makes today's plan the first visual layer,
  exposes exactly one state-derived prominent action, and shows at most one
  aggregated reminder (stock-in, expired, expiring, shopping, low-stock
  priority). Local data is never gated by auth restoration; existing tabs,
  write paths, stock-in/consumption flows, sync boundaries, and default-off
  flags remain unchanged. See `docs/IOS_HOME_DASHBOARD.md`.
- iOS UI Foundation Phase UI-0 now provides presentation-only feedback
  semantics, correct Inventory success/error iconography, an accurate Home
  Smart Import accessibility label, receipt compact-row selection semantics,
  and a Dynamic-Type-safe receipt fallback. Business state, persistence,
  navigation, sync, and import contracts remain unchanged. See
  `docs/IOS_UI_FOUNDATION_PHASE0.md`.
- iOS Home UI Phase UI-1 now gives Home a calmer native hierarchy: greeting,
  Today Plan, one existing-priority reminder, compact clipboard banner, then
  local issues. Home keeps the existing Smart Import entry, moves Settings
  access to the existing 我的 tab, and adds a contextual Today Plan add action
  without changing Home decisions, stores, navigation, clipboard privacy, or
  import behavior. See `docs/IOS_HOME_UI_PHASE1.md`.
- iOS recipe detail now supports session-only serving scaling and ingredient
  checks, plus a native Cooking Mode with step navigation, foreground timer,
  temporary screen-awake behavior, and explicit Today Plan completion. It
  never auto-deducts inventory or syncs cooking progress; see
  `docs/IOS_RECIPE_COOKING_MODE.md`.
- iOS Shopping now uses a category-first, local-only presentation with a
  compact summary, name search, collapsible purchased items, guarded bulk
  actions, and a session-only Shopping Mode. It reuses the existing recipe
  shortfall and purchased-stock-in behaviors without changing sync or storage;
  see `docs/IOS_SHOPPING_EXPERIENCE.md`.
- iOS Share Import Phase 1 added a native Share Extension
  (`KitchenManagerShareExtension`) so a recipe **URL** shared from Safari,
  Xiaohongshu, YouTube, or any share-sheet-capable app can be handed to
  Kitchen Manager. Scope is URL-only: a plain-text share with no
  http/https URL anywhere in it is rejected inside the extension with a
  clear error and is never queued or handed to the main app — this was
  tightened during review after an earlier draft let bare text through to
  a "no valid link" failure inside Smart Import. The extension only
  classifies input and writes a small request into a new App Group
  (`group.com.lianghongjing.kitchenmanager`, the project's first App
  Group/entitlements usage); it never runs AI parsing, touches SwiftData,
  or accesses the main app's auth session. The main app reads the request
  on next launch/foreground and hands it to the existing, unmodified
  `ImportRecipeView` Smart Import flow (one additive `initialURLText`
  prefill parameter — no second import UI); any request lacking a URL is
  treated as legacy/invalid and discarded rather than presented. Text-only
  AI import is deferred to Share Import Phase 2. See
  `docs/IOS_SHARE_IMPORT.md`.
- Share Extension URL handoff now auto-starts the existing AI import
  pipeline instead of requiring an extra manual "开始导入" tap. Manual
  Smart Import remains user-triggered as before. Draft review and the
  final save remain manual in both cases.
- Active recipe-import network requests are cancelled when the import sheet
  disappears. Cancellation is treated as a silent lifecycle event, not as
  an import failure. Retry, draft review, manual save, and pending-share
  queue semantics remain unchanged.
- iOS Clipboard Recipe Import Phase 1 detects only the system's probable-URL
  clipboard pattern while Home is active, without reading clipboard contents.
  A lightweight Home prompt lets the user explicitly paste through the native
  system paste control, then reuses the existing URL parser and
  `ImportRecipeView` auto-start/cancel/Retry/draft/manual-save pipeline. The
  clipboard version is deduplicated in memory; Share Extension requests keep
  priority and their App Group queue behavior is unchanged. No clipboard
  content is automatically read, stored, queued, or imported. Debug and Release
  both use the production system detector; real cross-app detection and paste
  permission behavior remain manual device validation. See `docs/IOS_SHARE_IMPORT.md`.
- Xiaohongshu video import now uses a stricter page-completeness gate before
  skipping media processing: a long page with broad action words is not enough;
  it must contain multiple independent action segments, multi-stage coverage
  including real cooking, and concrete recipe evidence. Complete page recipes
  remain page-first, ordinary web behavior and no-video fallback are preserved,
  and existing media limits, models, ranking, and cache policies are unchanged.
- Xiaohongshu AI-failure fallback is now evidence-grounded and conservative.
  It isolates transcript/OCR evidence from page recommendations, rejects
  incidental dish-name and compound-word substring collisions, preserves only
  traceable action sentences, leaves missing quantities blank, and always marks
  low-evidence drafts for review. The former dish-specific method templates and
  fabricated `1份`/`1适量` defaults are removed; media extraction, ASR/OCR,
  ranking, cache, and normal AI-success behavior are unchanged.
- Normal final AI recipe results now deterministically retain any structured
  main ingredients or seasonings omitted by the model, appending only exact
  missing evidence items with blank unknown quantities. Existing model details
  win, no names/actions/raw media text are scanned for inference, and bounded
  input inspection, per-item/aggregate budgets, control-character filtering,
  and count/boolean-only preservation diagnostics prevent abnormal evidence
  from creating unbounded response growth. Low-evidence and grounded fallback
  behavior remain unchanged.

## Remaining rollout conditions

1. A real crash-reporting SDK is not integrated — only the abstraction and
   a selected future provider (Sentry) exist; no DSN, no real event has ever
   been sent anywhere.
2. Production monitoring/alerting is not live — alert rules are documented,
   no provider/dashboard is connected, nothing pages anyone.
3. No production Supabase project exists yet — the topology decision is
   made (separate dev+prod recommended), but provisioning it requires
   explicit future approval and must happen before Stage 2.
4. ~~Local Docker-based pgTAP execution~~ — done; all pgTAP passes locally
   and against dev-project read-only checks. Remaining: nothing local left
   to close for this item.
5. ~~No TestFlight/App Store Connect distribution pipeline exists~~ — the
   pipeline is now designed and locally validated (see "Completed"
   above); remaining before real distribution: a real app icon, an App
   Store Connect app record, a distribution-class signed archive, and the
   account-level Apple Developer/App Store Connect prerequisites listed
   in `docs/TESTFLIGHT_ROLLOUT_PLAN.md` §3.
6. The sync rate limiter needs a shared/multi-instance store (Redis/Upstash
   or equivalent) before GA — today's in-memory store is Stage-1-only.
7. A consent/opt-out UI and privacy-label decision for crash reporting is
   not yet designed — deferred until a real provider is chosen, since the
   no-op provider sends nothing.
8. Account deletion (App Store Guideline 5.1.1(v)) is implemented, locally
   validated, and requires real email/password reauthentication, but is not
   hosted/production-validated — hosted validation remains required before
   External TestFlight/App Store submission. See
   `docs/ACCOUNT_DELETION_DESIGN.md` §11.
9. **Phase 1C-E Public Diagnostics Privacy Hardening** remains required for
   pre-existing recipe-import diagnostics: audit all consumers, separate
   internal state from the public response, redact sensitive URL query values,
   and remove or replace raw/trusted/excluded source-text previews without
   breaking canonical URL identity, duplicate detection, source display, PWA
   behavior, or iOS decoding. This debt predates Phase 1C-D.1; its new
   evidence-preservation diagnostics are strictly finite numbers or booleans
   and do not expand that exposure.

A full static production-readiness audit and a stage-by-stage v1 blocker
list now exist: `docs/V1_STATIC_READINESS_AUDIT.md` and
`docs/V1_RELEASE_BLOCKERS.md`. Every release stage (Internal TestFlight,
External TestFlight, App Store, Production) is currently **No-Go**, with
named blockers (IDs like `APP-ICON-001`, `SIGN-DIST-001`,
`AUTH-REAUTH-001`). No new code defect was found
in the audit; the app builds Debug/Release green and passes all release
checks except the missing app icon.

## Next recommended phase

Provision the separate production Supabase project (topology already
decided; local migration/pgTAP validation now proven repeatable) — this is
the remaining prerequisite, independent of further engineering work, before
any real crash-reporting SDK or shared rate-limit store is worth
configuring. In parallel, the user can complete the manual Apple Developer/
App Store Connect prerequisites (`docs/TESTFLIGHT_ROLLOUT_PLAN.md` §3) and
supply a real app icon — both are required before Internal TestFlight can
actually start, independent of the Supabase provisioning work. Feature
expansion to additional synchronized entities should not jump ahead of
this operational readiness work.
