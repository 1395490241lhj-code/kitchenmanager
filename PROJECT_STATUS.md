# PROJECT_STATUS.md

Last updated: 2026-07-13

This file tracks the current project state for humans and AI coding agents. Update it after meaningful progress.

---

## 1. Current Stage

Kitchen Manager is no longer an empty early prototype. It is a functional local-first PWA with an existing feature set, tests, deployment workflow, and project guide documents.

Current focus:

- Make future AI-assisted development safer and more consistent.
- Preserve the working app while iterating.
- Keep project context, coding rules, testing rules, and handoff status inside the repository.
- Avoid regressions in the core cooking/inventory/shopping loop.
- Continue the native SwiftUI app under `ios-native/` without changing the PWA's stable routes or storage contracts.
- The native inventory now includes a persistent pantry-staple workflow: thresholds, restock quantities, low/out-of-stock states, suggestions, shopping-list merging, transition notifications, and backup/restore all use the existing `KitchenStore` and inventory records.
- The native core experience is aligned more closely with the PWA: actionable recipe/shopping add controls, Home quick recording, real ingredient/seasoning separation, seasoning-aware shopping generation, dual-mode staples, curated/full libraries, native recipe filters, inventory matching, and user override priority.
- Native recipe classification now treats `seasonings` as “调料与辅料”, with conservative title/context-aware handling for ambiguous ingredients. Home quick actions share one bottom-sheet presentation model, and Settings exposes only consumer-facing controls outside debug builds.
- Native inventory entry now shares one compact ingredient parser and one conservative expiry-suggestion path: compact quantity/unit input, receipt confirmation, manual batch entry, shopping stock-in, and normal inventory additions preserve explicit dates while suggesting dates only for recognized fresh foods.
- `InventoryExpirySuggestion` now covers every ordinary ingredient category (fresh produce, meat/seafood, dairy/egg/tofu, frozen, bread, deli, cured meat, opened/unopened seasonings, pantry staples) with a finite day count; only `常备` items and truly empty names still return `nil`, and unrecognized names default to 7 days. The manual-entry and receipt-confirmation "设置保质期" toggle is gone — both flows always show a plain `保质期` `DatePicker`, and a `hasUserEditedExpiry` flag (set only by real `DatePicker` interaction) protects a user's manual date choice from being overwritten by further name edits.
- The receipt confirmation list now renders each recognized item as a compact two-line row (`ReceiptIngredientCompactRow`) inside one shared `Section`, replacing the old one-`Section`-per-item layout that made each row ~200pt+ tall; rows are now ~78-96pt, fitting several more items per screen while keeping the same top-level 全选/确认入库 chrome and per-item delete.
- Native Inventory now presents fresh food as urgency-sorted adaptive lifecycle cards with dynamic light/dark status surfaces, a compact expiry progress line, accessible combined labels, and confirmed deletion. Staple rows retain their separate threshold-progress semantics.
- Native inventory detail now has one value-based single-item navigation destination and a user-controlled expiry-date editor; Home expiry and pending-shopping status sheets share the same material/grouped-list presentation container.
- Native iOS inventory persistence has completed its first SwiftData phase. `InventoryItem` remains the Codable/Hashable business and backup model, while an injected persistence layer stores every current inventory field in `InventoryRecord`. Startup migrates `native_km_inventory_v1` once, verifies UUIDs/counts before marking completion, preserves legacy JSON, and merges missing UUIDs without collapsing same-name batches. Other native data modules remain on their existing stores.
- Native iOS shopping-list persistence has completed its second SwiftData phase. `KitchenShoppingItem` remains the business and backup model, `ShoppingItemRecord` stores its current fields plus persistence-only order metadata, and startup migrates `native_km_shopping_v1` idempotently without deleting the legacy JSON. Shopping mutations, recipe/week-plan batch generation, completed-item stock-in, backup restore, and local-data clearing now use the injected shopping persistence layer; plans, weekly menus, consumption records, recipes, and settings remain on their prior stores.
- Native iOS today-plan persistence has completed its third SwiftData phase. `MealPlanItem` and the version-1 backup payload remain unchanged, while `TodayPlanRecord` mirrors its six business fields plus persistence-only order metadata. Startup migrates `native_km_plans_v1` behind `native_km_today_plan_swiftdata_migration_v1`, keeps legacy JSON, and preserves UUID-based duplicate semantics and array order. Home, recipe detail, AI cooking, week-plan batch insertion, shopping generation, consumption completion, backup restore, and local-data clearing continue through `KitchenStore`. Weekly plans, consumption records, user recipes, favorites, and settings remain on their existing stores.
- Native iOS consumption-record persistence has completed its fourth SwiftData phase. `InventoryConsumptionRecord` and its item array remain the Codable business/backup models; `ConsumptionRecordEntity` stores the record fields plus encoded `planIDs`/items and persistence-only order metadata. Startup migrates `native_km_consumption_records_v1` idempotently behind `native_km_consumption_swiftdata_migration_v1`, retaining the legacy JSON. Cooking confirmation and undo now calculate local snapshots, persist inventory then consumption records, and publish only after both succeed; a failed second write rolls inventory back best-effort. Weekly plans, user recipes, favorites, frequent recipes, and settings remain on their existing stores.
- Native iOS weekly-plan persistence now uses SwiftData. A single `WeeklyPlanRecord` stores the existing complete Codable `WeeklyMealPlan` snapshot, preserving AI-only recipes and all days, meals, shopping entries, servings, and ordering. Startup migrates `native_km_weekly_plan_v1` with `native_km_weekly_plan_swiftdata_migration_v1` while retaining legacy JSON; user recipes, favorites, frequent recipes, and settings remain on existing stores.
- The five native SwiftData modules have completed a consistency audit. All use one shared production/in-memory schema and independent MainActor contexts. Completed migration markers now self-heal from retained legacy JSON when their SwiftData table is unexpectedly empty; explicit clear-all removes both SwiftData records and legacy JSON so data cannot reappear. Five-module restart and backup restoration are covered by integration tests. Cross-context recovery remains best-effort rather than transactional.
- Native iOS recipe persistence has completed its sixth SwiftData phase. Full Codable user recipes are stored in `UserRecipeRecord`, while favorites and frequent-recipe flags share one independent `RecipePreferenceRecord` keyed by recipe ID, including remote-only IDs. `RecipeStore` keeps its public arrays/sets and all existing ID/source/content duplicate rules, but now writes the same application `ModelContainer` as the five `KitchenStore` modules. Startup migrates the three legacy keys behind `native_km_recipe_store_swiftdata_migration_v1`, retains them after successful migration, and can self-heal empty tables; explicit clear removes both tables and the legacy fallback. The version-1 kitchen backup still intentionally omits recipe-library data, favorites, and frequent flags because this phase preserves the established backup contract.
- Account login and PWA/iOS synchronization began from a completed architecture audit. The recommended future architecture remains Guest-first with Supabase Auth/Postgres, the existing Express server as an authenticated sync/API layer, per-account local stores, household-scoped kitchen data, user-scoped recipe preferences, UUID-based incremental synchronization, tombstones, optimistic concurrency, and explicit first-login merge previews. Only the server-side development authentication foundation is now verified; no client login, cloud kitchen business database, synchronization, or production authentication behavior has been enabled.
- The native-alignment Node baseline has been refreshed after the SwiftUI navigation and SwiftData transaction refactors. Settings, inventory entry/detail, Home status sheets, pantry staples, stock-in, and consumption checks now assert semantic wiring and reference the corresponding XCTest/XCUITest coverage instead of requiring obsolete constructor syntax, private method names, or UserDefaults-era mutation shapes. Production behavior was not changed.
- Account/sync implementation Phase 0 now provides Supabase local-project/migration structure, idempotent profile + personal-household initialization, constrained household membership, RLS policies, asymmetric JWKS JWT verification in Express, and an authenticated/rate-limited `GET /api/me`. Only the new probe endpoint requires authentication; PWA/iOS login, cloud kitchen tables, SwiftData changes, and synchronization remain unimplemented, and all existing Guest/public routes retain their behavior.
- Account/sync Phase 0.5 is now verified against the linked Supabase development project. Local/remote migration `20260713000100` match; a read-only remote query verifies all 3 identity tables, RLS, constraints/indexes, 3 triggers, the exact 9-policy set, and personal-household owner integrity. Two real users repeatedly pass Auth/JWKS, `/api/me`, bidirectional RLS isolation, owner/member boundary, anti-userID-forgery, and Guest-route smoke checks. Docker is unavailable, so local pgTAP was attempted but not executed; optional rate-limit saturation also remains unexecuted. This does not implement client login, cloud kitchen tables, or synchronization.

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
- Current stable routes: empty hash redirects to `#today`; `#today` is the kitchen home, `#inventory` is food inventory, `#shopping` is shopping, `#recipes` is the recipe library, and `#settings` is settings.
- Weekly menu distinguishes meal batches from dishes: `mealCount` is the number of meals, `dishesPerMeal` is the target dishes per meal, and `mealIndex` only groups transient suggestions. `plan` remains one independent recipe row per dish.

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
- Temporary `creative-*` AI recommendation ids are display-only. They must be saved as a unique overlay recipe before entering a plan or becoming editable.

### PWA cache/versioning

- Browser/Service Worker caches can keep old files alive.
- Frontend file changes may require version stamping and possibly Service Worker cache updates.

### Architecture drift

- The project is intentionally no-framework and no-build.
- Avoid gradually introducing framework-like patterns, duplicated domain logic, or Tailwind-style classes that do not work in this project.
- Keep route documentation, comments, and tests aligned with the stable five-entry navigation; do not swap the meanings of `#today`, `#inventory`, and `#shopping` without product confirmation.

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
- The native iOS home recommendation module now has ranked local search, cancellable AI supplementation/new-batch generation, native paged cards, and in-place today-plan actions. Persistence for recommendation favorites/dislikes remains future work.
- The native five-tab shell uses the system iOS 27 tab-bar scroll minimization behavior; no custom tab bar or manual scroll-direction state is present.
- The native link-import feature now forms a complete flow from Render extraction and AI parsing through editable preview to persisted user recipes. Remote recipe refreshes and local user recipes remain separate and are merged for display.
- The native “AI 做菜” task now generates a complete editable recipe from inventory and user constraints through the existing Render AI proxy, then supports saving, adding to today, or both. Regeneration preserves the input and excludes the current dish name.
- The native food-entry task now supports camera or photo-library receipt capture, local image normalization/compression, real vision recognition through the existing Render `/api/ai-chat` receipt task, editable item confirmation, and persistent batch inventory import. The simulator correctly disables camera capture while retaining photo-library and manual entry.
- The native Xiaohongshu/web recipe importer now uses the backend's complete `/api/recipe-import-from-url` pipeline, accepts full share text, persists canonical/original source metadata, blocks duplicate source imports, exposes understandable progress/errors, and keeps the existing editable-review-before-save flow.

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
# Native iOS prototype (2026-07-10)

- Added a standalone SwiftUI prototype under `ios-native/Kitchen Manager`.
- Split the native app into app shell, recipe models/store, API services, home, recipe, and add/import views.
- The Xcode `KitchenManager` scheme builds successfully with no issues in Xcode.
- Native persistence, inventory, shopping, meal planning, and full parity with the PWA remain future work.
- The native tab structure now matches the PWA: Today, Inventory, Shopping, Recipes, and Settings; recipe creation lives inside Recipes instead of occupying a tab.
- Inventory, shopping, and settings have native information-architecture shells ready for SwiftData-backed behavior.
- The native Today page now follows the PWA's current structure: greeting/status header, expiry and pending-shopping pills, Plan/Recommendations segmented panel, recipe search and cycling, weekly-menu entry, and the two quick actions.
- Added native modal flows for expiry details, pending shopping, manual/receipt inventory entry, recipe preview, all recommendations, recommendation actions, cooked-meal calibration, weekly planning, quick shopping entry, and recipe import.
- Added a shared `KitchenStore` with local persistence so inventory, today's plans, and shopping state are reflected across Today, Inventory, Shopping, and Settings.
- Re-audited the native Today page against the deployed PWA at a 390px mobile viewport and the final effective CSS rules, rather than the older home prototypes still present earlier in `styles.css`.
- Added a shared native `AppTheme` sourced from the PWA tokens (`#007AFF` primary, `#34C759` success, `#FF9500` warning, adaptive surfaces/text) and rebuilt the Today background, header, status pills, custom segmented control, search panel, white recommendation card, pagination, quick actions, and floating dock to match the deployed mobile layout.
- Kept the app on a native SwiftUI `TabView`, using page-style selection plus a stable SwiftUI floating dock so there is no WebView and no duplicate system tab bar.
- Verified the result by building and running on the iPhone 17 Pro simulator and comparing a simulator screenshot with the deployed PWA screenshot.
