# Implementation Plan: Home IA Consolidation

**Branch**: `codex/002-home-ia-consolidation` | **Date**: 2026-09-10 | **Reconciled**: 2026-09-11
| **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/002-home-ia-consolidation/spec.md`, re-derived on
2026-09-11 against `main` = `a7b7d8f` (D-041 shipped). Audit evidence re-read at `eb894a8`.

**Status**: A–E implemented and committed through `e51f059`. D-042 is recorded.
Final serial tests, Release validation and reconciliation are in progress (T038–T040).

## Summary

Move the three ordinary-meal capabilities that only `TodayPlanDetailView` owns into Planner —
per-meal `做好了`, initiating `生成今日购物清单`, and hosting the AI weekly generator — remove
`全部做完` and the legacy alert-delete, reduce Home to one discovery entry and one planning
destination with no aggregator, add Special Plan today to the primary-task precedence, and then
delete `TodayPlanDetailView` and the code only it kept alive.

The retirement is inside this feature. D-041 shipped weekly materialization on `a7b7d8f`, so a
Planner-hosted generator no longer misrepresents what `加入用餐计划` does; the truthfulness gate
that previously blocked the move is satisfied by construction. Nothing in this feature is deferred
to a later one.

All work is deletion, rerouting or thin hosting over existing screens. The only new Planner
controls are a toolbar overflow menu, row-level `做好了` actions, and a generator host that passes
one callback. Generation/materialization/recovery and storage schemas remain unchanged. The separately approved
shared confirmation repair preserves exact plan IDs and idempotent consumption success.

## Technical Context

**Language/Version**: Swift / SwiftUI (native iOS; deployment target 26.0 — current SDK constraint)

**Primary Dependencies**: SwiftUI, SwiftData (existing single container), XCTest + XCUITest

**Storage**: unchanged; no schema, migration or persistence change

**Testing**: `KitchenManagerTests` (unit), `KitchenManagerUITests` (XCUITest), iPhone 17 Pro simulator

**Target Platform**: iOS (iPhone)

**Performance Goals**: not applicable — presentation, routing and hosting only

**Constraints**: visual/IA freeze except removal-caused layout; Chinese copy verbatim from the
spec; D-021 three-layer order and leaf identifiers preserved; D-040 delete contract is the only
delete; D-041 owns everything inside `WeeklyMenuPlanner.swift` and this feature does not touch it

**Scale/Scope**: six slices over `HomeView.swift`, `HomePrimaryTask.swift`,
`PlannerView.swift`, `InventoryConsumption.swift`, `RecipeCookingFlow.swift`,
and DEBUG fixtures; `HomeDashboardSummary.swift` is unchanged; two new UI-test files.
`KitchenStore.swift` is touched only by Slice E's proven-dead deletions.
`WeeklyMenuPlanner.swift` is not modified at all.

## Constitution Check

| Principle | Status | Notes |
|---|---|---|
| I. Evidence Before Assumption | SATISFIED | Re-audited at `eb894a8` on top of `main` = `a7b7d8f`: every Home control, `TodayPlanDetailView` capability with line evidence, Planner row action, store API caller, weekly-generator API surface and callback contract, and the Monday-first week anchor. The 2026-09-10 conclusions that fresher evidence contradicts are marked superseded in place rather than carried forward. |
| II. Bounded Change and Scope Discipline | SATISFIED | Scope is Home IA plus the Planner hosting needed to retire one view. Generation/materialization internals, AI provenance, recipe-residue cleanup, `planNotice` and `KitchenStore` decomposition stay out and are recorded as follow-ups. |
| III. Canonical Authority and Decision Integrity | SATISFIED | D-031 decisions 3–4 are superseded and decision 5 narrowed by recorded D-042, accepted before Slices B/D/E (FR-022). D-031 text is not rewritten. D-040 and D-041 are respected, not reinterpreted: the delete contract and the materialization contract are consumed as they shipped. Decision assignment is complete. |
| IV. Trust Before Automation and Data Safety | SATISFIED (design) | `做好了` keeps the consumption confirmation; removing `全部做完` strengthens the meal↔consumption linkage; the legacy delete that could not report a failed persist is replaced by D-040's outcome-returning delete with Undo; the generator host adds no automation and cannot write plans itself. |
| V. Validation Proportional to Risk | PLANNED | Per-slice focused suites (quickstart.md), a zero-reference proof per deleted symbol in Slice E, and the full native suite plus release check in Slice F. |
| VI. Authorization Is Never Implied | SATISFIED | Tasks describe code and tests only. Commit, push, vault write-back and the Decision record remain explicit user actions. |
| VII. Convergence Includes Reconciliation | REQUIRED | Slice F reconciles spec/plan/tasks against shipped behaviour, produces the AGENTS.md §7 final report and the vault write-back list. |

Post-design re-check: unchanged. The design adds no entities and no persistence; the one new
cross-surface contract (the generator callback) is consumed exactly as D-041 published it.

## Project Structure

### Documentation (this feature)

```text
specs/002-home-ia-consolidation/
├── spec.md              # WHAT/WHY, governing decisions, audits, state matrix, verdict B
├── plan.md              # This file
├── research.md          # Design rationale; historical unnumbered Decision draft
├── data-model.md        # Presentation-only entities; no schema change
├── quickstart.md        # Validation commands per slice
├── tasks.md             # Sliced task list
└── checklists/requirements.md
```

contracts/: skipped — no external interface. The one internal contract consumed here
(`onMaterialized` / `WeeklyMaterializationSummary`) is owned by 003 and documented in D-041.

### Source Code (repository root)

```text
ios-native/Kitchen Manager/
├── KitchenManager/
│   ├── PlannerView.swift           # A: 做好了 (swipe/context/AX); 更多 overflow; shopping + weekly routes; generator host + reveal; initial-path seed
│   ├── HomeView.swift              # C: remove +/SmartImportSheet, AI 换几道, 更多推荐. B: remove both TodayPlanDetail routes, context line. D: .specialPlanToday section. E: delete TodayPlanDetailView
│   ├── HomePrimaryTask.swift       # B: otherPlansLine model. D: .specialPlanToday + Special Plan input
│   ├── InventoryConsumption.swift  # shared exact-plan confirmation repair
│   ├── RecipeCookingFlow.swift     # preserve exact planned target identity
│   ├── ContentView.swift / PlannerRegressionFixture.swift # DEBUG fixtures
│   ├── KitchenStore.swift          # E only: delete markAllTodayCooked / removePlan(_ plan:) after proof
│   └── (WeeklyMenuPlanner.swift, ShoppingListGenerator.swift, HomeDashboardSummary.swift, PlannerProjection.swift untouched)
├── KitchenManagerTests/
│   ├── HomePrimaryTaskTests.swift          # context-line copy, Special Plan precedence, exhaustive combinations
│   ├── PlannerMealCRUDTests.swift / KitchenStoreTests.swift   # completion parity
│   └── TodayPlanPersistenceTests.swift     # E: retire the removePlan(_ plan:) caller
└── KitchenManagerUITests/
    ├── PlannerQuickCompleteUITests.swift   # new, Slice A
    ├── PlannerWeeklyHostUITests.swift      # new, Slice A
    ├── HomeDashboardUITests.swift, PlannerUITests.swift, RuntimeAccessibilityP1UITests.swift
    ├── ClipboardRecipeImportUITests.swift, ManualEntryExpiryUITests.swift, ReceiptCompactListUITests.swift
    └── ComponentMealUITests.swift, ProductionDesignLanguageUITests.swift, HomeVisualGateUITests.swift
```

**Structure Decision**: no new modules. `HomeView.swift` shrinks by `SmartImportSheet` and all of
`TodayPlanDetailView` (about 220 lines); `PlannerView.swift` gains row actions, an overflow menu
and one generator host; two new focused UI-test files.

## Slices (derived from dependencies in the current code)

| Slice | Content | Depends on | Independently testable by |
|---|---|---|---|
| **A — Planner capability parity** | `做好了` on three input paths (FR-001/002); `更多` overflow with `生成今日购物清单` (FR-003); weekly-generator host passing `onMaterialized` plus the start-date week reveal (FR-004/005) and truthful entry copy (FR-006); Planner initial-path seed for FR-013 | — | PlannerQuickCompleteUITests, PlannerWeeklyHostUITests, PlannerUITests, completion-parity unit test |
| **C — Home reduction** | remove `+` / `SmartImportSheet` (FR-007); `更多推荐` in both modes (FR-008); remove `AI 换几道` (FR-009); reroute the import-entry tests | — (parallel with A) | HomeDashboardUITests, tab reachability tests, RuntimeAccessibilityP1UITests |
| **B — Canonical routing** | Home's only planning destination is `用餐计划` (FR-010): remove `home.plan.secondaryLink` and both `home.today.plan.viewAll` branches; suppressed-plan context line (FR-011) | **A** (capabilities must already live in Planner or they become unreachable) + Decision recorded (FR-022); sequenced after C because both edit `HomeView.swift` | HomeDashboardUITests, PlannerUITests rewritten cases, HomePrimaryTaskTests |
| **D — Special Plan today** | `.specialPlanToday` with the approved precedence (FR-012); `查看聚餐` → Planner at that plan (FR-013); Special Plan context line on suppressed days | A (initial-path seed), B (context-line model), Decision recorded | HomePrimaryTaskTests (exhaustive), new HomeDashboardUITests seeds |
| **E — `TodayPlanDetailView` retirement** | delete the view, its route and identifiers (FR-016); zero-reference proof then deletion of dead store symbols (FR-017); retarget or remove obsolete tests and the fixture (FR-018); Home carries no `weeklyPlan` reference (FR-019) | A (parity) and B (no live route) are the real gates; sequenced after D because both edit `HomeView.swift` | reference gate, PlannerUITests, RuntimeAccessibilityP1UITests, HomeDashboardUITests |
| **F — Validation and reconciliation** | full suite + release check; reconcile spec/plan/tasks; final report; vault write-back list | all | — |

Execution order: **A ∥ C → B → D → E → F**.

Two ordering facts worth stating plainly, because getting them wrong breaks the product:

- **A must precede B.** B removes Home's only routes into `TodayPlanDetailView`. If the weekly
  generator, `生成今日购物清单` and `做好了` do not already live in Planner at that point, they
  become unreachable rather than re-homed.
- **E must follow A and B.** Deleting the view before parity would drop capabilities; deleting it
  while a Home route still points at it would not compile. E is not deferred anywhere: it is the
  last code slice of this feature.

## Complexity Tracking

No constitution violations requiring justification.
