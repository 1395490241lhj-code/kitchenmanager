# Feature Specification: GuestMergeSmoke direct-call consistency window

**Feature Branch**: `codex/004-guest-merge-smoke-consistency`

**Feature ID**: 004

**Created**: 2026-09-12

**Status**: Draft

**Input**: Make `GuestMergeSmoke`'s direct staging / sync / cleanup paths inherit the relevant
D-028 inventory consistency guarantees so the harness can be trusted as a pre-dogfood acceptance
gate.

## Problem

`GuestMergeController`'s three production entry points — `confirmMerge`, `rollback` and
`syncNow` — each run inside a whole-operation inventory consistency window (D-028). The
DEBUG-only `GuestMergeSmokeRunner` calls those same entry points, but it also drives persistence
directly: `InventorySyncAdapter.stageUpsert`, `stageDeleteRemovingLocalRecord`,
`SwiftDataSyncPersistence.savePending` and `SyncCoordinator.runOnce`.

During those direct calls no edit gate is held and no reconciliation runs at exit, so persistent
`InventoryRecord` state can change while `KitchenStore.inventory` stays stale. That is the R1
class of defect the harness exists to detect, which makes the harness itself capable of
exhibiting it. Until that is closed, a green smoke run is not trustworthy evidence for a
pre-dogfood acceptance gate.

Planning also found a second, independent defect that blocks the same goal: baseline seeding in
three runners can no longer complete, so those runners abort before reaching any checkpoint. It is
frozen as a **prerequisite harness-integrity repair** — required to reach the consistency-window
checkpoints at all, and deliberately not part of the window mechanism. See FR-011 and
`research.md` §3.

Implementing that repair uncovered a second prerequisite of the same kind. Once a baseline
confirms, its completed session keeps the default 24-hour rollback window, and
`activeGuestMergeSession` deliberately keeps returning a session inside that window, so the next
`preparePreview` in the same runner resumes the finished baseline session instead of building the
fresh scenario preview the smoke needs. That is tracked as FR-014 and `research.md` §6, and it is
also prerequisite harness integrity rather than consistency-window behavior.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - The harness protects its own direct persistence writes (Priority: P1)

A developer runs a Guest merge smoke against development infrastructure. Every block of the run
that can change durable inventory truth holds the same consistency guarantee the production
merge path holds: local edits are refused while the block is in flight, and in-memory inventory
is reconciled from persistence when the block ends, including when it ends by throwing.

**Why this priority**: This is the feature. Without it the harness can produce exactly the
inconsistency it is meant to detect, and no downstream evidence from it is trustworthy.

**Independent Test**: Drive `GuestMergeSmokeRunner` with an in-memory container and a fake
transport; assert that during each protected block `KitchenStore` refuses a conflicting local
edit, and that after the block the in-memory array equals durable storage.

**Acceptance Scenarios**:

1. **Given** a smoke run reaches the duplicate-retry block, **When** the first `stageUpsert`
   executes, **Then** the inventory consistency window is already open.
2. **Given** a protected block is in flight, **When** the harness or any other code attempts an
   ordinary local inventory edit, **Then** the edit is refused and leaves no durable row change
   and no staged outbound mutation.
3. **Given** a protected block completes normally, **When** the window closes, **Then**
   `KitchenStore.inventory` equals the durable inventory and no outbound mutation was staged by
   the reconciliation itself.
4. **Given** a protected block throws partway through, **When** the error propagates, **Then**
   the window still closes and reconciliation is still attempted.
5. **Given** reconciliation fails, **When** the window closes, **Then** the inventory stays
   locked and the run reports the failure instead of reporting success.

---

### User Story 2 - Deterministic regression coverage proves the protection holds (Priority: P2)

The guarantees above are proven by local, deterministic tests rather than by a hosted run that
needs credentials, network and a human.

**Why this priority**: Hosted smokes cannot be run on every change and legitimately skip when
credentials are absent. Merge-gate correctness needs coverage that always runs.

**Independent Test**: Run the iOS unit test target with no network; the new tests pass or fail on
their own.

**Acceptance Scenarios**:

1. **Given** a staging failure injected into the fake transport or persistence, **When** the
   protected block unwinds, **Then** reconciliation still runs and the test observes consistent
   state.
2. **Given** two protected operations overlap, **When** the inner one closes, **Then** the window
   remains held until the outer one closes.
3. **Given** a reconciliation that fails, **When** the block ends, **Then** the store reports
   locked rather than current.

---

### User Story 3 - Hosted acceptance and drift protection (Priority: P3)

After local correctness is green, the existing hosted development smokes still pass, and a
repository guard prevents a future edit from reintroducing an unprotected direct call.

**Why this priority**: It converts a one-time fix into a durable property, and confirms the
change against real infrastructure without changing what that infrastructure is.

**Independent Test**: Run the hosted smoke tests with development credentials present; run
`npm test` and observe the guard fail when an unprotected call is reintroduced.

**Acceptance Scenarios**:

1. **Given** development credentials and gates, **When** each hosted runner executes, **Then** it
   reaches its existing final checkpoint and reports zero marker residue or names the exact
   residual ids.
2. **Given** a new unprotected direct persistence call added to the smoke file, **When**
   `npm test` runs, **Then** the guard fails and names the call.

### Edge Cases

- A protected block ends by `throw` from deep inside an `await`: the window must still close.
- Reconciliation fails on the failure path as well: the run is already throwing, so the original
  error must survive and the store must stay locked.
- Cleanup runs twice (success path and again from an outer `catch`): the depth counter must not
  underflow and the window must not unlock early.
- The scenario-construction assignments to `KitchenStore.inventory` are ordinary local edits; if
  one of them were placed inside a window the edit gate would refuse it and the scenario would
  silently stop being constructed.
- Reconciliation republishes durable truth into the in-memory array mid-run; a scenario that
  depends on a specific in-memory array must keep asserting its own condition afterwards.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Every direct persistence-affecting call in `GuestMergeSmoke.swift` MUST execute
  inside an inventory consistency window. Direct means any call that does not already run inside
  `GuestMergeController`'s own boundary.
- **FR-002**: A window MUST open before the first persistence-affecting call of the operation it
  protects, never after it.
- **FR-003**: Every exit path of a protected block — normal completion, thrown error, early
  return — MUST close the window and attempt reconciliation.
- **FR-004**: A failed reconciliation MUST leave the inventory locked, and on an otherwise
  successful path MUST be surfaced as a smoke validation failure rather than ignored.
- **FR-005**: Reconciliation MUST NOT be treated as a user mutation: it MUST NOT write back to
  persistence and MUST NOT stage an outbound mutation.
- **FR-006**: Overlapping or nested protected operations MUST NOT release the window at the inner
  close.
- **FR-007**: The harness's intentional scenario-construction local edits MUST remain outside
  every window.
- **FR-008**: The duplicate-retry scenario MUST continue to resend the identical persisted
  mutation and observe a duplicate no-op rather than a version bump.
- **FR-009**: The simulated second-device scenario MUST continue to produce a stale-confirm
  rejection with zero mutations staged, and a fresh preview that still reports the ambiguous
  duplicate.
- **FR-010**: Cleanup MUST participate in a window, and "cleanup complete" MUST mean an
  observable state: every tracked id staged for soft delete, one coordinator run attempted, and
  local reconciliation succeeded. Residue MUST be reported as exact ids when it cannot be proven
  absent.
- **FR-011**: Baseline seeding in every runner that performs it MUST be able to reach
  `.completed`. **Classification: prerequisite harness-integrity repair.** Three baseline preview
  call sites create a merge preview without the real remote fingerprint that production
  confirmation semantics require, so `confirmMerge` correctly refuses the resulting plan and the
  runner aborts before any checkpoint. The repair MUST make those previews carry the real remote
  fingerprint, MUST stay inside the DEBUG-only smoke file, and MUST NOT change production merge
  behavior. This requirement is **not** a new D-028 semantic, **not** part of the
  consistency-window mechanism, **not** production behavior, **not** sync enablement, and **not**
  permission to broaden this feature. It is not evidence that D-028 was wrong.
- **FR-012**: No sync, merge, smoke, dogfood or diagnostics flag default may change; every
  committed configuration MUST still default them to `NO`.
- **FR-014**: A seeding-only baseline controller MUST NOT leave behind a completed session that
  stays the active rollback-capable session, so the next `preparePreview` in the same runner
  builds a fresh scenario preview rather than resuming the finished baseline.
  **Classification: prerequisite harness-integrity repair**, discovered while implementing
  FR-011. The repair MUST use existing harness configuration rather than altering production
  session lifecycle: `performConfirmMerge`, `activeGuestMergeSession`, rollback persistence
  semantics and the default rollback window MUST all stay unchanged, and production callers MUST
  keep the ordinary rollback window. Like FR-011 this is **not** a new D-028 or D-029 semantic,
  **not** part of the consistency-window mechanism, **not** production behavior, and **not** sync
  enablement.
- **FR-013**: A repository guard MUST fail when a direct persistence-affecting call is added to
  `GuestMergeSmoke.swift` outside a consistency window.

### Key Entities

None. This feature introduces no new domain data; `data-model.md` is deliberately absent.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: The repository guard reports zero direct persistence-affecting calls outside a
  consistency window in `GuestMergeSmoke.swift`.
- **SC-002**: Each protected block has deterministic coverage for both a successful close and an
  injected failure close.
- **SC-003**: A conflicting local edit attempted during a protected block is refused, with no
  durable row change and no outbound mutation staged.
- **SC-004**: Reconciliation stages zero outbound mutations in every covered scenario.
- **SC-005**: An injected reconciliation failure leaves the store locked and the run reports
  failure rather than success.
- **SC-006**: A nested protected operation does not unlock the window at the inner close.
- **SC-007**: All five hosted runners reach their existing final checkpoints against development
  infrastructure, with the same checkpoint semantics as before this feature.
- **SC-008**: Each hosted run ends with zero marker residue, or names the exact residual entity
  ids.
- **SC-009**: Every committed configuration still defaults sync, merge, smoke, dogfood and
  diagnostics flags to `NO` after the change.
- **SC-010**: For each affected runner the baseline confirms, its session completes, it is not
  retained as the active rollback-capable session, and the next preview is a fresh scenario
  preview — while a default-window control still exposes a completed merge as the active
  rollback-capable session.

## Assumptions

- The existing `KitchenStore` window primitive is sufficient; no change to D-028 semantics is
  needed or permitted.
- `GuestMergeSmokeRunner` constructs its own `KitchenStore`, so a reconciliation target always
  exists and D-028's fail-closed branch is unreachable inside the harness.
- Deterministic tests can drive the runner: the smoke configuration has a memberwise
  initializer, `APIEnvironment.current` is `.development` in DEBUG, `transportFactory` is
  injectable, and a signed-in `AuthStore` can be built from a fake auth service.
- Hosted acceptance targets development infrastructure only, and legitimately skips when
  credentials or gates are absent.

## Out of Scope

Enabling `SYNC_ENABLED` or any inventory sync flag; production Supabase provisioning; schema
migration; backend changes; R4 enrollment; production rollout or account migration; shared Redis
sync rate limiting; unrelated sync architecture cleanup; requeue/crash-window debt; rewriting
`KitchenStore`; changing D-028 or D-029 semantics.

## Completion Boundary

Completion means: `GuestMergeSmoke` is trustworthy enough to participate in the pre-dogfood
acceptance gate. Completion does **not** mean sync is enabled, dogfood has started, production is
ready, production Supabase exists, or that Stage 1 or Stage 2 is approved. Actual enablement
remains a separate owner-controlled rollout step.

