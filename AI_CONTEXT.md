# AI_CONTEXT.md

This file gives AI tools stable product and decision context. It intentionally excludes phase-by-phase history and volatile test counts.

## 1. Product identity

Kitchen Manager is a Guest-first, Local-first household kitchen assistant. It helps a person or small household answer practical daily questions:

- What food is available?
- What is expiring or low?
- What can be cooked now?
- What is missing?
- What should be bought?
- What should happen to inventory after cooking?
- How can recipes and receipts be imported with AI without surrendering control?

It is not an enterprise ERP, social network, autonomous nutrition authority, or background data-harvesting service.

## 2. Product principles

### Guest-first

The user must be able to use core local kitchen features without creating an account. Sign-in must not silently upload, clear, merge, or switch local kitchen data.

### Local-first, not local-only

Local device data and offline usability are primary. Optional account/sync infrastructure exists, but cloud behavior must be explicit, scoped, authenticated, reviewable, reversible where promised, and safe when disabled.

### Trust before automation

- AI output is draft data.
- Receipt recognition requires confirmation before inventory writes.
- Imported recipes require review.
- Cooking deductions require user confirmation/calibration.
- Incomplete extraction must remain visibly uncertain.
- Conflicts must not be silently overwritten.
- A “success” UI must be backed by verified persistence/network state when the operation is safety-critical.

### Mobile-first

PWA UI should work around a 390px phone viewport. Native iOS UI should follow SwiftUI platform conventions, accessibility, Dynamic Type, and safe-area behavior rather than mechanically copying browser markup.

### Small, reversible iteration

Prefer focused changes with explicit tests. Do not combine a behavior fix, architecture migration, design overhaul, and unrelated cleanup in one task.

## 3. Current architecture model

### PWA

- Plain HTML/CSS/native JavaScript modules
- Hash routing
- Browser `localStorage` through `src/storage.js`
- User recipe Overlay over read-only base recipe data
- Service Worker/PWA caching
- GitHub Pages-compatible static deployment

### Native iOS

- SwiftUI views
- SwiftData persistence records and migrations
- Codable/Hashable business and backup models
- Keychain-backed auth session
- `supabase-swift` for authentication
- Explicit composition-root wiring rather than Views owning infrastructure secrets

### Express server

- Static hosting
- AI and extraction/media proxying
- JWT verification and `/api/me`
- sync bootstrap/changes/mutations routes
- version gate, rate limiting, payload validation, redacted errors
- structured JSON logging, request correlation id, in-process sync metrics, `/health`/`/ready`

### Supabase

- Auth identities
- profile/personal-household foundation
- household/user-scoped business data
- RLS and direct-DML restrictions
- allowlisted atomic sync RPC
- idempotency, optimistic concurrency, tombstones, and change feed

## 4. Core user journeys to protect

1. Add or import inventory.
2. See expiry/availability and recommendations.
3. Add recipes to today or weekly planning.
4. Put missing core ingredients into shopping.
5. Confirm purchased items into inventory.
6. Confirm cooking and inventory deductions.
7. Back up and restore local data.
8. Optionally sign in without harming Guest data.
9. Where explicitly enabled, preview/confirm inventory merge, resolve conflicts, manually sync, inspect status, and rollback within the supported contract.

## 5. Data ownership and scope

- PWA data uses `S.keys` and migration/backup contracts.
- iOS local business data uses the current store and persistence protocols.
- Auth identity comes from a verified session/JWT.
- Household data and user-scoped preferences must never be conflated.
- Sync currently means the explicitly implemented entity scope, not every local data module.
- Tombstones, versions, mutation ids, and cursors are protocol data, not optional implementation details.
- Secrets and tokens are not business data and must not enter backups, diagnostics, SwiftData, UserDefaults, logs, screenshots, or committed config.

## 6. AI feature boundaries

AI may assist with:

- receipt/image extraction
- recipe drafting/import
- recommendation explanation or candidate ranking
- link/page/media parsing

AI must not:

- invent unsupported source details as facts
- directly mutate inventory without confirmation
- bypass structured validation
- expose prompts, images, credentials, or Authorization headers in unsafe logs
- make cloud-only failure block local kitchen workflows

## 7. Current release posture

Inventory sync and Guest merge have substantial offline, hosted-development, simulator, and physical-device evidence. Known feature-correctness blockers have been addressed. The feature is still gated off by default and operational production prerequisites remain open.

Therefore use precise language:

- Correct: “implemented and validated in development/controlled device runs; default off; production candidate with conditions.”
- Incorrect: “cloud sync is fully launched,” “production is enabled,” or “all app data automatically syncs.”
- A locally-run instance of the backend code, pointed at the real development Supabase project, is a valid **hosted-development validation** — it is never equivalent to validating the actually **deployed** Render service, and must not be described as such.
- Crash reporting is an implemented **abstraction** with a no-op default provider and a selected future provider (not yet integrated) — never describe it as “crash reporting is live” or “monitoring is active.” Basic backend observability (structured logging, request id, metrics, `/health`/`/ready`) is implemented and development-validated; no alert provider or dashboard is connected, and the sync rate limiter's in-memory store is explicitly Stage-1/single-instance only, not multi-instance-safe.
- “Production Go Candidate” is an engineering judgment about feature correctness and operational readiness gaps; it is not “Production Enabled” and must never be conflated with it.

Read `PROJECT_STATUS.md` for the current list of remaining conditions.

## 8. Non-goals unless explicitly requested

- Rewriting the PWA in React/Vue/Svelte/TypeScript or adding a bundler.
- Replacing SwiftUI/SwiftData with another iOS architecture wholesale.
- Enabling automatic/startup/background sync.
- Broadening sync from inventory to other entities without a contract, migration, adapter, UI, rollback, and validation plan.
- Bypassing Express/RPC/RLS with direct client writes.
- Changing storage keys, backup formats, route meanings, or feature-flag defaults casually.
- Treating development Supabase/Render as a fully isolated production environment.
- Adding a heavy dependency for a small local problem.

## 9. Decision heuristics for AI agents

When uncertain:

1. Prefer preserving local data and Guest usability.
2. Prefer an explicit user decision over silent automation.
3. Prefer the existing contract/helper over duplicated logic.
4. Prefer a narrow adapter or test seam over cross-layer coupling.
5. Prefer a safe failure with a useful message over a fake success.
6. Verify current code and tests instead of trusting phase prose or model memory.
