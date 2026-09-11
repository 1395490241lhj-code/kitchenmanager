# Implementation Plan: Home IA Consolidation

**Branch**: `codex/002-home-ia-consolidation` | **Date**: 2026-09-10 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/002-home-ia-consolidation/spec.md` (clarified 2026-09-10)

**Status**: Sealed for implementation planning. No code has been changed. Slices A and C may start
once the user authorizes implementation; Slices B/D additionally require D-041 recorded.

## Summary

Reduce native iOS Home to one discovery entry and no aggregator, add Special Plan today to the
primary-task precedence, rehome per-meal quick completion and today's shopping derivation to
Planner, remove `全部做完`, replace the eat-out / prep plan link with a factual context line, and
reduce `TodayPlanDetailView` to the capabilities it still truthfully hosts (today rows, `做好了`,
the AI weekly generator). Full retirement of that view is **blocked** by weekly materialization
(spec §2.1, §11) and is not part of this plan. All work is deletion or rerouting over existing
screens; the only new Planner controls are a one-item `更多` overflow and row-level `做好了`.

## Technical Context

**Language/Version**: Swift / SwiftUI (native iOS; deployment target 26.0 — current SDK constraint)

**Primary Dependencies**: SwiftUI, SwiftData (existing single container), XCTest + XCUITest

**Storage**: unchanged; no schema, migration or persistence change

**Testing**: `KitchenManagerTests` (unit), `KitchenManagerUITests` (XCUITest), iPhone 17 Pro simulator

**Target Platform**: iOS (iPhone)

**Project Type**: native mobile app

**Performance Goals**: not applicable — presentation and routing only

**Constraints**: visual/IA freeze except removal-caused layout; Chinese copy verbatim from spec;
D-021 three-layer order and leaf identifiers preserved; D-040 delete contract is the only delete;
no bridge for the weekly generator

**Scale/Scope**: four slices over `HomeView.swift`, `HomePrimaryTask.swift`, `PlannerView.swift`;
~10 test files; vault + D-041 at seal. `KitchenStore.swift` untouched.

## Constitution Check

| Principle | Status | Notes |
|---|---|---|
| I. Evidence Before Assumption | SATISFIED | Every Home control, `TodayPlanDetailView` capability, Planner row action, store API caller, tab entry point and the weekly generator's user-visible copy re-read on `1a7475b`. Vault anchor == HEAD, tree clean. |
| II. Bounded Change and Scope Discipline | SATISFIED | Out-of-scope is explicit; retirement and materialization deferred rather than bridged; dead-code cleanup deferred (FR-013). |
| III. Canonical Authority and Decision Integrity | SATISFIED (with gate) | D-031 decisions 3–4 superseded and 5 narrowed by **D-041**, to be recorded before Slices B/D (FR-016). D-031 text is not rewritten. |
| IV. Trust Before Automation and Data Safety | SATISFIED (design) | `做好了` keeps the consumption confirmation; `全部做完` removal strengthens meal↔consumption linkage; legacy alert-delete removed in favour of the D-040 undo contract; no new automation. |
| V. Validation Proportional to Risk | PLANNED | Per-slice focused suites (quickstart.md); full native suite at the end. |
| VI. Authorization Is Never Implied | SATISFIED | Tasks describe code/tests only; commit, push, vault write-back remain explicit user actions. |
| VII. Convergence Includes Reconciliation | REQUIRED | Slice F reconciles spec/plan/tasks, produces the AGENTS.md final report and the vault write-back list. |

Post-design re-check: unchanged; the design adds no entities and no persistence.

## Project Structure

### Documentation (this feature)

```text
specs/002-home-ia-consolidation/
├── spec.md              # WHAT/WHY, clarifications, audits, state matrices, verdict C
├── plan.md              # This file
├── research.md          # Design decisions with alternatives; D-041 draft text
├── data-model.md        # Presentation-only entities; no schema change
├── quickstart.md        # Validation commands per slice
├── tasks.md             # Sliced task list
└── checklists/requirements.md
```

contracts/: skipped — no external interface.

### Source Code (repository root)

```text
ios-native/Kitchen Manager/
├── KitchenManager/
│   ├── HomeView.swift              # remove +, SmartImportSheet, refresh, viewAll/moreLink → 更多推荐, secondaryLink → context line; Special Plan primary; reduce TodayPlanDetailView
│   ├── HomePrimaryTask.swift       # .specialPlanToday + Special Plan input; suppressed-plan line model
│   ├── PlannerView.swift           # 做好了 (leading swipe / context / AX); 更多 overflow; .shoppingToday route; initialPath
│   └── (KitchenStore.swift, WeeklyMenuPlanner.swift, ShoppingListGenerator.swift, RecipeCookingFlow.swift untouched)
├── KitchenManagerTests/
│   ├── HomePrimaryTaskTests.swift  # Special Plan precedence + context-line copy cases
│   └── KitchenStoreTests.swift / PlannerMealCRUDTests.swift  # completion parity
└── KitchenManagerUITests/
    ├── HomeDashboardUITests.swift, PlannerUITests.swift, RuntimeAccessibilityP1UITests.swift
    ├── ClipboardRecipeImportUITests.swift, ManualEntryExpiryUITests.swift, ReceiptCompactListUITests.swift
    ├── ComponentMealUITests.swift, ProductionDesignLanguageUITests.swift, Phase1DArtDirectionUITests.swift
    └── PlannerQuickCompleteUITests.swift  # new, Slice A
```

**Structure Decision**: no new modules; `HomeView.swift` shrinks by `SmartImportSheet` and part of
`TodayPlanDetailView`; one new focused UI-test file.

## Slices (derived from dependencies)

| Slice | Content | Depends on | Independently testable by |
|---|---|---|---|
| **A — Planner parity** | Planner `做好了` (FR-001/002); Planner `更多` → `生成今日购物清单` (FR-003); `PlannerRoute.shoppingToday`; `PlannerView(initialPath:)` | — | PlannerQuickCompleteUITests, PlannerUITests, completion-parity unit test |
| **C — Home reduction** | remove `+` / `SmartImportSheet` (FR-005); `更多推荐` in both modes (FR-008); remove `AI 换几道` (FR-009); reroute import tests | — (parallel with A) | HomeDashboardUITests, tab reachability tests, RuntimeAccessibilityP1UITests |
| **B — Plan-link canonicalization + TodayPlanDetail reduction** | remove `home.plan.secondaryLink`; OD-4/5 context line (FR-006/007); reduce `TodayPlanDetailView` (FR-004/012) | **D-041 recorded** (FR-016); sequenced after C (same file) | HomeDashboardUITests, PlannerUITests rewritten cases, TodayPlanDetail reduction UI test |
| **D — Special Plan today** | `.specialPlanToday` (FR-010); `查看聚餐` → Planner at plan (FR-011); Special Plan context line on suppressed days | A (initialPath), B (context-line model); **D-041 recorded** | HomePrimaryTaskTests (exhaustive), new HomeDashboardUITests seeds |
| **F — Reconciliation** | spec/plan/tasks reconcile; final report; vault write-back list (D-041, Product & IA, Current Status, Next Actions) | all | — |

Removed from this plan: former Slice E (retirement) — reclassified C, see spec §11; it becomes
the first slice of the weekly-materialization feature.

## Complexity Tracking

No constitution violations requiring justification.

