# Feature Specification: Planner ordinary-meal CRUD

**Feature Branch**: `codex/planner-meal-crud`

**Created**: 2026-09-10

**Status**: In Progress — Slices 1–3 implemented and reviewed; Slice 4 (delete + undo) pending

**Input**: Owner-approved Planner ordinary-meal CRUD direction and Slice 4 behavioral contract

## Overview

Planner becomes the single canonical saved ordinary-meal planning surface in
native iOS. The feature provides durable, plan-aware CRUD for ordinary meals:
explicit dated creation, deterministic within-day ordering, edit/move,
plan-aware cooking, and delete with undo. Home IA changes wait until Planner
reaches capability parity; nothing in this feature modifies Home.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Create an explicit ordinary meal (Priority: P1)

**Status**: Implemented and reviewed (creation flow).

A household member plans a specific dish for a specific day with an explicit
servings target, from Planner itself.

**Why this priority**: Creation is the entry point of the canonical planning
surface; the rest of the feature is meaningless without it.

**Independent Test**: From Planner, create a meal for a stated day and serving
count; the meal appears on that day with that count and survives relaunch.

**Acceptance Scenarios**:

1. **Given** a week in Planner, **When** the member adds a recipe as an
   ordinary meal on a stated day, **Then** the meal appears on that day with
   the chosen servings and a stable identifier.
2. **Given** the same recipe already planned that day, **When** the member
   adds it again explicitly, **Then** a second ordinary meal is permitted
   (explicit adds do not deduplicate; the one-tap today-add still does).
3. **Given** any relaunch or persistence cycle, **When** the app restarts,
   **Then** created meals persist with identical identity, day and servings.

### User Story 2 - Edit and move an ordinary meal (Priority: P1)

**Status**: Implemented and reviewed (edit/move flow).

The member changes a meal's day or servings after creating it. Moving a meal is
an edit of its date, not a delete-and-recreate.

**Why this priority**: Without edit/move, a planning surface cannot absorb the
changes a household week actually goes through.

**Independent Test**: Open an existing meal, change its day and/or servings;
the row leaves the old day and appears on the new day with the new servings.

**Acceptance Scenarios**:

1. **Given** an ordinary meal, **When** the member edits its day, **Then** the
   meal moves to the edited day and keeps its identifier, recipe, cooked state
   and consumption linkage.
2. **Given** an ordinary meal, **When** the member edits servings, **Then**
   the stored target changes; an out-of-range value is rejected rather than
   clamped into a different number.
3. **Given** a cooked meal, **When** its current servings are passed back
   through an edit, **Then** servings stay immutable — cooking fixes the
   target.

### User Story 3 - Cook through Planner with exact plan context (Priority: P1)

**Status**: Implemented and reviewed (plan-aware cooking).

Cooking an ordinary meal from Planner carries the exact plan context,
regardless of whether the meal is on today's date.

**Why this priority**: Cooking is the payoff of planning; plan context is what
makes the Planner surface canonical rather than a mirror of Home.

**Independent Test**: Cook a meal planned on a non-today day; the exact plan is
marked cooked the same way a today-plan is.

**Acceptance Scenarios**:

1. **Given** an ordinary meal on today's date, **When** cooking starts from
   Planner, **Then** the cooking session carries that plan's context.
2. **Given** an ordinary meal on a past or future date, **When** cooking
   starts from Planner, **Then** the outcome is identical to the today case.

### User Story 4 - Delete an ordinary meal with undo (Priority: P1)

**Status**: Pending — Slice 4.

The member removes a planned meal. Removal takes effect immediately, is
announced non-blockingly, and can be undone within the session; no
confirmation alert stands between intent and deletion because deletion is
immediately undoable.

**Why this priority**: Delete completes CRUD; without it the canonical surface
cannot remove stale plans and cannot claim parity with what Home offers today.

**Independent Test**: Swipe an ordinary meal row, confirm the row disappears
and a toast with an undo action appears; tap undo and confirm the identical
meal returns to its original day and position.

**Acceptance Scenarios**:

1. **Given** an ordinary meal row, **When** the member uses the trailing
   swipe action `移出计划` (destructive), the context-menu action `移出计划`,
   or the VoiceOver custom action `移出计划`, **Then** the row is removed
   immediately.
2. **Given** a successful delete, **When** the removal is published, **Then**
   a non-blocking toast `已移出「<菜名>」` appears with a `撤销` action, and
   no confirmation alert was shown at any point.
3. **Given** the undo toast is visible, **When** the member taps `撤销`,
   **Then** the identical meal — same id, day, servings, cooked state —
   returns to its original array position, clamped only when intervening
   mutations changed the array bounds, and reappears on its original day
   through the canonical source.
4. **Given** a second delete while an undo toast is active, **When** the
   second delete succeeds, **Then** the toast and undo token are replaced and
   the first deletion becomes final from the UI perspective (exactly one
   active token, no undo stack).
5. **Given** a cooked or consumed meal, **When** it is deleted, **Then**
   deletion is allowed, consumption records are untouched, no inventory
   restoration is implied, and undoing restores the same plan id so the
   consumption linkage stays valid.
6. **Given** a delete whose persistence fails, **When** the store reports
   failure, **Then** the row remains in Planner, no success toast is shown, an
   honest error state is shown, and the member can try again.
7. **Given** an undo whose persistence fails, **When** the store reports
   failure, **Then** the row remains absent, the toast is replaced with an
   error message, and no false success state is retained.
8. **Given** a stale destination for a deleted plan id, **When** navigation
   resolves it, **Then** the existing missing-item fallback (`这一餐不存在`)
   is shown instead of crashing.
9. **Given** VoiceOver or accessibility Dynamic Type sizes, **When** the
   member deletes and undoes, **Then** the delete action is discoverable, the
   undo control is explicitly labeled, custom targets are at least 44pt, and
   the toast announcement is durable enough that Undo stays usable.

## Edge Cases

- Deleting an id that no longer exists (raced by an intervening change): the
  store reports not-found; the UI handles it safely with no crash and no false
  success toast.
- Undo after intervening mutations shifted the array: the captured index may
  no longer exist; the store clamps the insert position and the meal still
  lands on its original day.
- Undo of an id already present again (e.g. a double tap): the store treats it
  as a no-op that still reports the true persistence outcome; the UI must not
  duplicate the row.
- Delete on a different week, after a move, after cooking, or with detail
  navigation active: the Planner must not crash or keep a destination that
  assumes the plan still exists.
- A second delete replacing an active undo toast: no ambiguity about which
  deletion is still undoable.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Ordinary-meal mutations MUST go through the durable canonical
  store contracts that persist before publishing and report a
  `PlanMutationOutcome` (`saved` / `notFound` / `persistenceFailed`).
- **FR-002**: Creation MUST be explicit-dated with explicit servings and MUST
  NOT deduplicate an explicit re-add of the same recipe on the same day; the
  one-tap today-add deduplication stays as shipped.
- **FR-003**: Within-day ordering of ordinary meals MUST be deterministic.
- **FR-004**: Editing MUST change only the editable fields (date, servings)
  in one write and preserve identity, recipe, cooked state and consumption
  linkage; moving a meal is editing its date.
- **FR-005**: A cooked meal's servings MUST stay immutable when an edit passes
  the current servings back.
- **FR-006**: Ordinary meal rows MUST offer delete through a trailing swipe
  action (destructive, labeled `移出计划`), the context menu, and a VoiceOver
  accessibility custom action; there MUST NOT be a permanent visible delete
  button and there MUST NOT be a confirmation alert.
- **FR-007**: Cooking from Planner MUST carry the exact plan context of the
  selected meal, on any date.
- **FR-008**: Delete MUST use the approved canonical store API `removePlan(id:)`
  only; the UI MUST NOT mutate `kitchenStore.plans` directly and MUST handle
  all three outcome cases.
- **FR-009**: Undo MUST use only `restorePlan(item, at: originalIndex)` with
  the exact `MealPlanItem` captured by the delete outcome. Undo MUST NOT
  create a new plan, alter recipe, servings, cooked state or consumption
  records, or move the meal to a different relative array position except
  where the store clamps because intervening mutations changed the array
  bounds.
- **FR-010**: A delete whose persistence fails MUST leave the row present,
  show no success toast, show an honest error state, and stay retryable.
- **FR-011**: An undo whose persistence fails MUST leave the row absent,
  replace the success/undo toast with an error message, and retain no false UI
  state; both failure paths MUST read `PlanMutationOutcome` directly rather
  than inferring from other notices.
- **FR-012**: Deleting a cooked or consumed meal MUST be allowed without
  touching consumption records and without implying inventory was restored;
  undoing restores the same plan id so existing consumption linkage remains
  valid.
- **FR-013**: Delete/undo feedback MUST be usable with VoiceOver and
  accessibility Dynamic Type sizes: `移出计划` discoverable on the row, an
  explicitly labeled undo control, custom action targets at least 44pt, and
  toast timing that does not make Undo unusable under VoiceOver. Undo is
  session-scoped only and MUST NOT be persisted.
- **FR-014**: Navigation to a deleted plan id MUST resolve to the existing
  missing-item fallback rather than crashing or retaining a stale destination.
- **FR-015**: There MUST be exactly one active undo token. A subsequent
  successful delete replaces the active toast and token, making the earlier
  deletion final from the UI perspective. No undo history, no undo manager.

### Key Entities *(include if feature involves data)*

- **MealPlanItem**: an ordinary planned meal — stable id, recipe identity,
  normalized civil day, planned servings, cooked state. Persisted through the
  existing single SwiftData container; no schema changes in this feature.
- **PlanRemoval**: the delete outcome payload — the exact `MealPlanItem`
  plus the array index it held, so undo restores the identical value at the
  same place instead of appending a lookalike.
- **PlanMutationOutcome<Value>**: the store's honest result type for every
  mutation (`saved`, `notFound`, `persistenceFailed`; the failure case
  guarantees nothing was published).
- **Undo token (view state)**: the session-scoped holder of one active
  `PlanRemoval` for the undo toast; never persisted.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Every ordinary-meal CRUD path reports its true
  `PlanMutationOutcome`; no visible state ever describes a change the store
  did not persist.
- **SC-002**: A deleted meal is restorable by one undo action to the identical
  plan — same id, day, servings, cooked state — at its original position,
  clamped only when the store requires it.
- **SC-003**: Delete and undo failure paths show honest error states and the
  visible list matches persisted state after every attempt.
- **SC-004**: Delete and undo are operable under VoiceOver and at
  accessibility Dynamic Type sizes.
- **SC-005**: Existing create, edit/move, cooking, and Special Plan flows pass
  the focused regression suites unchanged.

## Out of Scope

- Home IA implementation — including Special Plan Home precedence, discovery
  consolidation to 更多推荐, Home global + removal, and TodayPlanDetailView
  retirement.
- AI weekly-plan materialization.
- Quantity-aware readiness.
- Sync / schema changes.
- Planner redesign — visual/IA freeze; the only allowed visible addition is
  the native delete/undo feedback this behavior requires.

## Owner Decisions (binding for this feature)

- Planner is the single canonical saved-meal planning surface. Home IA changes
  wait until Planner reaches capability parity.
- No confirmation alert for ordinary-meal deletion, because deletion is
  immediately undoable.
- Single active undo token: deleting a second meal replaces the previous
  toast/token. If the existing toast architecture could queue multiple actions
  safely without extra complexity, that alternative must be reported before
  implementation instead.
- Deleting a plan never restores consumption; consumption records are
  separate.
- AI is not a separate navigation identity; this feature adds none.

## Assumptions

- Local-first persistence (single SwiftData container) is unchanged; no
  migration is needed or performed.
- Product copy is Simplified Chinese, quoted verbatim from the approved
  direction: `移出计划`, `已移出「<菜名>」`, `撤销`, `这一餐不存在`.
- Undo history is session-scoped; nothing survives relaunch.
