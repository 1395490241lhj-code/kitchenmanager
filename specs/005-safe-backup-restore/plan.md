# Implementation Plan: Safe backup restore

**Branch**: `codex/005-safe-backup-restore` | **Date**: 2026-09-14 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/005-safe-backup-restore/spec.md`

## Summary

Put a validation gate and an explicit member decision in front of backup restore, take a durable
pre-restore copy before the first write, and report one of five truthful outcomes instead of a
success string or a generic error. Repair the four persistences whose failed saves currently
poison the compensating write. Restore does not become atomic and the feature never says it does;
the guarantee is a successful restore or a truthful, proven recovery result.

## Technical Context

**Language/Version**: Swift 5.9+, SwiftUI / SwiftData, iOS deployment target 26.0

**Primary Dependencies**: SwiftData, `UniformTypeIdentifiers`, XCTest / XCUITest

**Storage**: SwiftData `ModelContainer` via `KitchenPersistenceBundle`; plus one app-private file
slot for the pre-restore recovery copy (`research.md` R3)

**Testing**: `KitchenManagerTests` for validation, outcome and failure-injection coverage;
`KitchenManagerUITests` for the agency, accessibility and outcome-presentation coverage

**Target Platform**: Native iOS client only. No PWA, server, Supabase or schema change.

**Project Type**: Mobile app

**Performance Goals**: None beyond keeping preview counting off the path that would block the
confirmation surface.

**Constraints**: No change to `KitchenBackupPayload`'s domains; no change to clear-local-data; no
change to sync, GuestMerge or any flag default; no Settings IA or visual redesign; restore must
not be described as atomic.

**Scale/Scope**: One store file, one Settings destination view, four persistence implementations,
plus new test files. No protocol-wide persistence redesign.

## Constitution Check

*GATE: passed before Phase 0 research; re-checked after design.*

| Principle | Status | Evidence |
|---|---|---|
| I. Evidence Before Assumption | Pass | Every governing fact was read from code at `dbb7bce` and is cited in `research.md` R1-R7, including the finding that `format`/`version` have zero readers and that four persistences lack save-failure cleanup. |
| II. Bounded Change and Scope Discipline | Pass | Scope is the restore path plus the four persistences its recovery depends on. Clear-local-data, atomicity, encryption, cloud backup and payload expansion are listed as out of scope in `spec.md` and re-checked in Phase 7. |
| III. Canonical Authority and Decision Integrity | Pass | No Decision is overturned. The Settings P1 IA and its test-locked copy stay intact; the guest footer and existing focused suites are preserved. D-028's inventory consistency window is reused, not modified. |
| IV. Trust Before Automation and Data Safety | Pass | The feature only strengthens confirmation and data safety. It adds a pre-mutation gate, an explicit confirmation and a durable recovery copy; it weakens nothing. The one new data-at-rest artefact is declared in `research.md` R3 with location, lifetime and removal. |
| V. Validation Proportional to Risk | Pass | Deterministic failure injection per domain built on the existing `Failing*Persistence` seam, plus UI coverage for agency, AXXXL and VoiceOver. Risk is data loss, so coverage targets the pre-mutation boundary and every failure branch. |
| VI. Authorization Is Never Implied | Pass | This package authorises nothing. Implementation, further commits and any push require their own explicit approval. |
| VII. Convergence Includes Reconciliation | Pass | Phase 7 carries reconciliation, the repository final report and the vault write-back decision as explicit tasks. |

No violations; **Complexity Tracking** is intentionally empty.

## Project Structure

### Documentation (this feature)

```text
specs/005-safe-backup-restore/
├── spec.md
├── plan.md              # this file
├── research.md
├── quickstart.md
├── tasks.md
└── checklists/
    └── requirements.md
```

`data-model.md` and `contracts/` are deliberately absent: no persisted domain model is added, the
backup payload is unchanged, and the three contracts this feature introduces are specified in
`spec.md` Key Entities with their storage and lifetime decided in `research.md` R3.

### Source surfaces expected to change

```text
ios-native/Kitchen Manager/KitchenManager/
├── KitchenStore.swift                      # validation gate, outcome model, recovery copy, reconcile
├── MainFeatureViews.swift                  # BackupRestoreView: preview, confirmation, outcomes
└── Persistence/
    ├── ShoppingListPersistence.swift       # save-failure cleanup
    ├── ConsumptionPersistence.swift        # save-failure cleanup
    ├── PreparedComponentPersistence.swift  # save-failure cleanup
    └── SpecialPlanPersistence.swift        # save-failure cleanup
```

The exact file placement of the validation and outcome types is an implementation choice; the
requirements are behavioural and do not mandate new type names.

## Phases

| Phase | Content | Maps to |
|---|---|---|
| 1 | Setup: branch, baseline confirmation, failure-injection seam extended from the existing `Failing*Persistence` types | FR-029 |
| 2 | Validation gate and its failure categories, with zero-mutation proof | US1, FR-001..FR-006, FR-011 |
| 3 | Persistence save-failure cleanup for the four affected domains, pinned by regression tests | FR-025 |
| 4 | Recovery copy: creation, lifetime, removal, preparation-failure path | FR-013..FR-017 |
| 5 | Outcome model and consistency behaviour after each outcome | FR-018..FR-024 |
| 6 | Preview, destructive confirmation, cancellation normalisation, outcome presentation, accessibility | US2, US3, FR-007..FR-012, FR-019, FR-028 |
| 7 | Focused validation, scope re-check against the out-of-scope list, final report, reconciliation | Constitution V, VII |

Phase 3 precedes Phase 4 deliberately: the recovery contract in Phase 4 is only meaningful for
four of the seven domains once their compensating write is reliable (`research.md` R5).

Phase 6 is last among the behavioural phases because the interface should present an outcome model
that already exists and is already proven, rather than the outcome model being shaped by the
interface.

## Risks

- **The recovery copy is a new data-at-rest artefact.** Mitigated by reusing the existing export
  bytes, a single reserved slot, defined removal on success or proven recovery, and app-private
  storage. Stated rather than hidden.
- **Recovery runs through the same pipeline it is recovering from.** A sufficiently broken
  persistence layer fails both. This is why `RESTORE_FAILED_UNSAFE` exists as a reportable state
  and why the copy is exportable.
- **Strict version acceptance refuses future backups on older builds.** Accepted deliberately in
  `research.md` R2 and reported as a version message, not as corruption.
- **Settings P1 regression.** The existing focused Settings suite must keep passing unchanged;
  this feature adds a destination behaviour, not an IA change.
