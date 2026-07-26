# iOS Recipe Experience — Phase 2

## Scope

Phase 2 is a presentation-only refinement of the native Recipe experience:
Recipe list, Recipe detail, and Cooking Mode. It uses SwiftUI system
typography, semantic colors, native grouped surfaces, Dynamic Type fallbacks,
and the existing `AppTheme` tokens.

The scope excludes Recipe models, persistence, storage, API/import behavior,
navigation architecture, auth, sync, and every non-Recipe tab.

## Information hierarchy

- **Recipe list:** recipe title is the first and strongest row element.
  Summary, availability, and tags are secondary metadata. Search uses the
  existing searchable control and gives a specific, quiet no-results state.
- **Recipe detail:** title and session metadata establish context, then
  servings, ingredients, seasonings, steps, and tips are grouped into readable
  native sections. The existing `开始烹饪` action is the sole prominent action and
  is the final in-flow action after the preparation content, so it never
  overlays reading content or the tab bar.
- **Cooking Mode:** the current step and its completion action are the visual
  focus. Progress remains visible, while step navigation, ingredients, timer,
  and finish controls remain reachable but use a quieter secondary treatment.

## Preserved contracts

- Existing Recipe list search, filters, refresh, add/import routes, detail
  menu actions, favorite/frequent state, shopping generation, edit/delete, and
  stable accessibility identifiers are preserved.
- Serving scale, ingredient checks, completed steps, current step, and timer
  state remain session-only through the existing `RecipeCookingSession` and
  `CookingTimerController`.
- Cooking still never writes inventory, syncs progress, or changes a recipe.
  Completing a Today Plan still uses the existing callback only when entered
  from a plan.
- No animation was added. Reduce Motion therefore retains the existing static
  transitions. Semantic system/AppTheme colors support light and dark mode.

## Accessibility and visual evidence

- Metadata uses `ViewThatFits` to remain horizontal where possible and fall
  back to a readable vertical stack at larger Dynamic Type sizes.
- The detail hero uses `.headline` at accessibility Dynamic Type sizes while
  retaining the native large-title hierarchy at standard sizes. This avoids an
  oversized title or metadata block without limiting body text or clipping
  reading content.
- Buttons retain system sizing and the shared 44-point minimum target where a
  compact control is presented.
- Existing VoiceOver labels and identifiers for servings, ingredients, cooking
  completion, navigation, timer, exit, and finish remain intact. Detail step
  rows additionally have stable identifiers for long-content reachability
  checks.
- Debug-only UI-test launch arguments provide long-detail, cooking, and
  no-results screenshot fixtures. They are compiled out of Release and do not
  affect user data or runtime navigation.

## Screenshot-review follow-up

- The long-recipe fixture now has a long title, ten ingredients, and ten
  long-form steps. Its seed clears only DEBUG UI-test recipe data before
  inserting, preventing a persisted old fixture from masking the current
  evidence.
- The one `开始烹饪` button uses `AppTheme.brand`, is placed after the final
  reading section, and remains fully reachable above the main tab bar. It
  retains its existing identifier and Cooking Mode presentation behavior.
- Cooking Mode keeps the current step and `下一步` as the clear focused path;
  `上一步` is disabled at the first step, ingredients remains secondary, and
  finish is a quieter contextual action. The state machine and timer are
  unchanged.
- Recipe content actions use the existing brand token. Existing Filter and Add
  toolbar controls intentionally retain the system tab/navigation tint: they
  are standard toolbar affordances rather than the Recipe screen’s primary
  cooking action.
- Final visual evidence is exported outside the repository to
  `/Users/lianghongjing/Desktop/KitchenManager-Recipe-UI2-Review/final-fix/`.
  The branch requires an update after PR #6 merges because PR #6 is still open
  and has not entered `main`.

## Validation

Run focused Recipe support and UI suites, then the full `KitchenManagerTests`
and `KitchenManagerUITests` suites on an installed simulator. Visual review
must include the Recipe list, active search/no-results state, long detail top
and bottom, Cooking Mode first/middle/timer states, dark mode, and maximum
Dynamic Type.

### Final review evidence — 2026-07-25

- Recipe support/store focused unit tests: **24 passed, 0 failed, 0 skipped**.
- Recipe UI focused suite: **7 passed, 0 failed, 0 skipped**.
- Full `KitchenManagerTests`: **774 passed, 0 failed, 5 skipped**; the skipped
  unit tests predate this UI follow-up.
- Full `KitchenManagerUITests`: **33 passed, 0 failed, 1 skipped**. The one
  existing skip is `HostedSyncSmokeUITests/testExplicitDevelopmentInventorySmoke`,
  because hosted sync-smoke credentials were intentionally not supplied.
- Full Node suite: **1049 passed, 0 failed, 0 skipped**. Debug and Release
  simulator builds and `git diff --check` passed.
- Fresh simulator captures are outside Git at
  `/Users/lianghongjing/Desktop/KitchenManager-Recipe-UI2-Review/final-fix/`.
