# Implementation Plan: Weekly Menu → Canonical Planner Materialization

**Branch**: `codex/003-weekly-menu-materialization` | **Date**: 2026-09-10 | **Spec**: [spec.md](spec.md)

**Status**: Sealed under OD-1…OD-11 and complete. Slices A, B, C, R, D and E are all implemented,
each authorized explicitly by the owner before it started.

## Summary

Make the generator's one canonical action write `KitchenStore.plans` truthfully: resolve recipes,
allocate exact `MealPlanItem` ids, persist a pending receipt, run one atomic batch with those ids,
then finalize the receipt. Add the observable weekly-draft write the pending receipt needs, remove
the manual add-today bypasses, retire the `本周` copy in favour of the draft's real date range, and
move global restock semantics from the unmaterialized draft to canonical plans. Planner and Home
need no code to reflect a materialized menu.

## Technical Context

**Language/Version**: Swift / SwiftUI (native iOS; deployment target 26.0 — current SDK constraint)

**Primary Dependencies**: SwiftUI, SwiftData (one container, one `ModelContext` per store), XCTest + XCUITest

**Storage**: `TodayPlanRecord` unchanged; `WeeklyPlanRecord` JSON payload gains one optional field
(`materialization`); user recipes via existing `UserRecipeRecord`; no migration, no schema change

**Testing**: `KitchenManagerTests` (batch, materializer, receipt/status, restock), `KitchenManagerUITests`
with a stubbed weekly response and `PlannerRegressionFixture` states

**Target Platform**: iOS (iPhone)

**Project Type**: native mobile app

**Performance Goals**: not applicable (≤ 84 items: 7 days × 3 meals × 4 dishes)

**Constraints**: `commitPlans` stays the single private plan write path; no cross-store transaction
claimed; exact-id recovery only, never `(recipeID, date)` heuristics; no provenance on `MealPlanItem`
or `Recipe`; no `HomeView.swift` / 002 / Special Plan edit; no visual redesign

**Scale/Scope**: `KitchenStore.swift` (batch + observable draft write, remove dead
`todaysWeeklyMeals`), `Recipe.swift` (batch recipe save), `WeeklyMenuPlanner.swift` (receipt,
materializer, state machine, copy, CTA, action removal, host callback), `InventoryConsumption.swift`
+ one pure projection (restock migration), `ShoppingListGenerator.swift` (two strings in the `.weeklyPlan` branch, plus the `.plannedMeals` case and its label), tests

## Constitution Check

| Principle | Status | Notes |
|---|---|---|
| I. Evidence Before Assumption | SATISFIED | Flow, both persistence contexts, `replacePlans` rollback and unique-id attribute, `saveUserRecipe` duplicate rules, every `weeklyPlan` reader, both restock consumers, `ShoppingGenerationSource` expansion and the affected tests inspected on `1a7475b`. The stale “weekly is pushed a day at a time” header comment was verified, not trusted. |
| II. Bounded Change | SATISFIED | Home, 002, Special Plan, sync, provenance, record deletion excluded; the restock migration is in scope because OD-9 requires it and its exact cost is measured (spec §8). |
| III. Canonical Authority | SATISFIED (with gate) | D-040's single write path, `nil`-servings meaning and no-dedup-on-explicit-dates rule are reused, not overturned; `PlanMutationOutcome` is left untouched by using a separate batch outcome type; the Decision number is taken at reconciliation, never reserved (OD-10, FR-018). |
| IV. Trust Before Automation and Data Safety | SATISFIED (design) | Append-only with confirmation; atomic plan batch; honest recipe-residue disclosure; no success copy without durable exact ids; no automatic repair of a partial set; a materialized receipt never reopens after a user's own Planner deletion. |
| V. Validation Proportional to Risk | SATISFIED | Persistence-failure fixtures at each boundary, id-collision rejection, receipt state machine, relaunch, restock migration, full suite (quickstart). |
| VI. Authorization Is Never Implied | SATISFIED | Tasks are proposals; commit/push/vault remain explicit user actions. |
| VII. Convergence | SATISFIED | Slice E reconciled the artifacts against the code, re-read `Decisions.md` at reconciliation time and took D-041, and produced the final report and the vault update list. |
| Additional constraint — specs describe WHAT/WHY | ACCEPTED WITH RATIONALE | spec §4–§5, FR-001 and FR-009 carry Swift signatures because the owner brief asked for the exact receipt, batch and store contracts as owner decisions (spec Input, OD-7); they are contract facts under D-040's single write path, reviewable in one place, not implementation choices left to this plan. `data-model.md` remains the owner of signatures. Recorded here so the deviation is accepted explicitly rather than only self-certified in the requirements checklist. |

Post-design re-check: unchanged. One optional Codable field, two additive store APIs, one enum case
rename; no entity or persistence-shape change.

## Project Structure

### Documentation (this feature)

```text
specs/003-weekly-menu-materialization/
├── spec.md · plan.md · research.md · data-model.md · quickstart.md · tasks.md
└── checklists/requirements.md
```

### Source Code (repository root)

```text
ios-native/Kitchen Manager/
├── KitchenManager/
│   ├── KitchenStore.swift              # appendPlans(_:) batch + PlanBatchOutcome; commitWeeklyPlan; delete dead todaysWeeklyMeals()
│   ├── Recipe.swift                    # RecipeStore.saveUserRecipes(_:) with id reuse
│   ├── WeeklyMenuPlanner.swift         # receipt + status, WeeklyMenuMaterializer, state machine, copy, CTA, action removal, onMaterialized
│   ├── InventoryConsumption.swift      # restock derives from canonical plans; .weeklyPlan → .plannedMeals; 未来 7 天计划需要
│   ├── PlannedMealHorizon.swift        # new: pure forward-horizon slice over [MealPlanItem]
│   ├── ShoppingListGenerator.swift     # two strings in the .weeklyPlan branch (sourceLabel + empty-draft warning); + .plannedMeals case
│   └── PlannerRegressionFixture.swift  # DEBUG fixture states for stubbed result / collision / failure / pending receipt
├── KitchenManagerTests/
│   ├── PlannerMealCRUDTests.swift              # batch contracts
│   ├── WeeklyMenuMaterializationTests.swift    # new: mapping, receipt state machine, failure ordering, idempotency
│   ├── RestockSuggestionEngineTests.swift      # + canonical-plan derivation, draft yields nothing
│   └── WeeklyPlanPersistenceTests.swift        # receipt round-trip, legacy decode
└── KitchenManagerUITests/
    └── WeeklyMenuMaterializationUITests.swift  # new: materialize → Planner, double tap, collision, failure, relaunch, frozen
```

**Structure Decision**: no new modules. `WeeklyMenuMaterializer` and the receipt status function are
pure types inside `WeeklyMenuPlanner.swift` so mapping and recovery are unit-testable without UI;
`PlannedMealHorizon` is a separate small file because `InventoryConsumption.swift` and tests both use
it and it follows the existing `plans:`-parameter projection convention.

## Slices

| Slice | Content | Depends on | Testable by |
|---|---|---|---|
| **A — Store contracts** | `appendPlans(_:)` + `PlanBatchOutcome`/`PlanBatchRejection` (FR-001); `commitWeeklyPlan` (FR-009); `saveUserRecipes` (FR-003); receipt types + persistence round-trip (FR-008) | — | PlannerMealCRUDTests, WeeklyPlanPersistenceTests, recipe-store tests |
| **B — Materializer + state machine** | pure mapping (FR-005/006), OD-2 refusal (FR-004), collision detection (FR-007), ordered writes and recovery classification (FR-002/008/010/013) | A | WeeklyMenuMaterializationTests |
| **C — Result surface truth** | single CTA and its states, frozen/pending/recovery presentation, copy per §9 (FR-012), removal of both manual actions (FR-011), regenerate/duplicate confirmations (FR-013), `onMaterialized` (FR-014; a host-supplied `查看用餐计划` is deferred to 002), accessibility identifiers | B | WeeklyMenuMaterializationUITests |
| **R — Restock migration** | `PlannedMealHorizon`; restock derives from canonical plans; new `ShoppingGenerationSource.plannedMeals` so `.todayPlans` keeps meaning today; `.weeklyPlan` → `.plannedMeals`; `未来 7 天计划需要`; remove dead `todaysWeeklyMeals()` (FR-015/016) | — (parallel with A/B) | PlannedMealHorizonTests, RestockSuggestionEngineTests |
| **D — Validation** | UI suites, relaunch, full native suite (SC-005/007) | C, R | quickstart |
| **E — Reconciliation** | artifacts; next Decision number re-read (FR-018); final report; vault list | D | — |

R is independent of A–C and can land first or in parallel; D needs both branches.

## Complexity Tracking

No constitution violations. Two deliberate, disclosed simplifications: the receipt lives on the
legacy draft rather than on `MealPlanItem` (the no-provenance rule), and a partial exact-id set is
surfaced for explicit user recovery rather than auto-repaired, because a missing id is equally
consistent with a legitimate Planner deletion.
