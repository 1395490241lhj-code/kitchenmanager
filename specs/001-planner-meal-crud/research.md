# Research: Planner ordinary-meal CRUD (Slice 4 design decisions)

All unknowns were resolved from fresh inspection of the current tree. No
NEEDS CLARIFICATION items remain.

## D1 — Delete goes through the existing store contract

**Decision**: Use `KitchenStore.removePlan(id:)` as the only delete path.

**Rationale**: The Slice 1 contract is already tested: persists before
publishing, returns the exact item and original index, and reports
`notFound` / `persistenceFailed` honestly.

**Alternatives considered**: mutating `kitchenStore.plans` directly (rejected:
bypasses durability and the tested outcome contract); adding a new store API
(rejected: duplicates a tested contract).

## D2 — Undo goes through the existing restore contract

**Decision**: Use `KitchenStore.restorePlan(item, at:)` with the captured
`PlanRemoval`; the same UUID returns.

**Rationale**: The contract is idempotent, clamps an index that no longer
exists, preserves consumption linkage via the stable plan id, and existing
tests already cover exact-item restore, index clamping, duplicate-id no-op,
and persistence failure.

**Alternatives considered**: delete + re-add (rejected: new UUID breaks
consumption linkage); an in-memory-only restore (rejected: cannot honestly
report persistence).

## D3 — Toast action is a small extension of the shared feedback component

**Decision**: Extend `FeedbackToast` in AppFeedback.swift with an optional
trailing action (label + handler), preserving existing message/style
rendering, dark high-contrast styling and VoiceOver announcement behavior.

**Rationale**: The approved direction requires the smallest reusable optional
action capability; a new independent toast system is explicitly forbidden.

**Alternatives considered**: a separate undo toast system or undo manager
(rejected: scope creep and visual/IA freeze violation).

## D4 — Single active undo token (owner decision)

**Decision**: One session-scoped, non-persisted undo token. A successful
second delete replaces the token and toast; the earlier deletion becomes final
from the UI perspective.

**Rationale**: Matches the preferred simple contract in the approved
direction; deterministic; store-level duplicate-restore semantics already
tested.

**Alternatives considered**: queued multi-token toasts (rejected: undo-manager
scope creep).

## D5 — No confirmation alert

**Decision**: Ordinary-meal deletion never shows a confirmation alert.

**Rationale**: Owner decision; deletion is immediately undoable within the
session.

## D6 — Navigation fallback already exists

**Decision**: Verify (do not rewrite) that `plannedMealDestination` resolves a
deleted id to the existing `这一餐不存在` fallback; change nothing if safe.

**Rationale**: Fresh inspection shows the fallback is already in place for
missing plans and missing recipes.

## D7 — Cooked and consumed meals

**Decision**: Deleting a cooked/consumed meal is allowed; consumption records
are untouched; `undoConsumption` is never called; undo restores the same plan
id so existing consumption linkage stays valid.

**Rationale**: Consumption is a separate record set by design; the store test
`testCookedAndConsumedLinkageSurvivesRemoveThenRestore` already pins this.

## D8 — Toast timing under VoiceOver

**Decision**: Reuse the existing toast timing model if one exists; otherwise
choose the smallest robust extension needed for accessibility sizes and
VoiceOver. No hardcoded short timeout.

**Rationale**: Approved accessibility requirement. The exact timing decision
belongs to implementation inspection (tasks T002/T008); no persisted undo
history is created either way.

## D9 — Persistence-failure honesty

**Decision**: Failed delete keeps the row and shows an error state (retryable);
failed undo keeps the row absent and replaces the toast with an error. Both
read `PlanMutationOutcome` directly.

**Rationale**: The store's persist-before-publish guarantee already leaves
memory unchanged on failure; the UI must not fake success or infer state from
other notices.
