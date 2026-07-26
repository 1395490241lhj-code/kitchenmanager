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
  remains safely pinned above the bottom edge.
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
- Buttons retain system sizing and the shared 44-point minimum target where a
  compact control is presented.
- Existing VoiceOver labels and identifiers for servings, ingredients, cooking
  completion, navigation, timer, exit, and finish remain intact; the current
  step adds `recipe.cooking.currentStep` for stable UI inspection.
- Debug-only UI-test launch arguments provide long-detail, cooking, and
  no-results screenshot fixtures. They are compiled out of Release and do not
  affect user data or runtime navigation.

## Validation

Run focused Recipe support and UI suites, then the full `KitchenManagerTests`
and `KitchenManagerUITests` suites on an installed simulator. Visual review
must include the Recipe list, active search/no-results state, long detail,
Cooking Mode, dark mode, and maximum Dynamic Type.
