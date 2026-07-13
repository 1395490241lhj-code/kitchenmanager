# AI_CONTEXT.md

This file gives AI coding tools the product and architecture context for Kitchen Manager.

It should be read together with:

- `AGENTS.md`
- `PROJECT_GUIDE.zh.md`
- `PROJECT_WORKFLOW.md`
- `PROJECT_STATUS.md`
- `CODING_RULES.md`
- `TESTING_RULES.md`

---

## 1. Project Identity

Project name: Kitchen Manager / 厨房管理

Kitchen Manager is a local-first home kitchen assistant. It helps the user answer practical daily cooking questions:

- What do I have at home?
- What is about to expire?
- What can I cook today?
- What ingredients am I missing?
- What should go into the shopping list?
- After cooking, how should the inventory be updated?
- How can I import or draft recipes with AI while keeping control?

This is not an enterprise inventory ERP. It should feel like a low-friction daily kitchen companion.

---

## 2. Product Principles

### Local-first

User kitchen data should primarily stay in the browser through `localStorage`.

The app may call AI services only for user-triggered features such as recipe import, recipe drafting, receipt recognition, or recommendation assistance. The app must not silently upload broad personal kitchen data.

### Trust before automation

The app should help the user, not pretend to know things it does not know.

Important examples:

- AI-generated recipes are drafts.
- Imported recipes need review.
- Receipt recognition needs confirmation before writing inventory.
- Cooking completion should deduct inventory only after user confirmation.
- Incomplete Xiaohongshu/video extraction must be marked as uncertain instead of silently producing a fake complete recipe.

### Mobile-first

The primary usage scenario is a phone in or near the kitchen. New UI should work first at around 390px width.

### Small safe iteration

This project should evolve through small, testable, reversible changes. Avoid large rewrites.

---

## 3. Current Technical Context

Kitchen Manager currently uses:

- Plain `index.html`, `styles.css`, and native JavaScript modules.
- `app.js` as the main browser routing/rendering entry.
- `src/views/*` for page-level render functions.
- `src/components/*` for reusable UI pieces.
- `src/*.js` for domain logic such as storage, inventory, ingredients, recommendations, shopping, staples, AI, backup, migrations, theme, PWA install, and recipe packs.
- `server.js` plus `src/server/**` for Express static hosting, AI proxying, link/page extraction, SSRF protection, rate limiting, media pipeline, JSON repair/parsing, and related server-side helpers.
- `data/*` for recipe libraries and recipe completion overlays.
- `test/*` for Node built-in test runner tests.
- `scripts/*` for validation, curation, and version/cache stamping utilities.
- `supabase/*` plus `src/server/auth/*` for the Phase 0 identity foundation. A linked development project has passed migration/object checks, real two-user Auth/JWKS, `/api/me`, bidirectional RLS, and Guest-boundary smoke tests; client login and kitchen business-data sync are not implemented.

There is no frontend build pipeline. The browser runs the files directly.

---

## 4. Main User Journeys

The most important user journey is:

1. Add or import kitchen inventory.
2. See recommended recipes based on current inventory and expiry state.
3. Add a recipe to today/future plan.
4. If ingredients are missing, optionally add them to the shopping list.
5. Cook the dish.
6. Confirm actual cooking completion and inventory deductions.
7. Keep inventory, shopping list, and future recommendations accurate.
8. Export backup when real user data exists.

Any change that touches inventory, recipes, shopping, plans, recommendations, or backup must protect this loop.

---

## 5. Current Feature Map

Kitchen Manager already includes or is designed around these areas:

- Kitchen home page / today dashboard.
- Inventory management and quick entry.
- Expiry warnings and out-of-stock state handling.
- Recipe recommendation from available inventory.
- Recipe library mode: curated daily recipes and full original recipes.
- Recipe detail and recipe editor.
- User recipe overlay edits.
- Recipe completion overlay.
- Today plan and future meal planning.
- Missing ingredient detection.
- Shopping list generation and manual shopping items.
- Staples / pantry shelf state.
- Cooking feedback / completion flow.
- AI-assisted recipe drafting.
- AI-assisted recipe import from text, link, screenshot, or other source material where supported.
- Receipt/image recognition.
- BYOK advanced AI configuration.
- Default backend AI proxy mode.
- Backup and restore.
- PWA install and Service Worker caching.

---

## 6. Data Model Context

The core persistence layer is `src/storage.js`.

General rules:

- Use `S.load` and `S.save`.
- Use `S.keys.*` constants.
- Do not write raw `localStorage.getItem('km_...')` or `localStorage.setItem('km_...')` outside the storage/migration layer.
- Do not rename existing storage keys without a migration.
- Do not clear user data as a shortcut.

Important persisted concepts:

- Inventory.
- Today/future plan.
- Recipe overlay edits.
- Settings.
- Shopping items.
- Staples/pantry shelf.
- AI/local recommendation caches.
- Favorite recipes.
- Recipe usage/activity.
- Schema version.

When adding persistent fields:

1. Check how the loader normalizes/rebuilds objects.
2. Add migration logic when needed.
3. Update backup/export/restore behavior.
4. Add tests.
5. Update `PROJECT_STATUS.md` and `CHANGELOG.md`.

---

## 7. AI Feature Context

AI is a helper, not an authority.

AI features may include:

- Recipe recommendation assistance.
- Recipe method draft generation.
- Recipe import parsing.
- Receipt recognition.
- Link/page extraction support.
- Future video-to-recipe workflows.

Rules:

- Keep prompts and parsing logic separated from UI code when practical.
- Validate AI output before displaying or saving.
- Preserve warnings and uncertainty when source information is incomplete.
- Do not infer complete recipe steps from weak evidence.
- Do not let AI automatically change inventory without user review.
- Do not expose API Keys in frontend defaults, logs, backups, or committed files.

---

## 8. Future Direction

Likely future priorities:

- Make the current MVP more reliable rather than larger.
- Improve recipe import accuracy and transparency.
- Harden Xiaohongshu/video/URL import failure states.
- Keep tests aligned with real user flows.
- Improve mobile usability and iOS-like polish without changing the native stack.
- Prepare eventual app packaging while preserving local-first data ownership.

Do not assume a rewrite is required for these improvements.

---

## 9. Non-goals Unless Explicitly Requested

Do not pursue these without explicit approval:

- Full React/Vue/Svelte rewrite.
- TypeScript migration.
- Tailwind migration.
- Backend database introduction.
- Client account/login UI or expansion of the verified server-side Phase 0/0.5 authentication foundation.
- Kitchen business-data cloud sync.
- Full native iOS rewrite.
- Replacing localStorage data model.
- Changing the core navigation model.
