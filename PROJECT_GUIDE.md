# Kitchen Manager Project Guide

This guide is the operating contract for future AI-assisted development on Kitchen Manager. It is intentionally specific to this repository. Read it before changing code.

## 1. Project Positioning

Kitchen Manager is a local-first household kitchen management PWA. It helps one person or a small household move through this loop:

1. Record what is in the kitchen.
2. See what should be used soon.
3. Decide what to cook today.
4. Add missing ingredients to a shopping list.
5. Confirm purchased items into inventory.
6. Mark recipes as cooked and update usage history.
7. Back up or restore the whole kitchen.

The current implementation is plain HTML/CSS/JavaScript with browser-native ES modules, plus a small Express server. There is no frontend framework, no bundler, and no build step.

Primary product principles:

- Local-first: core user data lives in `localStorage`.
- Low-friction daily use: the app should answer "what should I do next in my kitchen?"
- AI is a helper, not an authority: AI output must be treated as a draft and validated before entering user data.
- Mobile-first: the app must remain comfortable at 390px iPhone width.
- Incremental evolution: do not rewrite the project or change many surfaces in one task.

## 2. Core User Paths

Keep these paths working after every change:

1. New user path:
   - Open app.
   - See onboarding or empty state.
   - Add food manually, via receipt recognition, or by importing a backup.

2. Daily kitchen path:
   - Open "厨房" home dashboard.
   - See today plan, urgent expiring items, ready recipes, almost-ready recipes.
   - Add a recipe to today's plan.
   - Add missing ingredients to the shopping list.

3. Inventory path:
   - Go to "库存管理".
   - Add a raw item or dry good.
   - Edit quantity, unit, purchase date, shelf life, frozen state, and stock state.
   - Delete or mark item empty without breaking recommendations.

4. Pantry path:
   - Go to "库存管理 -> 常备货架".
   - Toggle staple availability.
   - Manage custom shelf items.
   - Missing staples should join the shopping list.

5. Shopping path:
   - Add manual shopping items.
   - See grouped shopping items by source.
   - Mark bought.
   - Confirm bought items into inventory before writing inventory records.
   - Copy a readable list for WeChat/Notes.

6. Recipe path:
   - Search recipes by name, tag, or ingredient.
   - Open recipe detail.
   - Add to today's plan.
   - Add missing ingredients to shopping list.
   - Mark cooked without aggressively deleting inventory unless a confirmation/calibration flow is used.
   - Edit system recipes via overlay, not by mutating base data.

7. Backup path:
   - Export full kitchen backup.
   - Import full kitchen backup.
   - Import old inventory-only backup.
   - Bad JSON must show a clear error and must not clear data.

## 3. Current Page Structure

Routes are hash-based and handled in `app.js`.

Current route map:

- `#inventory`: visible page "厨房"; this is the home dashboard. Keep this old hash for compatibility.
- `#shopping`: visible page "库存管理"; contains three segmented panels:
  - shopping items
  - staples/pantry shelf
  - full inventory
- `#recipes`: visible page "菜谱"; search, filters, AI import, manual recipe creation.
- `#settings`: visible page "设置"; theme, recipe library mode, AI settings, backups, cache clearing.
- `#recipe:id`: recipe detail page.
- `#recipe-edit:id`: recipe editor page.

Important current files:

- `app.js`: initialization, migrations, recipe-pack loading, route composition, global error display.
- `src/views/home-view.js`: kitchen dashboard, quick actions, today's plan integration, AI inspiration, receipt entry.
- `src/views/shopping-view.js`: shopping list, segmented inventory management page, pantry management modals.
- `src/views/inventory-view.js`: full inventory add/edit grid and receipt scanning entry.
- `src/views/recipes-view.js`: recipe list/search and AI recipe import flow.
- `src/views/recipe-detail-view.js`: recipe detail actions, cooking completion, inventory deduction confirmation.
- `src/views/recipe-editor-view.js`: recipe editing, AI draft conversion, overlay save.
- `src/views/settings-view.js`: settings, backup/restore, theme.

Current component/service split:

- `src/components/modal.js`: reusable modals for inventory edit, receipt confirmation, cook calibration, clean-fridge modal.
- `src/components/menu-plan.js`: today's plan UI and shortage modal.
- `src/components/recipe-card.js`: recipe cards and search result cards.
- `src/components/pantry-shelf.js`: egg/milk/dry-good pantry shelf tiles.
- `src/components/status.js`: escaping, inline status, small UI helpers.
- `src/storage.js`: localStorage keys and safe load/save.
- `src/migrations.js`: schema version and migration helpers.
- `src/ingredients.js`: ingredient aliases, units, dry-good definitions, canonical names.
- `src/inventory.js`: inventory matching, stock state, shelf life, merging, deductions.
- `src/shopping.js`: shopping item normalization, grouping, merging, copy text, conversion to inventory.
- `src/recommendations.js`: local recommendation scoring, shortages, plan/cooked records.
- `src/staples.js`: pantry/staple state and custom shelf config.
- `src/ai.js`: AI calls, JSON parsing, validation, receipt/recipe import helpers.
- `src/backup.js`: overlay and kitchen backup import/export.
- `server.js`: Express static server plus AI/link proxy endpoints.

## 4. Recommended Future Page Structure

Do not implement this all at once. Use it as direction for small changes.

Recommended navigation:

- `#inventory` / "厨房": dashboard only.
  - Today plan
  - urgent/expiring items
  - can-cook-now
  - almost-can-cook
  - quick add / receipt / backup entry

- `#shopping` / "采购":
  - active shopping list
  - grouped by source
  - bought items
  - stock-in confirmation
  - copy/share

- `#stock` or existing `#shopping` segmented panel / "库存":
  - full inventory
  - add/edit inventory
  - receipt recognition
  - low/out-of-stock maintenance

- `#pantry` or existing segmented panel / "常备":
  - pantry shelf
  - custom pantry management
  - staple status
  - dry goods, egg/milk, seasonings

- `#recipes` / "菜谱":
  - search and filter
  - recipe cards
  - import AI draft
  - manual recipe creation

- `#settings` / "设置":
  - theme
  - recipe library mode
  - AI config
  - backup/restore
  - cache reset

Migration rule: if routes are renamed later, keep old hashes as aliases for at least one release cycle. Never break `#inventory`, `#shopping`, `#recipes`, `#settings`, `#recipe:id`, or `#recipe-edit:id` links.

## 5. Current Data Structures And localStorage Keys

All keys are centralized in `src/storage.js`. Use `S.keys.<name>`, not string literals.

Current keys:

- `km_schema_version`: data schema version.
- `km_v19_inventory`: inventory array.
- `km_v19_plan`: today's/future plan array.
- `km_v19_overlay`: user recipe overlay.
- `km_v23_settings`: settings, including AI endpoint/model/key and theme preferences.
- `km_v48_ai_recs`: AI recommendation cache.
- `km_v97_local_recs`: local recommendation cache.
- `km_v97_rec_time`: recommendation timestamp cache.
- `km_v97_rec_signature`: recommendation cache signature.
- `km_v80_favorite_recipes`: favorite/common recipe ids.
- `km_v95_recipe_usage`: legacy/usage recipe records.
- `km_v2_recipe_activity`: planned/cooked activity records.
- `km_v87_shopping_items`: shopping list rows.
- `km_v1_staples`: staple availability state.
- `km_v1_pantry_config`: custom pantry shelf config.

Important structures:

- Inventory item:
  - `id`, `name`, `qty`, `unit`, `buyDate`, `kind`, `shelf`, `stockStatus`, `isFrozen`
  - dry goods may include `dryPrep`
  - gear-based items may include `gear`, `unitType`
  - out-of-stock cleanup may use `outOfStockAt`

- Shopping item:
  - `id`, `name`, `qty`, `unit`, `source`, `done`, `stockedIn`, `stockedInAt`, `remark`

- Plan item:
  - `id`, `servings`, `date`

- Recipe overlay:
  - `{ version, recipes, recipe_ingredients, deletes }`
  - user edits must go here, not into `data/*.json`.

- Pantry config:
  - `hidden`: hidden default pantry entries
  - `overrides`: renamed/regrouped default entries
  - `custom`: user-created pantry entries

Data rules:

- Any new persistent field must be documented here and wired through backup/restore.
- Any new localStorage key must be added to `S.keys`.
- Any breaking structure change must increase `DATA_SCHEMA_VERSION` and add a migration in `src/migrations.js`.
- Migrations must never clear data on failure.
- Import/restore must be all-or-nothing where possible. If partial restore is unavoidable, show a clear warning.

Known watch point:

- When touching backup/restore, make sure custom pantry config (`km_v1_pantry_config`) is included alongside `km_v1_staples`.

## 6. Frontend Module Rules

Keep the current native ES module architecture.

Allowed:

- Plain JavaScript modules.
- DOM APIs.
- Existing helper modules.
- Small focused modules in `src/`.
- Small focused components in `src/components/`.
- Small focused views in `src/views/`.

Not allowed without explicit approval:

- React, Vue, Svelte, Solid, Angular, or any frontend framework.
- Bundlers/build tools such as Vite/Webpack/Rollup.
- TypeScript migration.
- CSS frameworks or external UI libraries.
- Large dependency additions.

Layering rules:

- `app.js` should only initialize, load packs, run migrations, handle routes, and compose views.
- `src/views/*` may assemble DOM and bind page-level events.
- `src/components/*` should render reusable UI blocks and accept callbacks.
- `src/inventory.js`, `src/shopping.js`, `src/recommendations.js`, `src/staples.js`, `src/ingredients.js`, `src/backup.js`, and `src/ai.js` should contain business logic or service logic.
- Pure scoring, matching, parsing, normalization, and conversion logic should not live inside DOM event handlers.
- If a view grows further, extract pure helpers first, then reusable components. Do not split a file and redesign UI in the same change unless explicitly requested.

Import/version rules:

- The project uses `?v=<number>` cache busting on modules and static assets.
- After changing JS/CSS that is imported by the browser, run `node scripts/stamp-version.js` or update relevant versions consistently.
- Do not hand-edit many version query params unless the task is tiny and the scope is obvious.

## 7. UI Design Rules

Design goal:

- Calm, Apple-inspired, high-readability, mobile-first, local utility app.
- It should feel like a daily kitchen dashboard, not a marketing landing page.

General UI:

- Primary action: use `.btn.ok`.
- Normal action: use `.btn`.
- Dangerous/delete action: use `.btn.bad`.
- AI action: use `.btn.ai` or an existing AI-specific class.
- Avoid adding new button styles when existing hierarchy fits.
- Use page-level cards and full-width sections sparingly. Do not create nested cards.
- Preserve the floating liquid-glass dock navigation.
- Preserve dark mode.

Mobile rules:

- Always inspect 390px width mentally and, when possible, in browser.
- Text in buttons/cards must not overflow. Use `truncate`, `min-width: 0`, wrapping, or shorter labels.
- Do not rely on hover-only interactions.
- Tap targets should usually be at least 36px high; dense micro chips are allowed only for pantry-style matrix controls.
- Bottom content needs enough padding so the floating nav does not cover it.

Home page rules:

- Home must answer "what should I do now?"
- Keep the priority order:
  - today's plan / suggestion
  - urgent expiring items
  - can cook now
  - almost can cook
  - secondary utilities
- Do not push full inventory tables into the first viewport.

Inventory rules:

- Full inventory can be dense, but must remain readable on mobile.
- Editing should be explicit via edit/manage mode.
- Destructive actions need confirmation or clearly reversible behavior.

Shopping rules:

- Group by source.
- Merge same-name same-unit active items visually.
- "Stock in" must ask for confirmation/editable fields before writing inventory.

Recipe rules:

- Recipe cards should show action hierarchy without squeezing title text.
- Recipe details should have clear next actions.
- AI drafts must show draft status until saved by the user.

## 8. CSS Naming And Design Token Rules

Use existing `styles.css` tokens first.

Core tokens:

- Colors: `--primary`, `--accent`, `--warning`, `--danger`
- Text: `--text-main`, `--text-secondary`
- Surfaces: `--bg-card`, `--bg-input`, `--separator`
- Glass: `--glass-fill`, `--glass-fill-strong`, `--glass-stroke`, `--glass-edge`
- Surface cells: `--surface-cell`, `--surface-cell-border`
- Status: `--status-ok-*`, `--status-warn-*`, `--status-bad-*`, `--status-info-*`, `--status-draft-*`
- Shadows: `--shadow-sm`, `--shadow-card`, `--shadow-float`, `--shadow-hero`, `--shadow-nav`
- Radius: `--radius-s`, `--radius-m`, `--radius-l`, `--radius-nav`

Naming rules:

- Prefer feature-scoped prefixes:
  - `home-*`
  - `shopping-*`
  - `inventory-*` or `inv-*`
  - `recipe-*`
  - `settings-*`
  - `km-modal-*`
  - `staple-*`
  - `menu-*`
- Do not introduce generic class names such as `.panel2`, `.new-card`, `.blue-button`.
- If adding a reusable component, use a `km-*` prefix.
- For state, use `is-*` classes, for example `is-active`, `is-hidden`, `is-managing`, `is-collapsed`.
- Prefer CSS variables over hard-coded colors.
- If a new hard-coded color is unavoidable, check light and dark mode contrast.

Modal rules:

- Prefer `.km-modal-overlay` and `.km-modal-content` for new liquid-glass modals.
- Avoid creating another modal shell unless the old `.modal-overlay` component is being intentionally migrated.
- Closing animations must only transition `transform` and `opacity`; do not use `transition: all`.

Responsive rules:

- Use existing media-query style in `styles.css`.
- Avoid viewport-width font scaling.
- Use stable dimensions for grids, chips, toolbars, and controls.

## 9. Data Safety And Privacy Principles

User kitchen data is personal. Treat it like private data.

Rules:

- Do not delete or rename existing localStorage keys unless there is an explicit migration and user-safe fallback.
- Do not write directly into base recipe data files for user edits.
- Do not store API keys in exported backups.
- Do not log API keys or image base64 to console.
- Do not send inventory, recipes, receipt images, or personal notes to external services except when the user explicitly invokes an AI/import feature.
- AI feature failures must not block local workflows.
- Backup import errors must show user-visible errors and must not silently fail.
- Any new data key must be included in:
  - `src/storage.js`
  - `src/migrations.js` if structure needs migration
  - `src/backup.js` export/restore
  - this guide

## 10. AI Feature Boundaries

AI can:

- Recognize receipt images into draft inventory items.
- Parse recipe links/text/screenshots into editable recipe drafts.
- Generate method drafts for recipes.
- Suggest recipe ideas based on inventory.
- Help clean fridge by proposing recipes from expiring items.

AI must not:

- Directly overwrite inventory without user confirmation.
- Directly overwrite existing recipes without showing/editing draft state.
- Delete user data.
- Be the only path to complete a core task.
- Break local fallback behavior.

Validation requirements:

- Use `safeParseJson` for AI JSON.
- Validate recipes with `validateRecipeResult` or import-specific validation.
- Validate recommendations with `validateRecommendationResult`.
- Validate receipts with `validateReceiptItems`.
- Normalize ingredients with `normalizeAiIngredients`.
- If AI returns invalid JSON, show inline status and keep manual paths usable.

Server-side AI:

- `server.js` provides:
  - `GET /api/xhs-extract`
  - `POST /api/ai-parse`
- Server env vars:
  - `PORT`
  - `OPENAI_API_KEY`
  - `OPENAI_BASE_URL`
  - `OPENAI_MODEL`
- Do not expose server API keys to the frontend.

## 11. Forbidden Actions

Do not:

- Rewrite the project from scratch.
- Replace native JS with a frontend framework.
- Change many pages in one task unless the user explicitly asks.
- Remove existing functionality without a migration plan.
- Modify `data/sichuan-recipes*.json` for user-level edits.
- Break old hash routes.
- Add new localStorage keys outside `S.keys`.
- Store API keys in exported backups.
- Use `alert()` for new flows unless the change is deliberately tiny and no inline status/modal exists.
- Add UI that only works on desktop.
- Add unvalidated AI output into business data.
- Make destructive git operations such as reset/checkout unless explicitly requested.
- Manually clear user localStorage in app code.
- Use broad CSS overrides that affect unrelated pages.
- Hide errors silently.

## 12. Development Checklists

Before coding:

- Confirm the exact user request and scope.
- Run `git status --short`.
- Read the directly related files and their call chain.
- Identify whether the change touches:
  - localStorage data
  - backup/restore
  - migrations
  - AI validation
  - route/hash behavior
  - mobile layout
  - PWA cache/versioning
- If there is data-loss risk, explain the risk before editing.
- Choose the smallest safe change.

During coding:

- Keep edits scoped to the requested theme.
- Prefer existing helpers and CSS tokens.
- Keep business logic in service modules when possible.
- Escape user-visible dynamic HTML with `escapeHtml` / `escapeOptionAttr`.
- Use callbacks instead of importing route functions into low-level modules.
- Preserve old data structures unless a migration is part of the task.
- Avoid nested cards and duplicate modal shells.

After coding:

- Run syntax checks for touched JS files, for example:
  - `node --check app.js`
  - `node --check src/views/<changed-view>.js`
  - `node --check src/<changed-service>.js`
- Run `git diff --check`.
- If JS/CSS was changed, ensure cache-busting versions are updated consistently, preferably with `node scripts/stamp-version.js`.
- If data structures changed, test old data loading and backup import/export paths.
- If UI changed, manually test 390px mobile layout when possible.
- If AI changed, test missing API key and invalid JSON paths.
- If shopping/inventory changed, test:
  - add item
  - edit quantity/status
  - delete/empty item
  - add to shopping list
  - mark bought
  - confirm stock-in
- If recipe changed, test:
  - search
  - detail
  - add to plan
  - edit/save overlay
  - AI draft save if relevant

Final response to user:

- Say what changed.
- List files changed.
- Explain why the change was made.
- Mention risks or limitations.
- Provide browser verification steps.
- If tests could not be run, say why.

