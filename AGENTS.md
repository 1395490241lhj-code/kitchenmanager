# AGENTS.md

This file is the single entry point for every AI coding agent working on Kitchen Manager: Codex, Claude Code, Cursor, Cline, Copilot, Gemini CLI, and future tools.

Its purpose is to route an agent to the smallest relevant context, not to duplicate the entire repository history.

Last reorganized: 2026-07-16.

## 1. Source of truth

When sources disagree, use this order:

1. Actual code, committed configuration, database migrations, generated project files, and executable tests.
2. `PROJECT_STATUS.md` for the current project state and release posture.
3. `PROJECT_GUIDE.zh.md` for the canonical detailed architecture and constraints.
4. Scoped design/contract/validation documents under `docs/` for the subsystem being changed.
5. `CODING_RULES.md` and `TESTING_RULES.md`.
6. `PROJECT_WORKFLOW.md`.
7. `PROJECT_GUIDE.md` as the English companion summary.
8. `README.md` for human onboarding.
9. `CHANGELOG.md` and historical phase documents for change history only.
10. Chat history, model memory, or prior summaries.

Repository facts always beat AI memory. A historical validation document proves what was tested at that time; it does not automatically describe current code after later changes.

## 2. Minimum reading before any change

Always read:

- `AGENTS.md`
- `PROJECT_STATUS.md`
- `package.json`
- the directly affected source files
- the directly affected tests

Then read only the relevant route below.

### PWA / browser / localStorage task

Read:

- relevant sections of `PROJECT_GUIDE.zh.md`
- `CODING_RULES.md` PWA, data, UI, security, and cache sections
- `TESTING_RULES.md` PWA section
- `src/storage.js` when persistence is touched
- `src/migrations.js` and `src/backup.js` when a stored shape changes
- the relevant `src/views/*`, `src/components/*`, and domain modules

### Native iOS / SwiftUI / SwiftData task

Read:

- `AI_CONTEXT.md`
- relevant sections of `PROJECT_GUIDE.zh.md`
- `CODING_RULES.md` iOS, persistence, auth, and security sections
- `TESTING_RULES.md` iOS section
- the affected Swift model, persistence protocol/record, store/controller, view, and XCTest/XCUITest files

### Server / AI / media / extraction task

Read:

- `server.js`
- the related modules under `src/server/**`
- relevant security and AI rules in `CODING_RULES.md`
- related Node tests

Preserve SSRF protection, rate limits, timeout/error handling, and secret redaction.

### Auth / Supabase / sync task

In addition to the affected code and tests, read the relevant documents among:

- `docs/AUTH_SYNC_ARCHITECTURE.md`
- `docs/SYNC_SCHEMA_PHASE2A.md`
- `docs/INVENTORY_MERGE_CONTRACT.md`
- `docs/INVENTORY_MUTATION_COALESCING.md`
- `docs/MINIMUM_APP_VERSION_ENFORCEMENT.md`
- `docs/SYNC_API_RATE_LIMITING.md`
- `docs/PRODUCTION_ENABLEMENT_READINESS.md`
- the latest validation document for the exact phase or behavior

Do not read every phase document by default. Read the contract plus the latest directly relevant evidence.

### Documentation-only task

Read the code/configuration that the document claims to describe. Do not “synchronize” stale statements across many files without first verifying the implementation.

## 3. Project facts that must not be forgotten

Kitchen Manager is a Guest-first, Local-first, dual-client kitchen product.

- Web/PWA: plain HTML, CSS, and native JavaScript ES modules; no frontend framework or bundler.
- PWA persistence: browser `localStorage`, centralized through `src/storage.js` and `S.keys`.
- Native iOS: SwiftUI, SwiftData, Keychain, and `supabase-swift`.
- Server: Node/Express for static hosting, AI/link/media services, auth, and sync endpoints.
- Cloud foundation: Supabase Auth/Postgres/RLS in the linked development environment.
- Tests: Node built-in test runner plus XCTest/XCUITest.
- Package manager: npm with `package-lock.json`.
- Core local features must remain usable in Guest mode.
- Inventory sync/Guest merge infrastructure exists and has substantial validation, but committed feature flags remain off by default and the feature is not broadly production-enabled.

“Local-first” does not mean “cloud code does not exist.” It means local use and data ownership remain primary, and cloud behavior must be explicit, scoped, reviewable, and safely disabled.

## 4. Hard boundaries

Do not change these without explicit user approval and a migration/compatibility plan where applicable:

- PWA hash-route meanings or bottom navigation semantics.
- Existing `S.keys` strings, PWA schema, migration behavior, or backup contract.
- User recipe Overlay precedence or base recipe immutability.
- iOS business-model/SwiftData migration compatibility.
- Keychain/session handling or secret-storage assumptions.
- Household/user scope semantics, RLS assumptions, sync cursor/version/idempotency/tombstone contracts.
- Default-off sync, merge, smoke, dogfood, diagnostics, or production-safety flags.
- Automatic/startup/background sync behavior.
- Authentication identity derivation: server identity comes from the verified JWT, never a client-supplied user id.
- GitHub Pages or Service Worker strategy.
- Package manager, lockfile strategy, or major folder structure.
- A broad architecture/framework migration.

Never silently enable production writes, point tests at an unapproved environment, use a service-role key in client code, or treat a development smoke result as production rollout approval.

## 5. Working contract

For every task:

1. Inspect repository state and the relevant call chain before editing.
2. Classify the affected surface: PWA, iOS, server, database, sync, shared data contract, tests, or docs.
3. State the smallest safe implementation plan when the task is non-trivial.
4. Preserve unrelated behavior and avoid opportunistic refactors.
5. Add or update tests for logic, persistence, security, migrations, or regressions.
6. Run the relevant matrix in `TESTING_RULES.md`; never overstate coverage.
7. Check secrets, feature flags, environment targeting, and data-loss risk.
8. Update documentation only where responsibility belongs.
9. Report exact files, commands, results, manual checks, assumptions, and remaining risks.

Commit, push, deploy, change hosted configuration, apply a migration, enable a feature flag, or touch real user data only when the user explicitly requested that action.

## 6. Documentation ownership

- `PROJECT_STATUS.md`: current snapshot only; no long phase narrative.
- `CHANGELOG.md`: concise history of notable changes.
- `docs/*PHASE*` and validation files: immutable or append-only engineering evidence for that phase.
- `PROJECT_GUIDE.zh.md`: stable architecture and invariant rules.
- `CODING_RULES.md`: coding constraints.
- `TESTING_RULES.md`: verification policy and commands.
- `README.md`: human onboarding.
- `AI_CONTEXT.md`: stable product intent and decision boundaries.
- `CLAUDE.md` and `.cursorrules`: thin pointers to this file; do not duplicate project facts there.

Do not paste the same phase report into `PROJECT_STATUS.md`, `AI_CONTEXT.md`, `PROJECT_WORKFLOW.md`, and `CHANGELOG.md`.

## 7. Required final report

Use this structure after a code or documentation change:

```text
Summary:
- ...

Changed files:
- ...

Validation:
- Command: ...
  Result: ...
- Manual checks: ...

Data / security / environment:
- ...

Risks / assumptions / follow-up:
- ...

Documentation updated:
- PROJECT_STATUS.md: yes/no/not applicable
- CHANGELOG.md: yes/no/not applicable
```

If a test was not run, say why and provide the exact next command. Never replace “not run” with an inferred pass based on an older report.
