---
name: km-task-routing
description: Use at the start of Kitchen Manager repo work to choose the target surface and minimum relevant code, tests, docs, and canonical context without broad archaeology.
---

# Kitchen Manager Task Routing

Choose the minimum context that can safely answer or implement the task. Do not preload phase history or every canonical document.

## First identify the target surface

Kitchen Manager has four distinct surfaces:
- Web/PWA: native HTML/CSS/JS, Service Worker, `localStorage`.
- Native iOS: SwiftUI, SwiftData, Keychain, `supabase-swift`.
- Express server: static hosting, AI/scraping/media, auth and sync APIs.
- Supabase: Auth, Postgres, RLS and controlled sync RPC in the approved development environment.

Do not transfer client-specific wording, UI behavior, or implementation assumptions between surfaces.

## Minimum task context

Always inspect:
- directly affected code;
- directly affected tests;
- the current branch/worktree relevant to the task;
- the affected call chain, flags, environment and data-loss/security risk.

For meaningful work, invoke `km-project-memory` and read only the relevant canonical notes it routes.

Do not read `PROJECT_STATUS.md` or `package.json` by default. Read them only when the task actually depends on the repo snapshot or Node/package configuration.

## Route by surface

### PWA / browser / localStorage
Read only relevant sections of `docs/architecture/OVERVIEW.md` and `docs/development/CODING.md` or `TESTING.md`. For persistence work, inspect `src/storage.js`, `src/migrations.js`, `src/backup.js`, affected views/components and focused tests.

### Native iOS / SwiftUI / SwiftData
Read only relevant sections of `docs/architecture/OVERVIEW.md` and `docs/development/CODING.md` or `TESTING.md`. Inspect the affected View, business model, persistence protocol/record, store/controller and XCTest/XCUITest path. Use `km-ios-validation` for verification.

For visual/UI work, Kitchen Manager's canonical `UI Design System.md`, accepted Decisions and `docs/design/KITCHEN_DESIGN_LANGUAGE.md` own project-specific intent. Invoke `km-ui` to load only the Apple/SwiftUI/accessibility guidance needed; external guidance never overrides Kitchen Manager product decisions.

### Server / AI / media / extraction
Read `server.js`, affected `src/server/**` modules and tests, plus at most one focused development/service document. Preserve SSRF protection, limits, timeouts, redaction and safe errors.

### Auth / Supabase / sync
Read affected code/tests and only the relevant long-term contract, normally one of `AUTH_SYNC_ARCHITECTURE.md`, `SYNC_API_CONTRACT.md`, `INVENTORY_MERGE_CONTRACT.md`, `INVENTORY_MUTATION_COALESCING.md`, `MINIMUM_APP_VERSION_ENFORCEMENT.md`, or `SYNC_API_RATE_LIMITING.md`. Do not read every historical Phase document.

### Documentation-only
Verify the current code/config/history the document claims to describe. Use `docs/README.md` for ownership and links. Do not synchronize stale claims across multiple files.

## Spec Kit recovery

If a task requires Spec Kit but the generated Codex `speckit-*` skills are missing or unhealthy, read `references/spec-kit-integration.md`. Do not load it for ordinary tasks.

## Investigate proportionally

Follow the full invariant-bearing call chain, but keep archaeology bounded. If new evidence requires materially broader investigation, explain why before expanding. Reuse existing helpers, protocols, tokens, error types and fixtures; do not turn a local task into a repo-wide cleanup.
