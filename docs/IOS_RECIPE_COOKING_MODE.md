# iOS Recipe Detail and Cooking Mode

## Information architecture

`RecipeDetailView` presents the recipe summary, a session-only serving control,
checkable ingredients and seasonings, steps, tips, existing recipe actions, and
one primary **开始烹饪** action. Cooking opens a full-screen native SwiftUI mode
that highlights one step at a time, provides bounded previous/next controls and
a jump-to-step menu.

## State boundary

The recipe itself is never edited by cooking. Serving scale, ingredient checks,
completed steps, current step, and timer state are all session-only. They do not
enter SwiftData, backups, sync metadata, or cloud data.

## Serving and timer rules

The base serving count is the current Today Plan serving count when entered from
a plan; otherwise it begins at one. A conservative parser scales the first
numeric quantity (whole number, decimal, or common fraction) and leaves text
such as `适量` unchanged. Timers can use an explicit `N 分钟` step hint or a
manual common duration. They are reliable in the foreground only; no local
notification, background task, or long-running background guarantee exists.

## Today Plan and inventory

Finishing a cooking session entered from a `MealPlanItem` marks only that plan
as cooked. A regular recipe never changes a Today Plan. Cooking mode never
deducts inventory; the existing consumption-confirmation workflow remains the
only inventory-writing path.

## Screen awake and accessibility

Cooking mode temporarily preserves the display-awake state, restores it when
the view exits or backgrounds, and reactivates while the foreground cooking
view remains visible. Step progress, timer remaining time, checks, and main
actions have explicit VoiceOver labels and stable UI-test identifiers.
