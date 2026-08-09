# AGENTS.md

This is the single instruction entry point for every AI coding agent working on Kitchen Manager. Route to the smallest relevant context; do not preload phase history.

## 1. Source of truth

When sources disagree, use this order:

1. Actual code, committed configuration, migrations, generated project files, and executable tests.
2. `PROJECT_STATUS.md` for current state and release posture.
3. `docs/product/PRINCIPLES.md` and `docs/architecture/OVERVIEW.md` for stable product and architecture rules.
4. The directly relevant contract, runbook, decision, or validation document under `docs/`.
5. `docs/development/CODING.md`, `docs/development/TESTING.md`, and `docs/development/WORKFLOW.md`.
6. `README.md` for human onboarding.
7. `CHANGELOG.md` and historical evidence for past changes only.
8. Chat history or model memory.

Historical evidence proves what was checked then; it does not override current code.

## 2. Minimum reading

For an ordinary task, read only:

- `AGENTS.md`;
- `PROJECT_STATUS.md`;
- `package.json`;
- directly affected code;
- directly affected tests;
- at most one or two relevant topic documents below.

Inspect the current branch, worktree, call chain, feature flags, environment and data-loss risk before editing. Preserve unrelated work.

## 3. Task routing

### PWA / browser / localStorage

Choose the relevant sections of:

- `docs/architecture/OVERVIEW.md`;
- `docs/development/CODING.md` or `docs/development/TESTING.md`.

When persistence changes, inspect `src/storage.js`, `src/migrations.js`, `src/backup.js`, affected views/components and focused tests.

### Native iOS / SwiftUI / SwiftData

Choose the relevant sections of:

- `docs/architecture/OVERVIEW.md`;
- `docs/development/CODING.md` or `docs/development/TESTING.md`.

Inspect the affected View, business model, persistence protocol/record, store/controller and XCTest/XCUITest files.

### Server / AI / media / extraction

Read `server.js`, affected `src/server/**` modules and tests, plus at most one of:

- `docs/development/CODING.md`;
- the focused service contract/design document.

Preserve SSRF protection, limits, timeouts, redaction and safe errors.

### Auth / Supabase / sync

Read the affected code/tests and select only the relevant long-term contract, normally one of:

- `docs/AUTH_SYNC_ARCHITECTURE.md`;
- `docs/SYNC_API_CONTRACT.md`;
- `docs/INVENTORY_MERGE_CONTRACT.md`;
- `docs/INVENTORY_MUTATION_COALESCING.md`;
- `docs/MINIMUM_APP_VERSION_ENFORCEMENT.md`;
- `docs/SYNC_API_RATE_LIMITING.md`.

Use a latest validation document only when the task depends on its exact evidence. Do not read every Phase file.

### Documentation-only

Read the code/config/history that the document claims to describe. Verify links and ownership using `docs/README.md`; do not synchronize stale claims across multiple files.

## 4. Hard boundaries

Do not change these without explicit approval and a compatibility/migration plan where applicable:

- PWA hash routes, bottom navigation, `S.keys`, schema, migrations or backup contract;
- user-recipe Overlay precedence or base-recipe immutability;
- iOS business-model/SwiftData migration compatibility;
- Keychain/session/secret-storage assumptions;
- household/user scope, RLS, cursor/version/idempotency/tombstone contracts;
- default-off sync, merge, smoke, dogfood, diagnostics or production-safety flags;
- startup, login, timer, background or Realtime sync behavior;
- verified-JWT identity derivation;
- GitHub Pages, Service Worker, package manager, lockfile, major folders or framework architecture.

Never silently enable production writes, target an unapproved environment, use service-role credentials in clients, expose secrets, or describe development evidence as production rollout approval.

Do not commit, push, open a PR, deploy, apply migrations, change hosted configuration, enable flags or touch real user data unless explicitly requested.

## 5. Required final report

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

List unrun tests and the exact next command. Never infer a pass from an older report.
