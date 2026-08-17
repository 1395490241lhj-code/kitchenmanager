# Changelog

Only notable changes that have entered `main` are recorded here. Current state belongs in [`PROJECT_STATUS.md`](PROJECT_STATUS.md); detailed evidence belongs in focused documents or Git history.

## 2026-08-16

- Closed the P3 delivery phase at stable checkpoint `21500bc`: P3-A aligned shared recipe-draft eligibility and deterministic fixture isolation; P3-B completed Groq/Gemini text routing and unified `/api/ai-chat` text/vision SDK transport with Groq-only vision; P3-C made post-extraction Import save deterministic and verified at Normal and Accessibility XXXL sizes without network or paid AI.
- Deferred by scope: `Recipe.samples` onboarding/product decision, media OCR frame direct Axios POST, dead `RecipeImportOptionsView`, repo-wide identifier cleanup and hosted Groq/Gemini verification.

## 2026-08-09

- Completed the 《大众川菜》1979 source-restoration closeout for the current scanned-source scope: all 147 entries have an explainable disposition, all 39 eligible new-recipe candidates are promoted, and `applicationReady=false` remains explicit. See the [closeout audit](data/source-restoration/dazhong-chuancai-1979-closeout-audit.v1.md).

## 2026-08-05

- Completed the reviewed recipe quantity/unit pilot and made recipe runtime checks deterministic across locales.
- Improved curated ingredient roles, matching and recommendation cache signatures.
- Made Home local recommendations rotate without repeats while preserving valid recommendation sessions across renders and reloads.

## 2026-08-04

- Stabilized account-deletion reauthentication fixtures without changing the production account-deletion contract.

## 2026-08-03

- Added safe pre-confirm editing of Guest-merge conflict choices, retained stable same-record keep-both reservations and made review read-only after any confirm attempt. See [`docs/archive/ios/IOS_ACCOUNT_LIFECYCLE_UI5B2BB2B.md`](docs/archive/ios/IOS_ACCOUNT_LIFECYCLE_UI5B2BB2B.md).

## 2026-08-01

- Changed the default receipt/vision model to `qwen/qwen3.6-27b` after real iOS requests reached Render but returned `model_not_found`; deployed configuration and live image verification remained external follow-up.
- Improved inventory-based recommendation ranking by core-ingredient coverage and gaps, and limited AI creative results to cases with no reasonable existing recipe candidate.

## 2026-07-31

- Corrected Guest-merge conflict presentation so no option appears selected before a user choice and each choice describes its real consequence.
- Corrected merge-preview summaries, surfaced resolved/skipped/deferred outcomes and added a read-only results review. See [`docs/archive/ios/IOS_ACCOUNT_LIFECYCLE_UI5B2BB1.md`](docs/archive/ios/IOS_ACCOUNT_LIFECYCLE_UI5B2BB1.md) and [`docs/archive/ios/IOS_ACCOUNT_LIFECYCLE_UI5B2BB2A.md`](docs/archive/ios/IOS_ACCOUNT_LIFECYCLE_UI5B2BB2A.md).

## 2026-07-30

- Moved remote Guest-merge preview reads behind the explicit user action and hardened persisted-plan safety.
- Added clear signed-in inventory sync status and recoverable-error presentation without changing sync semantics. See [`docs/archive/ios/IOS_ACCOUNT_LIFECYCLE_UI5B2A.md`](docs/archive/ios/IOS_ACCOUNT_LIFECYCLE_UI5B2A.md) and [`docs/archive/ios/IOS_ACCOUNT_LIFECYCLE_UI5B2BA.md`](docs/archive/ios/IOS_ACCOUNT_LIFECYCLE_UI5B2BA.md).

## 2026-07-29

- Refined the signed-in iOS account overview, household/sync status, error presentation and sign-out hierarchy.
- Reworked iOS Settings information architecture and accessibility while preserving auth, persistence, backup and sync behavior.
- Shipped the category-first iOS Shopping experience with search, purchased-item management and session-only Shopping Mode.

## 2026-07-28

- Shipped accessible native Inventory and Recipe experiences with clearer hierarchy, search, Dynamic Type behavior and floating-tab-bar clearance.
- Added and selected the production 1024×1024 iOS App Icon without changing signing identity or distribution configuration.

## 2026-07-22

- Reworked native Home around today's plan, one priority reminder and local-first content, then corrected visual, localization and accessibility follow-ups.
- Added a shared presentation-feedback semantic for reliable success/error iconography and VoiceOver announcements.

## 2026-07-19

- Preserved structured source ingredients omitted by recipe-import models while keeping unknown quantities blank and bounding evidence processing.

## 2026-07-18

- Hardened Xiaohongshu import completeness checks and made AI-failure fallback evidence-grounded without fabricated quantities or method templates.
- Added privacy-preserving iOS clipboard URL detection and native paste controls that reuse the existing recipe import flow.

## 2026-07-17

- Added the URL-only iOS Share Extension and App Group queue; shared URLs enter the existing review-and-save import flow and never auto-save.
- Added shared-import auto-start and cancellation of active import requests when the sheet disappears.
- Added native Home, Cooking Mode and Shopping Mode product experiences while retaining explicit inventory confirmation.

## 2026-07-16

- Added account deletion with ownership handling, business-data anonymization, recent password reauthentication and fail-closed server Admin-capability checks. See [`docs/contracts/ACCOUNT_DELETION_DESIGN.md`](docs/contracts/ACCOUNT_DELETION_DESIGN.md).
- Added the iOS release scheme, privacy manifest, version/build tooling, archive guard and manual release-check workflow; no App Store upload path was added.
- Replayed Supabase migrations locally and established pgTAP plus remote-parity verification.
- Recorded the separate dev/prod Supabase topology decision and added environment-misconnection guards.
- Added no-op-by-default iOS crash-reporting abstractions and backend structured logging, request IDs, metrics, `/health` and `/ready`.
- Added minimum-app-version enforcement and per-user `/api/sync/*` rate limiting.
- Completed production-readiness, rollout and rollback documentation while keeping all production-sensitive flags disabled.

## 2026-07-15 to 2026-07-12

- Added Guest-first email/password authentication, Keychain session restoration and `/api/me` household loading without automatically uploading, clearing or merging local kitchen data.
- Migrated native inventory, shopping, today/weekly plans, consumption history and user recipes/preferences to SwiftData with idempotent retained-legacy migration and backup compatibility.
- Completed the inventory sync and Guest-merge foundation: authenticated bootstrap/pull/mutations, explicit preview/confirm, conflict choices, mutation coalescing, manual sync, diagnostics and rollback.
- Wired the shipped Guest-merge path to read remote household inventory during preview and added remote-drift protection.
- Fixed a stale-index crash when deleting an inventory item and rollback false-success/per-entity verification defects found during physical-device validation.
- Added bounded queues, fault injection, hosted-development smoke checks and physical-device evidence while preserving default-off flags.

## 2026-07-11

- Expanded the native iOS product from its initial prototype into shared inventory, shopping, planning, recipe, import, receipt, backup and SwiftData-backed flows.
- Added recipe ingredient/seasoning classification, local recipe overlays, native recommendations and explicit AI draft review.
- Made native manual and receipt entry use editable expiry suggestions while preserving dates explicitly changed by the user.

## 2026-07-10

- Added the standalone SwiftUI iOS application and aligned its five-tab navigation with the PWA.
- Added trusted-proxy hop configuration for correct server-side client IP rate limiting.
- Updated weekly planning to support multiple dishes per meal without changing the plan schema.

## 2026-07-09

- Added AI recommendation dislike feedback, safe empty states and protection against temporary creative IDs entering saved plans.
- Fixed local-calendar date handling and migration field preservation.
- Hardened backup validation, added missing user-persistent backup data and made primary storage-write failures visible instead of reporting false success.
- Fixed Service Worker cache ownership and client-IP trust handling.
- Expanded CI validation for pull requests and main deployments.

## 2026-07-08

- Added shared repository guidance and project status/coding/testing documentation for AI coding agents; no runtime behavior changed.
