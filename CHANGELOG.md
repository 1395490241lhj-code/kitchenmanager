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
