# CODING_RULES.md

This file defines coding rules for Kitchen Manager. It complements `PROJECT_GUIDE.zh.md`, `PROJECT_GUIDE.md`, and `PROJECT_WORKFLOW.md`.

If this file conflicts with actual code or `PROJECT_GUIDE.zh.md`, inspect the code and follow the more project-specific source.

---

## 1. Core Principles

- Keep changes small, safe, and reversible.
- Prefer clear code over clever abstractions.
- Preserve existing behavior unless the task explicitly asks for a change.
- Do not refactor unrelated files.
- Do not introduce large dependencies for small tasks.
- Do not rewrite the app architecture.
- Always protect user data.
- Always protect the core loop: inventory -> recommendation -> plan -> shopping -> cook -> inventory update -> backup.

---

## 2. Stack Rules

This project is intentionally:

- Plain HTML.
- Plain CSS.
- Native browser JavaScript ES modules.
- No frontend framework.
- No build step.
- No TypeScript.
- No Tailwind runtime.
- No bundler.
- Node/Express only for static hosting and API/AI/proxy functions.

Do not add any of the following without explicit approval:

- React, Vue, Svelte, Angular.
- Vite, Webpack, Rollup, Parcel, Babel.
- TypeScript migration.
- Tailwind CSS runtime or CSS framework.
- State management framework.
- Database.
- Cloud sync or login system.

---

## 3. Architecture Rules

### Domain logic

Domain/business logic belongs in `src/*.js` or `src/server/**`, not directly inside DOM rendering code.

Examples:

- Storage: `src/storage.js`.
- Ingredient normalization/classification: `src/ingredients.js` and related utilities.
- Inventory behavior: `src/inventory.js`.
- Recommendation behavior: `src/recommendations.js`.
- Shopping behavior: `src/shopping.js`.
- Staples behavior: `src/staples.js`.
- AI client/frontend logic: `src/ai.js`.
- Server-side AI/page/media logic: `server.js` and `src/server/**`.

### Views

Page-level rendering belongs in `src/views/*`.

View files should:

- Render DOM.
- Bind UI events.
- Call domain/component functions.
- Save through domain/storage helpers.
- Trigger rerender through the existing routing flow.

View files should not duplicate ingredient classification, inventory deduction, recommendation scoring, or shopping merge rules.

### Components

Reusable UI flows belong in `src/components/*`.

Examples include modal shells, recipe cards, plan/missing checks, pantry shelf, cook feedback, and status/toast helpers.

### Server

Server-side behavior belongs in `server.js` and `src/server/**`.

Keep server responsibilities separated:

- Config in `src/server/config.js`.
- AI HTTP/client helpers in `src/server/services/ai-client.js`.
- Page/link extraction in `src/server/services/page-source.js`.
- Media processing in `src/server/services/media-pipeline.js`.
- Rate limits and SSRF protection in their existing service files.
- JSON/text utilities in `src/server/utils/*`.

---

## 4. Storage and Data Safety Rules

The only general localStorage entry point is `src/storage.js`.

Rules:

- Use `S.load` and `S.save`.
- Use `S.keys.*`.
- Do not write raw `localStorage.getItem('km_...')` or `localStorage.setItem('km_...')` in feature code.
- Do not rename storage keys without a migration.
- Do not clear or overwrite user data as a quick fix.
- User recipe edits should go through overlay behavior, not base recipe JSON rewrites.
- New persisted fields must be reviewed for backup/export/restore.
- Schema-breaking changes require migration logic and tests.

Special warning:

- If adding fields to shopping items, check the loader/normalizer/rebuild logic so new fields persist after refresh.

---

## 5. Recipe and Ingredient Rules

Recipes should preserve the project distinction between:

- Core ingredients that affect inventory and shopping decisions.
- Seasonings/staples that usually should not create noisy shopping requirements unless explicitly requested.

Do not duplicate seasoning detection logic in random views. Reuse existing classifier/helpers.

User recipe changes should be safe and reversible:

- Base recipe data files are source data.
- User changes belong in overlay/customization storage.
- Reset behavior should still be able to return to base + completion overlay state.

---

## 6. AI Feature Rules

AI output is always draft data.

Rules:

- Validate AI output before saving or displaying as structured data.
- Keep uncertainty/warnings visible.
- Do not invent full recipe steps from weak source evidence.
- Do not auto-change inventory from AI output.
- Receipt recognition must go through user confirmation before writing inventory.
- Recipe import must allow review/edit before save.
- Failed AI calls should show useful fallback paths.
- Static mode without `/api/*` should degrade gracefully.
- Server-side prompts, extraction, media handling, and JSON parsing should stay testable.

Secrets:

- Do not hardcode real API Keys.
- Do not commit `.env` with secrets.
- Do not log API Keys.
- Do not include API Keys in backup exports.
- Use environment variables such as `OPENAI_API_KEY`, `OPENAI_BASE_URL`, `OPENAI_MODEL`, and specialized model variables already used by the project.

---

## 7. Security Rules

- Escape dynamic content before inserting into `innerHTML`.
- Use existing escaping helpers where available.
- Attribute values need attribute-safe escaping.
- Preserve SSRF protection for URL/page/media extraction.
- Preserve rate limits for AI/import endpoints.
- Preserve CORS restrictions unless the deployment requirement is explicit and reviewed.
- Do not expose server-only secrets to frontend code.

---

## 8. UI and CSS Rules

The UI is mobile-first and should work at about 390px width.

Rules:

- Prefer existing design tokens in `:root`.
- Prefer semantic kebab-case CSS class names.
- Use `.is-*` for state classes.
- Do not paste Tailwind utility class strings into HTML.
- If a design request uses Tailwind-like wording, translate it into project CSS tokens/classes.
- New UI must be usable in light and dark themes.
- Avoid large visual redesigns for small behavior tasks.
- Inline/local edits are preferred where they reduce modal friction.
- Touch targets should be comfortable on mobile.

---

## 9. PWA and Cache Rules

When changing frontend JS/CSS imported by the browser:

- Follow the version/cache stamping rules in `PROJECT_GUIDE.zh.md`.
- Prefer the existing script `node scripts/stamp-version.js` rather than manually editing many `?v=` values.
- For deployment cache problems, consider whether `sw.v18.js` `CACHE_NAME` also needs updating.
- Do not change Service Worker strategy casually.

---

## 10. Testing Rules While Coding

- Add or update tests for changed business logic.
- Prefer targeted tests first, then full `npm test` when practical.
- For docs-only changes, tests should still pass, but no new test is usually needed.
- For UI-only changes, run relevant tests and do manual mobile checks.
- For storage changes, test refresh/persistence/backup behavior.
- For AI/server changes, test success, malformed output, upstream failure, and rate/error handling where possible.

See `TESTING_RULES.md` for command-level expectations.

---

## 11. Dependency Rules

Before adding a dependency, explain:

1. Why the dependency is necessary.
2. Why existing code cannot solve the problem.
3. Whether it affects GitHub Pages static deployment.
4. Whether it affects `npm test` or CI.
5. Whether it increases browser bundle/runtime risk.

Do not add browser dependencies casually because this project has no bundler.

---

## 12. Final Delivery Rules

Every code change must end with:

- Summary of what changed.
- Exact changed files.
- Tests run and results.
- Manual checks performed.
- Risks/TODOs.
- Whether `PROJECT_STATUS.md` and `CHANGELOG.md` were updated.
