# PROJECT_STATUS.md

Last updated: 2026-07-09

This file tracks the current project state for humans and AI coding agents. Update it after meaningful progress.

---

## 1. Current Stage

Kitchen Manager is no longer an empty early prototype. It is a functional local-first PWA with an existing feature set, tests, deployment workflow, and project guide documents.

Current focus:

- Make future AI-assisted development safer and more consistent.
- Preserve the working app while iterating.
- Keep project context, coding rules, testing rules, and handoff status inside the repository.
- Avoid regressions in the core cooking/inventory/shopping loop.

---

## 2. Verified Current Project Shape

Current observed structure:

- Root frontend files: `index.html`, `app.js`, `styles.css`.
- PWA files: `manifest.webmanifest`, `sw.v18.js`, `sw-register.v18.js`, `sw-reset.html`.
- Backend entry: `server.js`.
- Frontend/domain modules: `src/*.js`.
- Page views: `src/views/*`.
- UI components: `src/components/*`.
- Server modules: `src/server/*`, `src/server/services/*`, `src/server/utils/*`.
- Data files: `data/*`.
- Scripts: `scripts/*`.
- Tests: `test/*`.
- Docs already present: `README.md`, `PROJECT_GUIDE.md`, `PROJECT_GUIDE.zh.md`, `PROJECT_WORKFLOW.md`, `docs/*`.
- CI/deployment: `.github/workflows/deploy.yml`.

Current package facts:

- Package name: `kitchenmanager`.
- Runtime: Node >= 18.
- Main local command: `npm start` -> `node server.js`.
- Main test command: `npm test` -> `node --test`.
- Validation commands:
  - `npm run validate:recipe-packs`
  - `npm run validate:recipe-pack-data`
- Current dependencies include Express, Axios, and ffmpeg-static.

---

## 3. Existing Strengths

- The app already has a clear product direction: local-first kitchen inventory, recipes, shopping list, planning, AI assistance, and backup.
- The project already has detailed architecture guidance in `PROJECT_GUIDE.zh.md` and `PROJECT_WORKFLOW.md`.
- The repository contains a broad Node test suite under `test/*`.
- GitHub Pages deployment has a test gate.
- The README already documents local run modes, AI settings, localStorage keys, PWA/cache behavior, and deployment options.
- The codebase has a modular structure with domain modules, views, components, server services, and tests.

---

## 4. Current Risk Areas

These areas need extra caution:

### Data safety

- `localStorage` keys are user-data contracts.
- Any schema change needs migration and backup/restore review.
- Never clear user data to fix a bug.
- API Key must not be written to backup, logs, or committed defaults.

### Shopping item shape

- Shopping item normalization/rebuild behavior can silently drop new fields if the fixed field set is not updated.
- Any shopping item field change needs refresh/persistence testing.

### AI import and media pipeline

- Link/video extraction may be incomplete or unreliable.
- AI-generated recipe data must remain reviewable draft data.
- Media and URL handling must preserve SSRF/rate-limit/error handling safeguards.

### PWA cache/versioning

- Browser/Service Worker caches can keep old files alive.
- Frontend file changes may require version stamping and possibly Service Worker cache updates.

### Architecture drift

- The project is intentionally no-framework and no-build.
- Avoid gradually introducing framework-like patterns, duplicated domain logic, or Tailwind-style classes that do not work in this project.

---

## 5. In Progress

- Adding unified AI-agent handoff documentation:
  - `AGENTS.md`
  - `AI_CONTEXT.md`
  - `PROJECT_STATUS.md`
  - `CODING_RULES.md`
  - `TESTING_RULES.md`
  - `CHANGELOG.md`
  - optional tool adapters such as `CLAUDE.md` and `.cursorrules`

---

## 6. Recommended Next Priorities

1. Add the shared AI-agent documentation files to the repository root.
2. Run `npm test` after adding the documentation, even though docs should not affect runtime behavior.
3. Open the app locally with `npm start` and confirm the main page loads.
4. Keep `PROJECT_GUIDE.zh.md`, `PROJECT_WORKFLOW.md`, and the new agent docs aligned when major rules change.
5. For future coding tasks, require the AI tool to read `AGENTS.md` first.
6. When changing frontend JS/CSS, remember cache/version stamping rules.
7. When changing data structures, add tests and update backup/migration behavior.

---

## 7. Do Not Change Without Explicit Approval

- `S.keys` storage key strings.
- Hash routes and bottom navigation semantics.
- User backup/export format.
- API Key storage/export behavior.
- GitHub Pages deployment workflow.
- Package manager / lockfile strategy.
- Framework architecture.
- PWA Service Worker strategy.
- Recipe source data files as a substitute for user overlay edits.

---

## 8. How to Update This File

After each meaningful change, update:

- `Last updated` date.
- `Current Stage` if the project phase changed.
- `In Progress` if active work changed.
- `Recommended Next Priorities` if priorities changed.
- `Current Risk Areas` if a new risk is discovered.

Do not turn this file into a long changelog. Put detailed change history in `CHANGELOG.md`.
