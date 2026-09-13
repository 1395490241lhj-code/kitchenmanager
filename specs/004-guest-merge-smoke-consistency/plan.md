# Implementation Plan: GuestMergeSmoke direct-call consistency window

**Branch**: `codex/004-guest-merge-smoke-consistency` | **Date**: 2026-09-12 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/004-guest-merge-smoke-consistency/spec.md`

## Summary

Wrap every direct persistence-affecting call in the DEBUG-only `GuestMergeSmokeRunner` in the
existing D-028 inventory consistency window, using four minimum-scope windows rather than one
runner-wide lock, so the harness inherits the same guarantee production already has. Repair the
baseline seeding that currently prevents three runners from reaching any checkpoint, prove the
result with deterministic local tests, and pin the call-site rule with the existing repository
guard.

## Technical Context

**Language/Version**: Swift 5.9+, SwiftUI / SwiftData, iOS deployment target 26.0

**Primary Dependencies**: SwiftData, `supabase-swift` (indirect, via the existing transport), XCTest

**Storage**: SwiftData `ModelContainer`; the smoke uses in-memory containers exclusively

**Testing**: XCTest (`KitchenManagerTests`) for deterministic coverage; `HostedGuestMergeSmokeTests`
for hosted development acceptance; Node `npm test` for the static call-site guard

**Target Platform**: Native iOS client only

**Project Type**: Mobile app, DEBUG-only test harness within it

**Performance Goals**: None. Correctness-only change.

**Constraints**: No change to D-028 or D-029 semantics; no flag default changes; no server, schema
or PWA change; the harness's scenario-construction local edits must keep working, so a
runner-wide lock is not acceptable.

**Scale/Scope**: One production-adjacent DEBUG file, one new test file, one existing Node guard.

## Constitution Check

*GATE: passed before Phase 0 research; re-checked after design.*

| Principle | Status | Evidence |
|---|---|---|
| I. Evidence Before Assumption | Pass | The call graph, the boundary primitive, the fingerprint gate and the test feasibility were each read from current code at `2f43689`; see `research.md`. |
| II. Bounded Change and Scope Discipline | Pass | Scope is `GuestMergeSmoke.swift`, one new test file, one existing guard. The out-of-scope list is explicit in `spec.md`. FR-011 is a prerequisite of this feature's own acceptance, recorded with rationale rather than absorbed silently. |
| III. Canonical Authority and Decision Integrity | Pass | D-028 and D-029 are reused unchanged; the plan states explicitly that neither may be modified. |
| IV. Trust Before Automation and Data Safety | Pass | No flag is enabled, no production infrastructure is touched, no confirmation step is weakened, and the destructive delete helper stays confined to smoke files under the existing guard. |
| V. Validation Proportional to Risk | Pass | Deterministic tests for each protected block plus failure injection; hosted acceptance as an additional layer, never a substitute. |
| VI. Authorization Is Never Implied | Pass | Planning only; no commit, push, flag change or hosted run is authorized by this document. |
| VII. Convergence Includes Reconciliation | Pass | Phase 6 carries the final report and vault reconciliation as explicit tasks. |

No violations; **Complexity Tracking** is intentionally empty.

## Project Structure

### Documentation (this feature)

```text
specs/004-guest-merge-smoke-consistency/
├── spec.md
├── plan.md              # this file
├── research.md
├── quickstart.md
├── tasks.md
└── checklists/
    └── requirements.md
```

`data-model.md` and `contracts/` are deliberately absent: the feature introduces no new domain
data and no new external interface.

### Source Code (repository root)

```text
ios-native/Kitchen Manager/
├── KitchenManager/
│   ├── KitchenStore.swift                         # window primitive — read, not modified
│   └── Synchronization/
│       ├── GuestMergeSmoke.swift                  # the only production-adjacent file changed
│       ├── GuestMergeController.swift             # reference only
│       ├── InventorySyncAdapter.swift             # reference only
│       └── SyncSmoke.swift                        # precedent for the begin/defer-end shape
└── KitchenManagerTests/
    ├── GuestMergeSmokeConsistencyTests.swift      # new
    ├── GuestMergeTests.swift                      # reuse of the signed-in AuthStore pattern
    ├── SyncSmokeTests.swift                       # precedent
    └── HostedGuestMergeSmokeTests.swift           # hosted acceptance, unchanged

test/ios-native-guest-merge-phase2b1.test.mjs      # existing guard, extended
```

**Structure Decision**: the change stays inside the existing native iOS layout. No new module,
target or directory is introduced.

## Design

### The four windows

Each window opens before the first persistence-affecting call of its operation and closes after
the last one, on every exit path.

| Window | Span | Opens before | Closes after |
|---|---|---|---|
| W1 duplicate retry | `runRemainingPhases`, the whole duplicate-retry block | `stageUpsert` (B1) | the marker-cleanup `runOnce` (B6) |
| W2 final pull | `runRemainingPhases`, the final pull | `finalCoordinator.runOnce` (B7) | the same call |
| W3 second device | `runProductionRemotePreviewMinimalSmoke` | `stageUpsert` (B8) | `updateCoordinator.runOnce` (B9) |
| W4 cleanup | `bestEffortCleanup` | the first staged soft delete (B10) | the coordinator run |

W1 spans the marker cleanup on purpose: it is the same logical operation as the retry it cleans
up after, and one window means one reconciliation instead of two. No scenario-construction edit
occurs anywhere inside W1–W4, which is what makes these spans legal.

### The helper

A single throwing helper inside `GuestMergeSmoke.swift`:

- opens the window;
- runs the block;
- on success, closes the window and converts a failed reconciliation into
  `GuestMergeSmokeError.validationFailed`;
- on error, still closes the window, then rethrows the original error.

`bestEffortCleanup` stays non-throwing and uses the primitive directly, returning whether
reconciliation succeeded so the success-path caller can refuse to report a clean run.

### Supporting change

`kitchenStore` is hoisted above the `do` block in the four runners that declare it inside, so the
`catch` path can pass it to cleanup. This mirrors the existing hoist of `persistence` in
`runIdentityForkMinimalSmoke`.

### Implementation sequence (frozen at spec review)

`Slice 0a` → `Slice 0b` → `Slice A` → `Slice B` → `Slice C` → `Slice D`. Slices 0a and 0b are
prerequisite harness-integrity repairs and MUST each stay independently reviewable as their own
code commit; neither MUST be collapsed into the W1–W4 wiring of Slice B. Slice 0b was discovered
while implementing Slice 0a and MUST execute after it and before Slice A.

| Slice | Content | Phase in [tasks.md](./tasks.md) |
|---|---|---|
| 0a | baseline fingerprint repair at three call sites, proven by a deterministic test, no window wiring | Phase 2 |
| 0b | seeding-baseline session lifecycle repair: zero rollback window on the three seeding-only controllers, so the next preview is a fresh scenario preview | Phase 2b |
| A | boundary plumbing: runner helper, cleanup signature and result, `kitchenStore` hoist, call sites | Phase 3 |
| B | W1–W4 wiring, scenario-construction edits kept outside | Phase 4 |
| C | deterministic failure, overlap, echo and scenario-preservation evidence | Phase 5 |
| D | hosted development acceptance and final seal | Phase 6 |

### Explicitly unchanged

`KitchenStore`, `GuestMergeController`, `InventorySyncAdapter`, `SyncCoordinator`,
`InventorySyncEligibility`, every `.xcconfig`, `project.pbxproj`, the server, Supabase and the
PWA. D-028 and D-029 semantics, and all flag defaults.

## Risks

- **Reconciliation republishes durable inventory mid-run.** Mitigated by keeping every scenario
  assertion after the close, so a damaged scenario fails loudly (`research.md` D1).
- **A window placed around a scenario-construction edit would silently stop constructing the
  scenario**, because the edit gate refuses it without throwing. Mitigated by the Category C
  table, by the guard, and by the deterministic tests asserting the scenario conditions.
- **The baseline repair changes what the baseline preview does** (it now performs a real remote
  read). This matches what every other preview in the file already does; hosted acceptance is the
  check.

