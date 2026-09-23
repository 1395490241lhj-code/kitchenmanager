# AGENTS.md

This is the single instruction entry point for AI coding agents working on Kitchen Manager. Keep this file limited to durable repository-wide authority, hard boundaries, and workflow routing. Load task procedures through repo Skills instead of growing this file with feature-specific checklists.

## 1. Source of truth

When sources disagree, use this order:

1. Actual code, committed configuration, migrations, generated project files, executable tests, and fresh build/runtime evidence. For Swift/SwiftUI/Xcode-facing work, Xcode is the authoritative build/runtime environment.
2. Canonical Kitchen Manager project memory in the external Obsidian vault for current product state, architecture, Product/IA, UI design rules, Decisions, testing/release posture and next actions.
3. `PROJECT_STATUS.md` as a repo-side point-in-time snapshot, not canonical current state.
4. `docs/product/PRINCIPLES.md` and `docs/architecture/OVERVIEW.md` for stable product and architecture rules.
5. The directly relevant contract, runbook, decision or validation document under `docs/`.
6. `docs/development/CODING.md`, `docs/development/TESTING.md`, and `docs/development/WORKFLOW.md`.
7. `README.md` for human onboarding; `CHANGELOG.md` and archived evidence for history only.
8. Memorix, chat history and model memory as session handoff/scratch only.

Historical evidence proves what was checked then; it does not override current code.

Generated Spec Kit artifacts under `.specify/**` and `specs/**` are bounded feature work products. They do not gain repository-wide authority.

This project-level order overrides generic user-level Memorix rules. A Memorix brief never substitutes for canonical project memory.

## 2. Core operating rules

- Make the smallest correct change.
- Preserve unrelated work and never discard, reset, checkout over, reformat, stage or modify unrelated dirty files.
- Do not perform broad repository archaeology by default. Expand investigation only when concrete evidence makes it necessary.
- Follow the invariant-bearing call chain rather than patching only a visible symptom.
- Reuse existing helpers, protocols, tokens, error types, fixtures and architecture before inventing parallel paths.
- Keep implemented, verified and not verified distinct. Never claim success from source edits or historical evidence alone.
- Prefer executable enforcement for stable invariants. Do not grow `AGENTS.md` with feature-specific acceptance checklists.

Kitchen Manager spans Web/PWA, native iOS, Express server and Supabase. Identify the target surface before transferring any product, UI, persistence or validation assumption between clients.

## 3. Canonical project memory and anti-drift

For meaningful implementation, architecture, product, UI, testing, release or documentation work, use `km-project-memory` before trusting current project state or accepted decisions.

The vault is external to the repository. If it is unavailable or its identity cannot be verified, enter degraded mode through that Skill rather than inventing state or creating a substitute.

Do not silently overturn an Active Decision or a test-enforced product contract. If implementation evidence conflicts with one:

1. stop scope expansion;
2. identify the concrete evidence;
3. identify the affected Decision/contract;
4. state the minimum affected scope;
5. propose the smallest resolution.

A Decision changes through a new explicit Decision, never by quietly ignoring the old one.

Do not copy volatile stable/open feature lists into this file. Current product state belongs in canonical memory, focused design/contract docs and executable tests.

## 4. Workflow routing

Use the smallest applicable project Skill:

- `km-task-routing` — choose the target surface and minimum code/tests/docs/canonical context.
- `km-project-memory` — verify/read/reconcile canonical Obsidian project memory and handle degraded mode.
- `km-ios-validation` — drive and report Swift/SwiftUI/Xcode validation through Xcode MCP or the documented fallback.
- `km-acceptance` — define bounded acceptance, evidence floors, review/escalation needs, stop conditions, and optional Jev routing for ambiguous non-trivial work.
- `km-delivery` — final diff review, truthful reporting, authorized commit/push actions and post-work memory reconciliation.
- `km-ui` — route native UI work to the minimum Apple HIG, SwiftUI and accessibility guidance required.

For Kitchen Manager UI work, project-specific design intent comes from canonical `UI Design System.md`, accepted Decisions and `docs/design/KITCHEN_DESIGN_LANGUAGE.md`. Use `km-ui`; external Apple/SwiftUI/accessibility guidance never overrides Kitchen Manager decisions.

Third-party Skills installed from `skills-lock.json` and Spec Kit generated Skills are regenerable local tooling. Kitchen Manager-owned `.agents/skills/km-*` Skills are committed repository workflow sources.

## 5. Validation and acceptance

Validation follows impact, not file count.

`docs/development/TESTING.md` owns concrete test selection. `docs/development/WORKFLOW.md` owns task execution and retry limits. `docs/development/AI_CODING_ACCEPTANCE_MATRIX.md` owns risk-to-evidence routing for non-trivial AI coding work.

For applicable iOS work, Xcode is authoritative. Use `km-ios-validation`; if Xcode MCP is unavailable, report that fact and use the supported `xcodebuild` fallback rather than fabricating MCP evidence.

For non-trivial implementation, use `km-acceptance` to establish a bounded contract. Stop rather than widen scope when progress requires an unapproved Decision change, hard-boundary change, environment/capability write, migration, hosted mutation, credential change, or repeated same-root-cause attempts without new evidence.

## 6. Hard boundaries

Do not change these without explicit approval and a compatibility/migration plan where applicable:

- PWA hash routes, bottom navigation, `S.keys`, schema, migrations or backup contract;
- user-recipe Overlay precedence or base-recipe immutability;
- iOS business-model/SwiftData migration compatibility;
- Keychain/session/secret-storage assumptions;
- signing identities, Apple accounts, provisioning profiles, entitlements or capabilities — never change these merely to make a build/test pass;
- household/user scope, RLS, cursor/version/idempotency/tombstone contracts;
- default-off sync, merge, smoke, dogfood, diagnostics or production-safety flags;
- startup, login, timer, background or Realtime sync behavior;
- verified-JWT identity derivation;
- GitHub Pages, Service Worker, package manager, lockfile, major folders or framework architecture.

Never silently enable production writes, target an unapproved environment, use service-role credentials in clients, expose secrets, or describe development evidence as production rollout approval.

Do not commit, push, open a PR, deploy, apply migrations, change hosted configuration, enable flags or touch real user data unless explicitly requested.

## 7. Spec Kit

Spec Kit is a bounded feature-level workflow layer. It never overrides this file, implementation evidence, canonical project memory, accepted Decisions, design language, architecture/contracts, testing ownership or hard boundaries.

Use Spec Kit for medium/large bounded features, migrations, data-model changes, sync/auth/provider-routing changes, architecture work and similarly high-risk work. Skip it for focused bug fixes, copy changes, contained refactors and ordinary documentation.

Do not retroactively specify the existing application, and do not copy volatile project status into the Spec Kit constitution.

Generated task lists or `/speckit-*` workflows do not authorize commit/push/PR/deploy/migration/hosted configuration or real-data actions.

## 8. Delivery

Use `km-delivery` before closing meaningful repository work.

Final reporting must name the files changed, current validation actually obtained, important checks not run, data/security/environment effects, and remaining risks or follow-up. Never infer a broader pass from a narrower run or from an older report.

For iOS implementation work, report the actual Xcode evidence: build outcome, diagnostics, tests run/results, visual Preview/render inspection where relevant, and whether validation used Xcode MCP or xcodebuild fallback.
