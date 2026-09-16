# Kitchen Manager / 厨房管理

> A guest-first, local-first kitchen manager for household inventory, recipes, meal planning, shopping, and cooking.

Kitchen Manager is an open-source household kitchen management project with four connected surfaces:

- **Native iOS** — SwiftUI, SwiftData, and Keychain
- **Web / PWA** — native HTML, CSS, JavaScript, Service Worker, and `localStorage`
- **Express server** — AI, media/extraction, authentication, and sync APIs
- **Supabase** — authentication, Postgres, RLS, and the development foundation for controlled inventory sync

The product is designed so that its core local workflows remain useful without requiring an account. AI output is treated as a draft, and consequential actions such as imports, inventory changes, and cooking deductions remain reviewable by the user.

**中文简介：** Kitchen Manager 是一个 Guest-first、Local-first 的家庭厨房管理项目，覆盖库存、临期食材、菜谱、今日/周计划、购物清单和烹饪流程。PWA 与原生 iOS 的核心本地能力均可在 Guest 模式下使用。

> **Project status:** the repository contains working PWA and native iOS clients plus auth/sync foundations, but production sync and related operational flags are intentionally disabled in committed configuration. For the current release posture, see [`PROJECT_STATUS.md`](PROJECT_STATUS.md).

## Why this project exists

Kitchen Manager is built around a few practical product and engineering constraints:

- **Guest-first / local-first** — useful kitchen workflows should not depend on account creation or a remote service.
- **Trust before automation** — AI-assisted extraction and generation produce reviewable drafts rather than silently changing user data.
- **Explicit data boundaries** — local persistence, authentication, sync, merge, and remote writes have separate contracts and validation paths.
- **Multi-client consistency without forced sameness** — the PWA and native iOS app share product principles while keeping platform-appropriate UI and implementation details.
- **Maintainable, evidence-driven development** — repository rules, focused regression tests, and platform-native validation are used to keep changes auditable.

## Agent-assisted development

This repository is also used to develop and document a disciplined workflow for working with coding agents on a real multi-surface application.

[`AGENTS.md`](AGENTS.md) is the single instruction entry point for coding agents. It defines source-of-truth ordering, task routing, safety boundaries, validation expectations, and rules for preserving unrelated work.

Agent-assisted changes are expected to follow the same engineering constraints as human-authored changes:

1. inspect the affected implementation and tests before editing;
2. make the smallest coherent change;
3. preserve local-first, confirmation, privacy, and safe-default invariants;
4. run validation proportional to the affected surface;
5. inspect the final diff and report exactly what was and was not verified.

For Swift / SwiftUI / Xcode-facing work, the repository treats Xcode itself as the authoritative build and runtime validation environment when the Xcode MCP bridge is available. Test selection remains governed by [`docs/development/TESTING.md`](docs/development/TESTING.md).

The detailed incremental workflow is documented in [`docs/development/WORKFLOW.md`](docs/development/WORKFLOW.md).

## Core capabilities

### Inventory and kitchen state

- household inventory and staple tracking
- expiry / attention workflows
- explicit inventory changes and cooking deductions
- backup / restore foundations

### Recipes and cooking

- recipe library and recipe import flows
- recommendation and planning workflows
- cooking mode
- user recipe overlays without rewriting the base recipe dataset

### Planning and shopping

- Today and weekly planning
- ordinary meals and special-plan flows
- shopping-list workflows
- inventory-aware planning foundations

### AI-assisted workflows

- recipe and planning assistance
- receipt / media and recipe extraction paths
- provider-backed server APIs
- user review before imported or generated results become durable kitchen data

### Accounts and sync foundations

- guest-first email/password authentication
- Keychain-backed iOS sessions
- household/user scope separation
- controlled inventory bootstrap, pull, mutation, conflict, tombstone, and change-feed foundations

Production enablement is intentionally separate from implementation readiness. See [`PROJECT_STATUS.md`](PROJECT_STATUS.md) for the current operational posture and known gaps.

## Repository layout

```text
.
├── index.html / app.js / styles.css     # Web/PWA entry points
├── src/                                 # PWA domain, views, components, server modules
├── data/                                # Recipe data and source-restoration data
├── server.js                            # Express entry point
├── supabase/                            # Migrations and database validation
├── ios-native/Kitchen Manager/          # SwiftUI / SwiftData project
├── test/                                # Node built-in tests
├── scripts/                             # Validation, configuration, maintenance scripts
├── docs/                                # Architecture, contracts, runbooks, development docs
└── AGENTS.md                            # Single entry point for coding agents
```

## Quick start — Web / PWA

### Requirements

- Node.js 22 or later
- npm

```bash
npm install
npm start
```

The default local address is:

```text
http://localhost:3000
```

A static file server can be used when only the frontend is needed, but static mode does not provide Express `/api/*` routes. AI, extraction, authentication, and sync capabilities therefore degrade explicitly in that mode.

## Open the native iOS project

The Xcode project is located at:

```text
ios-native/Kitchen Manager/Kitchen Manager.xcodeproj
```

For initial development configuration:

```bash
npm install
npm run configure:ios-auth
```

Real credentials must remain in Git-ignored local configuration and must not be committed.

## Validation

Common repository-level checks include:

```bash
npm test
npm audit --omit=dev --audit-level=high
npm run validate:recipe-packs
npm run validate:recipe-pack-data
```

iOS build, XCTest / XCUITest, release checks, hosted smoke boundaries, and change-based test selection are documented in [`docs/development/TESTING.md`](docs/development/TESTING.md).

Validation is intentionally proportional: documentation-only work does not trigger unrelated full application suites, while shared models, persistence, sync, networking, release gates, and completed feature phases require broader evidence.

## Data and privacy

- PWA business data is accessed through the project's storage layer and persisted locally with `localStorage`.
- iOS business data is persisted with SwiftData; authentication sessions are stored in Keychain.
- AI output remains a draft until the relevant user-confirmation flow accepts it.
- User recipes are stored as overlays instead of silently rewriting the base recipe dataset.
- Backups must not include API keys, access tokens, or other secrets.
- Sync writes must follow the controlled server / RPC / RLS contracts.
- Development and production-like environments are treated as separate operational concerns; local validation is not presented as proof of production readiness.

## Development workflow

Before making a meaningful change, start with repository reality and read only the smallest relevant context.

Useful entry points:

- [`AGENTS.md`](AGENTS.md) — coding-agent policy, source-of-truth order, safety and validation routing
- [`docs/development/WORKFLOW.md`](docs/development/WORKFLOW.md) — incremental task workflow
- [`docs/development/TESTING.md`](docs/development/TESTING.md) — test and verification policy
- [`docs/development/CODING.md`](docs/development/CODING.md) — coding conventions
- [`docs/architecture/OVERVIEW.md`](docs/architecture/OVERVIEW.md) — stable architecture overview
- [`docs/product/PRINCIPLES.md`](docs/product/PRINCIPLES.md) — stable product principles

Keep unrelated refactors out of scope, preserve safe defaults, and add regression coverage close to the invariant being changed.

## Documentation map

The repository deliberately separates current status, stable principles, architecture, contracts, and historical evidence instead of treating every document as equally authoritative.

- [`docs/README.md`](docs/README.md) — complete documentation index and ownership rules
- [`PROJECT_STATUS.md`](PROJECT_STATUS.md) — point-in-time repository/release status snapshot
- [`CHANGELOG.md`](CHANGELOG.md) — notable changes already integrated into `main`
- [`docs/product/PRINCIPLES.md`](docs/product/PRINCIPLES.md) — stable product principles
- [`docs/architecture/OVERVIEW.md`](docs/architecture/OVERVIEW.md) — stable architecture overview
- [`docs/development/WORKFLOW.md`](docs/development/WORKFLOW.md) — development workflow
- [`AGENTS.md`](AGENTS.md) — agent instruction entry point

When documentation disagrees with current executable behavior, current code, committed configuration, migrations, and executable tests take precedence according to the source-of-truth rules in [`AGENTS.md`](AGENTS.md).

## Deployment notes

- The PWA can be served from static hosting for frontend-only use, including platforms such as GitHub Pages.
- Express hosted configuration is primarily managed outside this repository; the repository does not contain complete backend infrastructure-as-code.
- Development validation does not imply that a production deployment is enabled or complete.

## Contributing

Issues and focused contributions are welcome. Before changing the repository, read [`AGENTS.md`](AGENTS.md) and [`docs/development/WORKFLOW.md`](docs/development/WORKFLOW.md), then use [`docs/development/TESTING.md`](docs/development/TESTING.md) to select validation proportional to the change.

Please keep contributions narrow, avoid unrelated cleanup, preserve local-first and confirmation guarantees, and describe the validation actually performed rather than relying on historical test counts.

## License

Kitchen Manager is licensed under the [MIT License](LICENSE).
