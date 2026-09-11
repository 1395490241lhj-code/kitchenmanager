# Implementation Plan: Planner ordinary-meal CRUD

**Branch**: `codex/planner-meal-crud` | **Date**: 2026-09-10 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/001-planner-meal-crud/spec.md`

## Summary

Complete ordinary-meal CRUD in the native iOS Planner on the durable store
contracts Slices 1–3 delivered. Slices 1–3 (durable mutation foundation,
creation flow, edit/move + plan-aware cooking) are implemented and reviewed;
the only outstanding slice is Slice 4 — ordinary-meal delete + undo — which
wires the existing `removePlan(id:)` / `restorePlan(item,at:)` contracts into
Planner rows with a single-token undo toast, honest failure states, and
VoiceOver-safe feedback. No new store entities, no Home changes, no Planner
redesign.

## Technical Context

**Language/Version**: Swift / SwiftUI (native iOS; deployment target 26.0 — current SDK constraint, not permanent product law)

**Primary Dependencies**: SwiftUI, SwiftData (existing single container), XCTest + XCUITest

**Storage**: SwiftData via the existing single app container (business-model / Record separation unchanged); no schema changes

**Testing**: XCTest unit tests in `KitchenManagerTests`, XCUITests in `KitchenManagerUITests`

**Target Platform**: iOS (iPhone)

**Project Type**: native mobile app

**Performance Goals**: not applicable — CRUD paths are list-scale writes already covered by existing store contracts

**Constraints**: local-first persistence; visual/IA freeze (only native delete/undo feedback may appear); Chinese product copy verbatim from the spec; trust-before-automation posture preserved

**Scale/Scope**: one UI slice over two existing Planner-related files plus one shared feedback component; one new focused UI-test file

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|---|---|---|
| I. Evidence Before Assumption | SATISFIED | Store contracts, row UI, toast component, navigation fallback and existing store-level delete/undo tests inspected fresh in the current tree before planning. |
| II. Bounded Change and Scope Discipline | SATISFIED | Spec out-of-scope list is explicit; Slices 1–3 are documented as approved facts, not re-specified or redesigned. |
| III. Canonical Authority and Decision Integrity | SATISFIED | No Decision or test-enforced contract is overturned; owner decisions are recorded in the spec verbatim; Home IA untouched. |
| IV. Trust Before Automation and Data Safety | SATISFIED (design) | Destructive delete is planned with an explicit data-safety posture: immediate session undo replaces confirmation (owner decision), persistence-before-publish preserved, failure paths refuse false success (FR-010/FR-011), consumption records untouched (FR-012). |
| V. Validation Proportional to Risk | PLANNED | Focused unit suites + new delete/undo UI tests + Debug build (see quickstart.md); full-suite rerun not justified by the rebase (constitution-only upstream change). |
| VI. Authorization Is Never Implied | SATISFIED | Tasks describe code and test work only; commit and push remain explicitly user-authorized actions. |
| VII. Convergence Includes Reconciliation | REQUIRED before Slice 4 completion | Phase 4 tasks mandate the AGENTS.md final report and artifact reconciliation. |

Post-design re-check: the design adds no entities, no persistence changes and
no new automation authority; the re-check outcome is unchanged from the table
above.

Note: FR-008/FR-009 name the exact store APIs because those names are
owner-approved contract facts (the Slice 4 direction states them), not
implementation prescriptions invented by this plan.

## Project Structure

### Documentation (this feature)

```text
specs/001-planner-meal-crud/
├── spec.md              # Feature specification (WHAT/WHY)
├── plan.md              # This file
├── research.md          # Phase 0 output: design decisions
├── data-model.md        # Phase 1 output: entities (no schema changes)
├── quickstart.md        # Phase 1 output: validation guide
└── tasks.md             # /speckit-tasks output (Slice 4 only)
```

contracts/: skipped — no new external interfaces. The only contracts involved
are the in-repo Swift APIs already documented in data-model.md.

### Source Code (repository root)

```text
ios-native/Kitchen Manager/
├── KitchenManager/
│   ├── KitchenStore.swift          # existing store contracts (no changes expected)
│   ├── PlannerView.swift           # delete entry points, undo token, outcome handling
│   ├── AppFeedback.swift           # FeedbackToast optional-action extension
│   ├── PlannerRegressionFixture.swift # DEBUG-only: selects which write fails
│   └── (all other surfaces untouched)
├── KitchenManagerTests/
│   └── PlannerMealCRUDTests.swift  # existing store-level delete/undo coverage
└── KitchenManagerUITests/
    ├── PlannerMealCreateUITests.swift
    ├── PlannerMealEditUITests.swift
    ├── PlannerMealDeleteUITests.swift   # new in Slice 4
    └── PlannerUITests.swift
```

**Structure Decision**: All Slice 4 work lands in the existing Planner files
plus the shared feedback component, with one new focused UI-test file. No new
modules, no project-structure change.

## Complexity Tracking

No constitution violations; no justification entries.
