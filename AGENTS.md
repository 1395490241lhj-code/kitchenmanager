# AGENTS.md

This file is the common entry point for all AI coding agents working on Kitchen Manager, including Codex, Claude Code, Cursor, Cline, Copilot, Gemini CLI, and future tools.

The goal is simple: every agent should understand the same project state, coding rules, testing rules, and safety boundaries before editing code.

---

## 0. Source of Truth Order

When files disagree, use this priority order:

1. The actual code currently in the repository.
2. `PROJECT_GUIDE.zh.md` and `PROJECT_GUIDE.md`.
3. `PROJECT_WORKFLOW.md`.
4. `PROJECT_STATUS.md`.
5. `AI_CONTEXT.md`.
6. `CODING_RULES.md`.
7. `TESTING_RULES.md`.
8. `README.md`.
9. Chat history or memory from any AI tool.

Never rely on chat history as the source of truth. The repository must explain itself.

---

## 1. Required Reading Before Code Changes

Before making any code change, read these files:

- `AGENTS.md`
- `PROJECT_GUIDE.zh.md`
- `PROJECT_WORKFLOW.md`
- `PROJECT_STATUS.md`
- `AI_CONTEXT.md`
- `CODING_RULES.md`
- `TESTING_RULES.md`
- `CHANGELOG.md`
- `README.md`
- `package.json`

For a targeted task, also read the directly related source files and tests before editing.

Examples:

- Inventory task: read `src/storage.js`, `src/inventory.js`, `src/ingredients.js`, `src/views/inventory-view.js`, related `test/*inventory*.mjs` files.
- Shopping task: read `src/shopping.js`, `src/views/shopping-view.js`, related `test/*shopping*.mjs` files.
- Recipe task: read `src/recipe-*.js`, `src/views/recipes-view.js`, `src/views/recipe-detail-view.js`, `src/views/recipe-editor-view.js`, recipe tests.
- AI import task: read `src/ai.js`, `server.js`, `src/server/**`, related AI/import/server tests.
- UI task: read the relevant view/component plus the related section of `styles.css`.

---

## 2. Project Facts Agents Must Not Forget

Kitchen Manager is a local-first kitchen management PWA.

Current stack:

- Frontend: plain HTML, CSS, and native browser JavaScript ES modules.
- No frontend framework.
- No TypeScript migration.
- No Vite/Webpack/Babel build pipeline.
- Backend: lightweight Node/Express server in `server.js`.
- Server modules: `src/server/config.js`, `src/server/services/*`, `src/server/utils/*`.
- Data persistence: browser `localStorage`, accessed through `src/storage.js` and `S.keys`.
- Tests: Node built-in test runner via `node --test` / `npm test`.
- Runtime: Node >= 18.
- Package manager: npm with `package-lock.json`.
- Deployment: GitHub Pages static deployment plus optional Node server for API features.

Main product areas:

- Kitchen home / today page.
- Inventory management.
- Expiry and out-of-stock handling.
- Recipe recommendation from available inventory.
- Today plan / meal planning.
- Cooking completion and inventory deduction through user confirmation.
- Shopping list and missing ingredient flow.
- Staples / pantry shelf.
- Recipe library, recipe editor, overlay customization.
- AI recipe draft/import.
- Receipt/image recognition.
- Local backup and restore.
- PWA/offline caching.

---

## 3. Hard Safety Boundaries

Do not change these without explicit user approval:

- Hash route meanings such as `#inventory`, `#shopping`, `#recipes`, `#settings`.
- `localStorage` key strings in `S.keys`.
- Existing user data schema or migration behavior.
- Backup/export behavior, especially API Key stripping.
- API Key handling or environment variable names.
- Authentication/security assumptions.
- GitHub Pages deployment workflow.
- Service Worker cache strategy.
- Package manager or lockfile strategy.
- Project framework or rendering architecture.
- Major folder structure.
- Large UI redesigns unrelated to the task.

Never introduce React, Vue, Svelte, Angular, Tailwind runtime, Vite, Webpack, TypeScript, or a large UI library unless the user explicitly asks for an architecture migration.

---

## 4. Working Contract for AI Agents

For each task:

1. Inspect before editing.
2. Identify the affected layer: domain logic, view, component, server, data, CSS, test, or docs.
3. Make the smallest safe change that solves the task.
4. Avoid unrelated refactors.
5. Preserve existing behavior unless the task explicitly asks to change it.
6. Add or update tests when the change affects logic.
7. Run the relevant tests described in `TESTING_RULES.md`.
8. Update `PROJECT_STATUS.md` for meaningful progress.
9. Update `CHANGELOG.md` for notable changes.
10. Report changed files, tests run, risks, and follow-up TODOs.

---

## 5. Required Final Report Format

Every coding agent must end with this structure:

```text
Summary:
- ...

Changed files:
- ...

Testing:
- Command run: ...
- Result: ...
- Manual checks: ...

Risks / assumptions:
- ...

Documentation updated:
- PROJECT_STATUS.md: yes/no
- CHANGELOG.md: yes/no
```

If tests could not be run, say exactly why and list the command that should be run next.

---

## 6. Special Project Warnings

This project has several known footguns:

- Shopping items may be rebuilt with a fixed field set. If a new shopping item field is added, update the normalization/rebuild logic so the field does not disappear after refresh.
- Inventory items preserve more unknown fields than shopping items. Do not assume all localStorage arrays behave the same way.
- User recipe edits must go through overlay behavior. Do not write user edits into base recipe data files.
- AI output is always draft data. Validate and sanitize it before saving.
- Dynamic strings inserted into `innerHTML` must be escaped.
- If frontend JS/CSS import URLs changed, run the version stamping script described in `PROJECT_GUIDE.zh.md` and `TESTING_RULES.md`.
- PWA caches can make old code appear after deployment. Consider `sw-reset.html` and cache versioning when debugging.
