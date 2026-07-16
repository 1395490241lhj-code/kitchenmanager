# Kitchen Manager Project Guide — English Companion

> This is the concise English companion to `PROJECT_GUIDE.zh.md`. The Chinese guide is the canonical detailed architecture and constraint document. This file must not introduce rules that do not exist there.

Last reorganized: 2026-07-16.

## 1. Architecture summary

Kitchen Manager is a Guest-first, Local-first, dual-client kitchen product:

- Web/PWA: plain HTML, CSS, native JavaScript ES modules, Service Worker, and browser `localStorage`.
- Native iOS: SwiftUI, SwiftData, Keychain, and `supabase-swift`.
- Server: Node/Express for static hosting, AI/extraction/media work, authentication, and sync APIs.
- Cloud foundation: Supabase Auth/Postgres/RLS and an allowlisted sync RPC in the linked development environment.

Account and inventory-sync code exists and has extensive controlled validation. Committed sync-related flags remain safe-off by default, and the project is not broadly production-enabled. Read `PROJECT_STATUS.md` for the current release posture.

## 2. Core product loop

Protect this flow after every change:

1. Record or import inventory.
2. See expiry, availability, and recipe suggestions.
3. Add meals to today/weekly planning.
4. Add missing core ingredients to shopping.
5. Confirm purchased items into inventory.
6. Confirm cooking and inventory deductions.
7. Back up and restore local data.
8. Optionally sign in without harming Guest data.
9. Where explicitly enabled, preview/confirm inventory merge, resolve conflicts, manually sync, and use scoped rollback.

## 3. Subsystem boundaries

### PWA

- Keep the no-framework/no-bundler architecture.
- Views render and bind events; domain modules own matching, scoring, parsing, deductions, and merging.
- Access `localStorage` through `src/storage.js` and `S.keys`.
- Storage-shape changes require migration and backup/restore review.
- User recipe edits go through Overlay; base recipe data stays read-only.
- Preserve hash-route meanings and Service Worker/cache strategy unless explicitly approved.

### Native iOS

- Keep SwiftUI Views free of tokens and persistence secrets.
- Keep business/backup models and SwiftData records separated according to the existing architecture.
- Use injected stores, services, persistence protocols, and the composition root.
- Preserve idempotent migration and retained-legacy/self-healing behavior.
- Sign-in/sign-out must not silently upload, clear, or reassign Guest kitchen data.

### Server and database

- Keep configuration, auth, sync, AI/media, and utility responsibilities separated.
- Preserve JWT/JWKS verification, RLS, direct-DML denial, request limits, SSRF protection, redaction, and route protection order.
- Database migrations must be reviewable, additive where practical, idempotent, and accompanied by verification.

### Sync

- Identity comes from the verified JWT, never a client-supplied user id.
- Preserve household/user scope separation.
- Preserve mutation idempotency, base-version conflicts, string cursor semantics, soft-delete tombstones, and pending-mutation state transitions.
- Guest merge is read-only preview first, explicit confirmation second.
- Do not add automatic/startup/background/Realtime sync or expand synced entities without explicit product and safety approval.
- Keep all sync/merge/smoke/dogfood/diagnostic flags off by default.

## 4. Safety language

Use precise statements:

- “Implemented and validated in the development environment; default off” is acceptable when true.
- “Production enabled,” “fully launched,” or “all data syncs” is not acceptable unless configuration and rollout evidence prove it.
- An old phase report proves a past run, not the current modified working tree.

## 5. Where to read next

- Current state: `PROJECT_STATUS.md`
- AI task routing: `AGENTS.md`
- Detailed architecture: `PROJECT_GUIDE.zh.md`
- Coding constraints: `CODING_RULES.md`
- Verification matrix: `TESTING_RULES.md`
- Task lifecycle: `PROJECT_WORKFLOW.md`
- Stable product intent: `AI_CONTEXT.md`
- Historical evidence: `CHANGELOG.md` and relevant files under `docs/`

When this file conflicts with code or the canonical Chinese guide, verify the code and update this companion rather than creating a second source of truth.
