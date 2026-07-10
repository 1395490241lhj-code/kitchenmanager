# CHANGELOG.md

All notable project changes should be documented here.

Keep entries concise. Use this file for what changed, not for long design discussion. Put current project state in `PROJECT_STATUS.md`.

---

## 2026-07-08

### Added

- Added `AGENTS.md` as the common entry point for AI coding agents.
- Added `AI_CONTEXT.md` to summarize product direction, architecture context, and AI feature boundaries.
- Added `PROJECT_STATUS.md` to track current project status, risks, and next priorities.
- Added `CODING_RULES.md` to define project-specific coding and architecture rules.
- Added `TESTING_RULES.md` to define automated and manual validation expectations.
- Added optional tool adapter files `CLAUDE.md` and `.cursorrules` for Claude Code and Cursor.

### Changed

- No application runtime code changed.

### Fixed

- No bug fixes in this documentation-only update.

### Notes

- These files are designed to complement the existing `PROJECT_GUIDE.zh.md`, `PROJECT_GUIDE.md`, and `PROJECT_WORKFLOW.md` documents.
- The repository should be treated as the source of truth for project progress, coding standards, testing standards, and AI-agent handoff.

---

## 2026-07-09

### Added

- Added a lightweight "unreasonable / dislike" feedback entry for AI recommendations: a "不合理/不喜欢" action on the AI creative recommendation card (home "今日" tab's "更多操作" sheet and the desktop hero panel card) and on the AI draft recipe detail page.
- Added `src/utils/ai-disliked-recipes.js` (`getDislikedAiRecipeNames` / `markAiRecipeDisliked` / `isAiRecipeDisliked`), backed by a new `S.keys.ai_disliked_recipes` (`km_v1_ai_disliked_recipes`) localStorage key, capped at 100 entries (oldest evicted first).
- Added `test/ai-disliked-recipes.test.mjs` covering storage limits, prompt injection, `validateRecommendationResult`/`processAiData` filtering, and the UI wiring.

### Changed

- `callCloudAI()` now injects disliked dish names into the recommendation prompt, asking the AI to avoid recommending the same or highly similar dishes.
- `validateRecommendationResult()` and `processAiData()` now drop any `local`/`creative` entry whose name matches a disliked entry, in addition to the existing dark-cuisine (`isSuspiciousAiCreativeDish`) filter.

### Fixed

- No unrelated bug fixes in this change.

### Notes

- Xiaohongshu import, receipt recognition, weekly-menu planning/date scheduling, the `plan` data structure, `server.js`, and the AI draft-method save flow were not touched.

---

## 2026-07-09 (2)

### Added

- Added a friendly fallback state for the home "今日" tab's "✨ 推荐" panel: when an AI recommendation result has zero cards left after `validateRecommendationResult`/`processAiData` filtering (dark-cuisine or user-disliked), the panel now shows "暂时没有合适的 AI 推荐" with three explicit actions — "换一批" (re-run the AI fetch), "看本地推荐" (switch to inventory-based local recommendations without calling AI), and "规划本周菜单" (switch to the 计划 tab, which already hosts the weekly-menu card).
- Added `test/ai-recommendation-empty-state.test.mjs` covering the no-crash/empty-array behavior of `processAiData`/`validateRecommendationResult` and the new `home-view.js` wiring.

### Changed

- `src/views/home-view.js`: `initRecsState()` now distinguishes "never fetched AI" (falls back to local recommendations, unchanged) from "fetched AI before, but the saved result is now empty after filtering" (new `mode: 'ai-empty'`), instead of silently reusing local recommendations either way.
- Extracted the "AI 换一批" fetch logic into a shared `triggerAiRefresh()` used by both the recommendation-tab footer button and the new empty-state's "换一批" button, so a fresh fetch that also filters down to zero consistently lands back on the same friendly empty state rather than a small inline status line.

### Fixed

- No unrelated bug fixes in this change.

### Notes

- Xiaohongshu import, receipt recognition, weekly-menu planning/date scheduling, the `plan` data structure, `server.js`, and the dislike-feedback recording logic (`src/utils/ai-disliked-recipes.js`) were not touched.

---

## 2026-07-09 (3)

### Fixed

- Prevented temporary `creative-*` AI recommendation ids from entering the saved meal plan.
- Creative recommendation cards and quick detail now direct users to complete/save the draft instead of offering a direct plan action.
- Saving a `creative-ai-temp` method draft now creates a unique user recipe with its own ingredients and routes to that new recipe, avoiding reuse of the temporary id or stale overlay methods.

### Notes

- Existing plan, weekly-menu AI suggestions, Xiaohongshu import, receipt recognition, and the recipe-generation prompt were not changed.

---

## 2026-07-09 (4)

### Fixed

- `todayISO()` (`src/storage.js`) now computes "today" from local date fields (`getFullYear`/`getMonth`/`getDate`) instead of `new Date().toISOString().slice(0, 10)`, which took the UTC calendar date. In negative-offset timezones (e.g. Toronto) this could roll the app's "today" over to tomorrow in the evening, throwing off plan dates, cook-log dates, expiry countdowns, and purchase dates.
- Added `parseLocalDate(iso)` and `addDaysISO(iso, days)` to `src/storage.js` as the shared local-date parsing/arithmetic helpers (DST-safe: operates on local calendar fields via `setDate`, not millisecond addition).
- Replaced the duplicated, timezone-fragile "tomorrow / day after tomorrow" `new Date(iso)` + `toISOString().slice(0, 10)` pattern in `src/recommendations.js`, `src/components/menu-plan.js`, and `src/views/recipe-detail-view.js` with `addDaysISO(today, 1)` / `addDaysISO(today, 2)`.
- `src/views/home/weekly-menu.js` no longer defines its own local `addDaysISO`; it now imports the shared, corrected implementation from `src/storage.js`.
- Added `test/date-utils.test.mjs` covering Toronto/Shanghai/UTC "today" calculation, DST-boundary date addition, and cross-month/cross-year arithmetic.

### Notes

- `src/migrations.js`'s internal `migTodayISO()` was intentionally left untouched — migrations are frozen snapshots of past behavior by design.
- `src/utils/prep-planner.js`'s `nextDateISO()` and `src/inventory.js`'s `daysBetween()` were left untouched: both already compute correctly (pure-UTC arithmetic on date-only strings is self-consistent and DST-safe) and are not part of this bug family.
- Xiaohongshu import, receipt recognition, AI recommendation logic, weekly-menu business logic, the `plan` data structure, `server.js`, backup logic, and migrations logic were not changed.

---

## 2026-07-09 (5)

### Fixed

- The v4 `plan` migration (`src/migrations.js`) used to rebuild each plan row as `{ id, servings, date }`, silently dropping `isCooked`, `cookedAt`, ad-hoc-cook `name`, and any other field. It now spreads the original item first (`{ ...item, id, servings, date }`) and only overrides the three fields it's meant to normalize.
- Applied the same "spread, don't rebuild" fix to the v2 inventory (`migNormalizeInventoryItem`) and shopping (`migNormalizeShoppingItem`) migrations, which had the identical bug: inventory items would lose `gear`/`unitType`/`opened`/`outOfStockAt`, and shopping items would lose `completedAt`/`remark`, on any migration running from a pre-v2 schema version.
- Updated a `migrations.test.mjs` assertion that had locked in the old (buggy) field-dropping behavior for plan rows; added dedicated tests for completed-plan-row preservation, ad-hoc-cook `name` preservation, unknown-field preservation, that id/servings/date normalization still works, and equivalent coverage for the inventory/shopping v2 fixes.

### Notes

- `plan`'s data structure, today's-recommendation logic, weekly-menu business logic, Xiaohongshu import, receipt recognition, backup logic, and `server.js` were not changed — only the migration functions and their tests.

---

## 2026-07-09 (6)

### Fixed

- `validateKitchenBackup()` (`src/backup.js`) used to only check top-level key names and JSON-serializability, not each key's internal shape. A syntactically valid backup with e.g. `overlay.recipe_ingredients.r1 = {}` (an object instead of an array) could pass validation and then crash `applyOverlay()` at `list.slice()`, breaking app startup after import.
- Added per-key structural validators/normalizers for `inventory`, `plan`, `shopping_items`, `settings`, and `overlay`: container-level shape errors (not an array/object, wrong nested shapes like `overlay.recipes.<id>` not being an object or `overlay.recipe_ingredients.<id>` not being an array) now throw and reject the whole backup with zero writes; item-level issues (missing identifying field, non-scalar `qty`/`unit`/`shelf`/`kind`/`storage` pollution, missing/invalid `id`) are sanitized per-item without failing the rest of the array. Oversized arrays (>5000 items) are rejected outright.
- Applied the same normalizers to the legacy (pre-`app`-field) backup import path (`keysFromLegacyData`) so old-format backup files get the same protection.
- `importKitchenBackup()` already validated fully before writing and rolled back on partial write failure — this change makes that "validate everything, write only after full success" guarantee also cover internal key structure, not just top-level shape.
- Added 10 tests in `test/backup.test.mjs` covering the `overlay.recipe_ingredients` crash reproduction, zero-write-on-rejection, non-array `inventory`/`plan`/`shopping_items`, invalid `settings` type, non-object `overlay.recipes` entries, oversized-array rejection, a still-importable valid backup, and a post-import `applyOverlay()` smoke test.

### Notes

- Xiaohongshu import, receipt recognition, AI recommendation logic, weekly-menu logic, the `plan` data structure, `server.js`, and migration logic (`src/migrations.js`) were not changed.

---

## 2026-07-09 (7)

### Fixed

- `sw-register.v18.js` used to hard-code `caches.keys().filter(key => key !== 'km-v18').map(caches.delete)` on every page load. Since `sw.v18.js`'s `CACHE_NAME` moves forward with every release via `scripts/stamp-version.js` (currently `km-v235`), that stale `'km-v18'` string meant the register script was deleting the *current*, just-precached cache on startup, making offline precaching unreliable.
- Removed the cache-deletion logic from `sw-register.v18.js` entirely. The register script now only unregisters stale Service Worker *registrations* (script URL not matching `sw.v18.js`) and handles `register`/`updatefound`/reload-prompt duties. Cache cleanup is now solely owned by `sw.v18.js`'s `activate` handler, which already correctly deletes every cache except its own (dynamic) `CACHE_NAME`.
- Added two `test/version-consistency.test.mjs` guards: `sw-register.v18.js` must not contain a hard-coded `'km-v18'` string, and must not call `caches.keys()`/`caches.delete()` at all.

### Notes

- `sw.v18.js`'s `activate` handler was not changed — it already owned cache cleanup correctly.
- No business code, AI, Xiaohongshu import, receipt recognition, weekly-menu, or `plan` data structure logic was touched.

---

## 2026-07-09 (8)

### Fixed

- `getClientIp()` (`src/server/services/rate-limit.js`) used to trust the client-supplied `X-Forwarded-For` header first, before falling back to `req.ip`/`req.socket.remoteAddress`. Since the app has no `trust proxy` configuration, a non-browser client could send a different `X-Forwarded-For` value on every request and get a fresh rate-limit bucket every time, bypassing the AI/media/import rate limits entirely.
- `getClientIp()` now only uses `req.ip || req.socket?.remoteAddress || 'unknown'` — no header parsing. `req.ip` is Express's own resolution of the connection address (governed by `trust proxy`, currently unset, so it equals the real socket address). If the app is ever deployed behind a trusted reverse proxy, that should be enabled via an explicit `app.set('trust proxy', ...)` call, not by hand-parsing headers in the rate limiter.
- Added `test/rate-limit-client-ip.test.mjs` (6 tests): `getClientIp` ignores `X-Forwarded-For` and falls back correctly when `req.ip` is absent; two requests with the same `remoteAddress` but different `X-Forwarded-For` land in the same rate-limit bucket; different `remoteAddress` values land in different buckets.
- Updated a stale `ai-provider-mode.test.mjs` assertion that had locked in the old header-trusting behavior.

### Notes

- `server.js` was not touched (no large-scale refactor); only `src/server/services/rate-limit.js` and its tests changed. Concurrency pool / temp-directory quota work is explicitly out of scope for this change.

---

## 2026-07-09 (9)

### Added

- The full kitchen backup now covers two previously-missing pieces of user-persistent data: `ai_disliked_recipes` (the "不合理/不喜欢" AI-recommendation feedback list) and `receipt_aliases` (product-name corrections the user taught the receipt scanner). Both were real user data that used to be silently lost on backup/restore.

### Fixed

- `src/utils/receipt-aliases.js` no longer hard-codes its own `'km_v1_receipt_aliases'` string; it now reads `S.keys.receipt_aliases` (added to `src/storage.js`, same literal value, so no existing user data changes key).
- Added structural validators to `src/backup.js` for both new keys, following the same "container-shape errors reject the whole backup, item-level issues are sanitized" policy as the rest of the backup importer: `ai_disliked_recipes` must be a plain object, each entry needs a non-empty dish-name key, `reason`/`ts` are safely coerced, and the import caps at 100 entries (same as the runtime limit in `ai-disliked-recipes.js`, keeping the newest by `ts`). `receipt_aliases` must be a plain object with non-empty, trimmed string keys and values, capped at 500 entries.
- Documented the backup key list in `src/backup.js` as three categories (user-persistent data that must be backed up, rebuildable caches that don't need to be, device-local UI state that's intentionally excluded) so future additions land in the right bucket without re-deriving the reasoning.

### Notes

- Added 10 tests to `test/backup.test.mjs` covering export/import round-trips for both keys, the underlying storage key staying `km_v1_receipt_aliases`, real `isAiRecipeDisliked()`/`lookupReceiptUserAlias()` hits after restore, rejection of non-object structures, sanitization of malformed entries, oversized-map truncation, and old backups that predate these keys still importing cleanly.
- Xiaohongshu import, AI prompts, weekly-menu logic, the `plan` data structure, `server.js`, the migration schema version, and UI were not touched — this was a backup-scope-only change plus its tests.

---

## 2026-07-09 (10)

### Added

- `mustSave(key, value, message)` in `src/storage.js`: wraps `S.save()` and throws an `Error` with `.code = 'STORAGE_WRITE_FAILED'` when the write fails (quota exceeded, private-mode restrictions, etc.), instead of the silent `false` that most callers never checked. Also added the single shared user-facing message, `STORAGE_WRITE_FAILED_MESSAGE`.

### Fixed

`S.save()` returning `false` on failure was widely ignored, so a failed write still showed a success toast — the data would then disappear on refresh. Wired `mustSave` into the six key user-data paths named in this pass, without a codebase-wide mechanical replacement:

- **inventory**: `saveInventory()` now throws on failure; `inventory-view.js`'s batch "记食材" flow catches it and shows the unified failure message instead of "已加入 N 样食材".
- **plan**: `addRecipeToPlan()` now throws on failure; `addRecipeToPlanWithMissingCheck()` catches it, returns `{ added: false, ... }`, and shows the unified message instead of "已加入{计划}" (and never reaches the missing-ingredient confirm dialog on a storage failure).
- **shopping_items**: `saveShoppingItems()` now throws on failure (its one internal opportunistic self-heal call inside `loadShoppingItems()` catches and logs instead of propagating, since that's not a user-initiated save); `shopping-view.js`'s quick-add flow catches the explicit save and shows the unified message instead of "已加入买菜清单".
- **settings**: the BYOK API key/URL/model save button in `settings-view.js` now uses `mustSave` and shows the unified message instead of "已保存，刷新后生效" on failure.
- **overlay / user recipes**: `saveOverlay()` now uses `mustSave` (was already throwing, message aligned). Wired explicit handling into the three most-used save points: `recipe-editor-view.js`'s main save button, `recipe-create-modal.js`'s create-recipe modal (already had a catch block; added the specific storage-failure message), and `recipe-detail-view.js`'s "保存到菜谱" for AI-generated methods.
- **backup import**: `restoreBackupEntries()` already validated everything and rolled back the full snapshot on any mid-import failure — no behavior change needed there, only aligned its error message to reference the same unified text.

### Notes

- Added `test/storage-write-failures.test.mjs` (17 tests) using a real `localStorage.setItem` throwing `DOMException('Quota exceeded', 'QuotaExceededError')`: `S.save`/`mustSave` behavior, each of the six save paths throwing/not-silently-succeeding, source-level checks that each UI entry point's success toast sits after (and is skipped by) the failure branch, the backup-import rollback, and that normal (non-failing) writes are unaffected.
- Deliberately did not touch every scattered `S.save(S.keys.plan, ...)` / inventory / overlay call site (e.g. plan removal on "标记做完", servings edits, the other ~7 `saveOverlay` callers) — only the primary user-facing save-and-confirm flow per category, per "first phase, no codebase-wide mechanical replacement." Non-critical caches (`local_recs`, `ai_recs`, `rec_time`, etc.) were intentionally left on the old silent `S.save()` boolean.
- AI prompts, the Xiaohongshu import flow structure, weekly-menu business structure, the `plan` data structure, `server.js`, and broad UI layout were not touched.

---

## 2026-07-09 (11)

### Changed

- `.github/workflows/deploy.yml`'s `test` job now runs the full validation suite instead of just `node --test`: `npm ci` → `npm test` → `npm run validate:recipe-packs` → `npm run validate:recipe-pack-data` → `npm audit --omit=dev --audit-level=high`, on a Node `['18', '22']` matrix (`fail-fast: false` so both results are visible). Node 18 stays in the matrix because `package.json`'s `engines.node` is `>=18` and all three production dependencies (axios, express, ffmpeg-static) declare Node 18 compatibility — nothing here narrows that.
- Added a `pull_request` trigger (targeting `main`) alongside the existing `push`/`workflow_dispatch` triggers, so PRs get the same validation gate before merge.
- `build` and `deploy` now both carry `if: github.event_name != 'pull_request'`, so PR runs stop at the `test` job and never build or deploy the Pages artifact; `push`/`workflow_dispatch` keep deploying as before via the existing `needs` chain (`build` needs `test`, `deploy` needs `build`).
- Scoped the `concurrency` group to `pages-${{ github.ref }}` (was a single fixed `"pages"` group) so a PR run and an in-progress `main` deploy no longer cancel each other.
- Added `cache: 'npm'` to `actions/setup-node` for the `test` job's dependency install.

### Notes

- Added `test/workflow-config.test.mjs` (8 tests): a dependency-free block-indentation/no-tab sanity check on the workflow YAML, plus source assertions for the triggers, the Node matrix, the exact `test`-job step order, the `build`/`deploy` gating and `needs` chain, and that no `run:` command is duplicated within the `test` job (matrix-driven repetition across Node versions is expected and out of scope for that check).
- `package.json`/`package-lock.json` were not touched — all required commands were either already-existing npm scripts (`test`, `validate:recipe-packs`, `validate:recipe-pack-data`) or plain `npm` CLI invocations (`npm ci`, `npm audit`), so no new scripts were necessary.
- No business code was touched; this was a CI-configuration-only change.

---

## 2026-07-10

### Added

- `src/server/config.js`: `parseTrustProxyHops()` + `TRUST_PROXY_HOPS`/`TRUST_PROXY_HOPS_INVALID_RAW`, parsing the `TRUST_PROXY_HOPS` env var. Only positive-integer strings (`'1'`, `'2'`, ...) are accepted; unset/empty/`'0'` normalize to `0` (the local-dev default, not an error); `'true'`, negative numbers, decimals (`'2.5'`), and any other non-digit string are treated as invalid and safely fall back to `0`.
- `server.js`: right after `const app = express()`, reads those two values and calls `app.set('trust proxy', TRUST_PROXY_HOPS)` only when it's a positive integer; otherwise trust proxy stays off. Logs a one-line status (`[server] trust proxy hops: 1` or `[server] trust proxy disabled`) and, when the env var was invalid, a one-line warning naming the bad raw value — never a user IP or the `X-Forwarded-For` header contents.

### Fixed

Render Web Service's public entry point is Render's own edge proxy — the Node process's `req.socket.remoteAddress` is always that proxy, never the end user. Without `trust proxy` configured, `getClientIp()` (`req.ip || req.socket.remoteAddress`) resolved to the same proxy address for every visitor in production, so the AI/import rate limiters were bucketing effectively all users together instead of per-visitor. `TRUST_PROXY_HOPS=1` on Render now makes Express resolve `req.ip` to the real client address forwarded by that one trusted hop, while still ignoring any additional `X-Forwarded-For` entries a client prepends on their own.

`src/server/services/rate-limit.js`'s `getClientIp()` was intentionally left unchanged (`req.ip || req.socket?.remoteAddress || 'unknown'`) — it already delegates entirely to Express's own trust-proxy-aware IP resolution and never reads `X-Forwarded-For` by hand.

### Notes

- Added `test/trust-proxy.test.mjs` (17 tests), including real integration tests that start an actual `express()` app on an ephemeral port and hit it with Node's built-in `http` client: `TRUST_PROXY_HOPS` string-parsing edge cases (`'true'`/`'2.5'`/`'-1'`/`'1'`/whitespace); `req.ip` resolution under `trust proxy = 1` with no `X-Forwarded-For`, a single forwarded IP, and a client-forged prefix (`"1.2.3.4, 203.0.113.10"` must resolve to `203.0.113.10`, never `1.2.3.4`); `req.ip` staying pinned to the socket address when trust proxy is `0`; real rate-limit bucket assignment showing the same trusted client landing in one bucket regardless of forged prefixes, and different clients landing in different buckets; and source guards against `app.set('trust proxy', true)`, hand-rolled `X-Forwarded-For` reads, and env-var parsing scattered outside `config.js`.
- Documented `TRUST_PROXY_HOPS=1` in `PROJECT_WORKFLOW.md` (new §12.9), including the explicit warning not to guess `2` if a CDN is ever added in front of Render without first verifying the real hop count, and that `true` must never be used.
- Rate-limit thresholds, media pipeline, AI prompts, the Xiaohongshu import flow, the frontend, and the `plan` data structure were not touched — this was a trust-proxy-configuration-only change plus its tests and docs.

---

## 2026-07-10 (2)

### Changed

- Aligned the Chinese and English project guides, route comments, status document, and manual test checklist with the current navigation contract: empty hash redirects to `#today`; `#today` is the kitchen home; `#inventory` is food inventory; and `#shopping` is the shopping list.
- Replaced outdated four-tab and "shopping contains full inventory" descriptions with the current five-entry dock: 今日 / 食材 / 买菜 / 菜谱 / 我的.

### Added

- Added a route-behavior test that executes the current `app.js` `onRoute()` body in a controlled harness and verifies empty-hash redirect, view selection, and dock active-state semantics.

### Notes

- No route branch, navigation link, page layout, AI/import flow, receipt recognition, `plan` data structure, or `server.js` behavior changed.
- The app still does not add a redirect for former `#inventory` home bookmarks; this pass records the current product behavior and does not create compatibility behavior.

---

## 2026-07-10 (3)

### Changed

- Weekly menu planning now distinguishes meal batches from dishes per meal. The modal defaults to two dishes per meal, and both AI and local fallback plans target `mealCount × dishesPerMeal` dishes, capped at 12.
- AI results carry a transient `mealIndex` / `mealLabel`, are rendered in meal groups, and synchronize the planned date within a group. Joining the plan still writes one independent recipe row per dish; the `plan` schema was not changed.
- Updated the weekly-menu prompt to request balanced home-style pairings, discourage duplicate heavy/protein dishes in one meal, and prefer reheatable dishes with appropriate servings for lunchbox plans.

### Added

- Added behavior tests for the 3 meals × 2 dishes path, grouped dates, synchronized date changes, per-dish plan mappings, local fallback, invalid `mealIndex` recovery, the 12-dish cap, and lunchbox prompt rules.

### Notes

- Xiaohongshu import, receipt recognition, today recommendations, AI draft details, shopping data, and the server structure were not changed.
