# CODING_RULES.md

These rules apply to Kitchen Manager across Web/PWA, native iOS, Express, Supabase, authentication, and synchronization.

## 1. General principles

- Protect user data before optimizing convenience.
- Keep changes focused, reversible, and reviewable.
- Preserve Guest-mode local usability.
- Prefer existing contracts and helpers over duplicate logic.
- Keep UI, domain, persistence, transport, and database responsibilities separated.
- Do not refactor unrelated files or change architecture as a side effect.
- A safe, visible failure is better than a fake success.
- Tests and documentation must describe the behavior that actually exists.

## 2. Existing technology is allowed; unapproved expansion is not

Current architecture includes:

- plain HTML/CSS/native JavaScript PWA
- Node/Express/Axios/JOSE/ffmpeg-static
- SwiftUI/SwiftData/Keychain/supabase-swift
- Supabase Auth/Postgres/RLS and sync RPC

Do not use obsolete rules to remove or reject existing database, login, sync, or native iOS code.

Still require explicit approval for:

- React/Vue/Svelte/Angular, TypeScript, Vite/Webpack/Rollup, Tailwind runtime, or another PWA architecture migration
- a wholesale iOS architecture/persistence/auth rewrite
- a second database or bypass of the current Express/Supabase contract
- automatic/startup/background/Realtime sync
- synchronizing additional entity families
- broad UI redesigns or major folder moves
- heavy dependencies for small tasks

## 3. PWA rules

### Structure

- `app.js` initializes, migrates, loads packs, routes, and composes views.
- `src/views/*` renders pages and binds page-level events.
- `src/components/*` owns reusable UI flows.
- domain/service logic belongs in focused modules such as inventory, ingredients, recommendations, shopping, staples, AI, backup, and migrations.
- do not duplicate business rules inside DOM handlers.

### Storage and data

- use `S.load`, `S.save`, and `S.keys` from `src/storage.js`;
- do not add raw `localStorage.getItem/setItem('km_...')` in feature code;
- do not rename keys or break shapes without migration and tests;
- migration failure must not clear user data;
- review backup/export/restore for every persisted field;
- keep API keys/tokens out of backups;
- keep user recipe edits in Overlay, not base recipe JSON;
- inspect fixed-field loaders when adding shopping fields so refresh does not drop them.

### DOM and security

- escape dynamic HTML and attribute values with existing helpers;
- avoid string-building untrusted URLs or event handlers;
- do not expose server secrets in frontend config;
- retain useful inline error/fallback states.

### UI and cache

- design for about 390px first;
- support light/dark themes and touch interaction;
- reuse existing CSS tokens and semantic classes;
- translate Tailwind-like design descriptions into project CSS rather than pasting utility strings;
- after browser-imported JS/CSS changes, use the version-stamping workflow;
- change Service Worker strategy/cache names only when justified.

## 4. Native iOS rules

### Swift and SwiftUI

- keep Views declarative and free of network tokens/persistence secrets;
- resolve mutable collection elements by stable id instead of long-lived captured indices;
- keep business rules in testable models, stores, controllers, services, or pure helpers;
- use `@MainActor` where UI-observable state and persistence architecture require it;
- treat Sendable/concurrency warnings as design feedback, not noise to suppress casually;
- preserve accessibility labels, Dynamic Type, dark mode, safe areas, and reasonable hit targets;
- confirm destructive actions and surface actionable errors.

### SwiftData and local persistence

- use the repository's shared schema/factory and in-memory test containers;
- keep business/backup models and persistence records mapped explicitly;
- update every current field when adding/changing a model;
- make migrations idempotent and verify before writing completion markers;
- retain legacy fallback/self-healing behavior unless an explicit migration plan changes it;
- explicit clear-all must clear both active persistence and retained fallback so data cannot reappear;
- audit multiple `ModelContext` writes for ordering, transaction, and rollback risk;
- do not silently change backup-version scope when moving a module to SwiftData.

### Authentication

- store sessions in Keychain through the existing auth service;
- never store access/refresh tokens in SwiftData, UserDefaults, Views, published models, diagnostics, or logs;
- acquire a fresh token per request from the live auth state where current code requires it;
- sign-out must starve later requests rather than reuse a captured token;
- account failure must not block local Guest features;
- login/logout must not auto-upload, clear, or switch local kitchen data.

## 5. Server rules

- keep `server.js` as composition/entry rather than a dumping ground;
- keep config, auth, sync, AI/media, extraction, rate limits, and utilities in focused modules;
- validate body size, item count, types, identifiers, URLs, and upstream output;
- keep timeouts and graceful failure paths;
- preserve SSRF protection and redirect/address checks;
- preserve CORS/security assumptions unless deployment requirements are explicit;
- return stable safe error codes; avoid leaking internal stacks, credentials, Authorization, prompts, images, or database details;
- production logs must be redacted and low-sensitivity.

## 6. Supabase and migration rules

- migrations under `supabase/migrations` are the versioned source of truth;
- prefer additive, idempotent changes and explicit constraints/indexes;
- inspect grants, RLS policies, triggers, functions, and rollback/recovery implications together;
- direct client DML to protected business tables remains denied;
- never use a service-role key in the PWA or iOS app;
- do not apply a migration or target a hosted project without explicit environment confirmation;
- add SQL/remote verification for security- or contract-relevant changes.

## 7. Sync protocol rules

### Identity and scope

- derive user identity from the verified JWT subject;
- reject client attempts to forge user identity;
- keep household and user scopes independent;
- validate membership, entity type, operation, payload, and scope on every write.

### Mutation contract

- preserve mutation id, entity id, base version, operation, scope, and payload semantics;
- retries must be idempotent;
- conflicts/rejections must remain visible and retry-safe;
- deletes are tombstones/soft deletes under the current contract;
- cursor values remain arbitrary-precision strings;
- do not advance a cursor past unapplied local state or delete pending work before authoritative success.

### Local staging

- stage SyncMetadata and PendingMutation through the centralized persistence API;
- preserve current create/update/delete coalescing rules;
- never lose deletes because of queue limits;
- avoid staging duplicate operations when an entity is already confirmed deleted;
- keep conflict resolution separate from network application when the contract defines a review step.

### Guest merge and rollback

- preview must be read-only and authenticated when remote data is required;
- no automatic conflict resolution;
- keepLocal, keepRemote, keepBoth, and skip retain their documented semantics;
- same-id keepBoth uses a persisted stable fork id;
- plan hash/revalidation must prevent stale confirmation;
- rollback targets only entities created by that merge session and must verify per-entity authoritative state before reporting success.

### Feature gates

- committed defaults for sync/merge/smoke/dogfood/diagnostics remain `NO` unless an approved rollout task changes them;
- Release configuration must not accidentally inherit local test flags;
- no startup/login/timer/background/Realtime hook without explicit approval;
- restore local ignored flags after smoke/device tests and verify the compiled configuration when relevant.

## 8. AI feature rules

- AI output is draft data;
- use existing structured validation and sanitization;
- preserve source uncertainty and warnings;
- never auto-update inventory from AI output;
- require review before recipe save or receipt stock-in;
- keep manual/text/local fallbacks available;
- avoid sending broad kitchen data when a narrower prompt/input is sufficient;
- never hardcode, commit, log, or export real API keys.

## 9. Dependency rules

Before adding a dependency, document:

1. the concrete need;
2. why the platform or existing code is insufficient;
3. runtime/build/binary-size impact;
4. PWA static deployment impact;
5. iOS package/signing impact where applicable;
6. security and maintenance implications;
7. tests and rollback/removal plan.

Keep `package-lock.json` consistent with npm changes. Do not mix package managers.

## 10. Test and delivery rules

- add a focused regression test for a confirmed bug when practical;
- run the matrix in `TESTING_RULES.md` for every affected subsystem;
- do not shrink a suite or delete coverage merely to make CI pass;
- distinguish local, simulator, hosted-development, physical-device, and production evidence;
- report exact commands, results, skipped tests, flags, environment, remote writes, cleanup, and untested areas;
- update `PROJECT_STATUS.md` only when current state changes and `CHANGELOG.md` when a notable change occurs.
