# Data Model: Planner ordinary-meal CRUD

No schema changes. Every persisted entity already exists in the tree; the only
new state for Slice 4 is view-scoped and session-limited.

## Existing entities (unchanged by this feature)

### MealPlanItem

- Fields: `id` (UUID, stable), `recipeID`, `recipeName`, `date` (normalized
  civil day), `plannedServings` (validated; immutable once cooked), `isCooked`.
- Persistence: existing single SwiftData container via the business-model /
  Record separation. No migration in this feature.
- Validation: the initializer validates `plannedServings`; store-level edit
  paths restate that validation, so out-of-range values surface as outcomes,
  never as clamped numbers.

### PlanRemoval

- Fields: `item` (the exact `MealPlanItem`), `index` (original array position).
- Purpose: the delete outcome payload that makes undo restore the identical
  value at the same place instead of appending a lookalike.

### PlanMutationOutcome<Value>

- Cases: `saved(Value)`, `notFound`, `persistenceFailed`.
- Contract: `persistenceFailed` guarantees nothing was published — visible
  state can never describe a change the store did not persist.

## New view state (Slice 4)

### Undo token

- Shape: the one active `PlanRemoval` plus the undo toast's presentation
  state.
- Scope: session-scoped, in-memory, never persisted; exactly one active token;
  a later successful delete replaces it.
- Not an entity: no SwiftData model, no schema, no migration, no undo history.
