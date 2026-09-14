---
description: "Task list for feature 005 — Safe backup restore"
---

# Tasks: Safe backup restore

**Input**: Design documents from `/specs/005-safe-backup-restore/`

**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md), [quickstart.md](./quickstart.md)

**Tests**: Included, and not optional. The risk this feature addresses is silent data loss, so the
pre-mutation boundary and every failure branch carry deterministic coverage.

**Organization**: Phases follow `plan.md`. Story labels map tasks back to the user stories in
[spec.md](./spec.md).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel — different files, no dependency on incomplete tasks
- **[Story]**: US1, US2, US3

## Implementation Sequence Freeze

| Phase | Content | Separate commit |
|---|---|---|
| 1 | setup and failure-injection seam | yes |
| 2 | validation gate | yes |
| 3 | persistence save-failure cleanup | yes |
| 4 | pre-restore recovery copy | yes |
| 5 | outcome model and state consistency | yes |
| 6 | preview, confirmation, outcome presentation | yes |
| 7 | validation and seal | yes |

**Phase 3 MUST NOT be deferred until after Phase 4.** The recovery contract is only meaningful for
shopping, consumption, prepared components and special plans once a compensating write immediately
after a failed write is reliable (`research.md` R5).

---

## Phase 1: Setup

- [x] T001 Confirm the branch is `codex/005-safe-backup-restore`, the base is `dbb7bce`, and the
      tree is clean before any source change
- [x] T002 Re-verify the three premises against current code: `format`/`version` have no readers,
      every payload field is `decodeIfPresent`-tolerant, and the four named persistences have no
      save-failure cleanup. If any premise has changed, stop and report rather than proceeding
- [x] T003 [P] Extend the existing `Failing*Persistence` seam so a test can make a chosen domain
      fail on a chosen call instead of on every call (FR-029)
- [x] T004 [P] Add a test helper that asserts all seven backup-scoped domains are byte-identical
      to a captured baseline, for reuse by every zero-mutation assertion

## Phase 2: Validation gate (US1)

- [x] T005 [US1] Introduce a validation result that distinguishes unreadable bytes, not-a-Kitchen-
      Manager-backup, and unsupported-version, and carries the creation date and per-domain counts
      a preview needs (FR-001..FR-004, FR-006)
- [x] T006 [US1] Reject a payload whose format identifier is not exactly the supported format
      (FR-002)
- [x] T007 [US1] Reject a payload whose version is not exactly the supported version, including
      newer versions, per the strict policy in `research.md` R2 (FR-003)
- [x] T008 [US1] Reject a structurally decodable object carrying no recognisable backup content,
      including `{}` (FR-004)
- [x] T009 [US1] Route restore through the gate so validation failure returns before any write
      (FR-005, FR-011)
- [x] T010 [P] [US1] Tests: `{}`, unrelated JSON object, wrong format, unsupported version,
      malformed bytes, and a valid v1 file — each asserting the refusal reason and, via T004, zero
      mutation across all seven domains (SC-001, SC-003)
- [x] T011 [P] [US1] Test: a legitimately empty but well-formed v1 backup is accepted, not refused,
      and its zero counts are reported honestly (spec Edge Cases)
- [x] T012 [P] [US1] Test: a v1 file omitting `preparedComponents` and `specialPlans` is still
      accepted, protecting real shipped v1 files (`research.md` R2)

## Phase 3: Persistence save-failure cleanup

- [x] T013 Shopping list: a failed save MUST NOT leave residue that breaks the immediately
      following compensating write (FR-025)
- [x] T014 Consumption records: same requirement (FR-025)
- [x] T015 Prepared components: same requirement (FR-025)
- [x] T016 Special plans: same requirement (FR-025)
- [x] T017 [P] Regression tests pinning, for each of the four domains, that a write failure
      followed immediately by a compensating write succeeds — the dirty-context regression
      (SC-009)
- [x] T018 [P] Test: the three domains that already clean up, and inventory's fresh-context
      behaviour, are unchanged by this phase

## Phase 4: Pre-restore recovery copy

- [ ] T019 Capture a durable copy of the backup-scoped data, from the existing export bytes, after
      confirmation and before the first write (FR-015)
- [ ] T020 Make the copy's creation a precondition of the point of no return: on failure the
      restore does not begin and the outcome is distinct from a validation failure (FR-013, FR-014)
- [ ] T021 Implement the single-slot lifetime from `research.md` R3: removed on success or proven
      recovery, retained while an unproven outcome is unresolved, replaced rather than accumulated
      (FR-017)
- [ ] T022 [P] Tests: the copy exists at the moment of the first write, is removed after success
      and after proven recovery, survives a simulated process restart, and a failed creation
      produces zero mutation (SC-003, SC-005)

## Phase 5: Outcome model and state consistency

- [ ] T023 Introduce the five-state outcome from FR-018 and return it from the restore path
- [ ] T024 Make compensation report its own result so a recovery failure is never discarded
      (FR-020)
- [ ] T025 After success, in-memory reflects the restored data (FR-022)
- [ ] T026 After proven recovery, in-memory equals what is stored (FR-023)
- [ ] T027 After an unproven outcome, re-establish every backup-scoped domain from persistence,
      following the existing `reconcileInventoryFromPersistence` shape; if a domain cannot be
      re-read, surface it and keep the recovery path available (FR-024, `research.md` R4)
- [ ] T028 [P] Tests: inject a write failure in each of the seven domains in turn and assert the
      resulting outcome, whether recovery was proven, and the post-state of in-memory versus
      persistence (SC-004, SC-009)
- [ ] T029 [P] Test: user recipes, favourites and frequent records are unchanged across success,
      proven recovery and unproven outcome alike (FR-026, SC-006)

## Phase 6: Preview, confirmation and presentation (US2, US3)

- [ ] T030 [US2] Present the validated backup before any write: creation date, per-domain counts,
      and the statement that restore replaces backup-scoped local data (FR-007, FR-008)
- [ ] T031 [US2] Name user recipes, favourites and frequent records as unchanged in that surface
      (FR-009)
- [ ] T032 [US2] Require explicit confirmation using the platform's destructive treatment, with
      abandonment leaving zero mutation (FR-010, FR-011, FR-012)
- [ ] T033 [US3] Present the five outcomes distinguishably, with proven recovery and unproven
      state reading differently, and offer the recovery action and export on an unproven outcome
      (FR-016, FR-019)
- [ ] T034 Normalise file-picker dismissal to a non-error outcome with no mutation and no alert
      (FR-028, `research.md` R6)
- [ ] T035 Review all new member-facing copy against FR-021: no merge, no atomic, no promise of
      full recoverability
- [ ] T036 [P] [US2] UI tests: selecting a valid file alone mutates nothing; the preview's counts
      match the payload; cancelling mutates nothing; confirmation is required (SC-002, SC-003)
- [ ] T037 [P] [US3] UI tests: each outcome is distinguishable; the replacement warning and the
      outcome message are readable at AXXXL without truncation and are announced under VoiceOver
      (SC-004, SC-007)
- [ ] T038 [P] Test: dismissing the picker produces no error surface (SC-008)

## Phase 7: Validation and seal

- [ ] T039 Run the focused suites from `quickstart.md`, including the existing
      `SettingsExperienceUITests` unchanged, and record real counts
- [ ] T040 Compare compiler warnings for every touched file against a clean-baseline build and
      report the delta
- [ ] T041 Re-check the package against the out-of-scope list in `spec.md`: no clear-local-data
      change, no sync, no payload expansion, no encryption, no cloud backup, no global persistence
      refactor. Remove or defer anything that crept in
- [ ] T042 Confirm no requirement, task or member-facing string claims atomicity
- [ ] T043 Produce the `AGENTS.md` final report and decide the vault write-back, without
      committing, pushing or reconciling anything not explicitly authorised

## Traceability

| Requirement | Tasks |
|---|---|
| FR-001..FR-006 | T005-T012 |
| FR-007..FR-010 | T030-T032, T036 |
| FR-011 | T009, T032, T036 |
| FR-012 | T032, T037 |
| FR-013, FR-014 | T020, T022 |
| FR-015..FR-017 | T019-T022, T033 |
| FR-018, FR-019 | T023, T033, T028, T037 |
| FR-020 | T024, T028 |
| FR-021 | T035, T042 |
| FR-022..FR-024 | T025-T028 |
| FR-025 | T013-T018 |
| FR-026 | T029 |
| FR-027 | T041 |
| FR-028 | T034, T038 |
| FR-029 | T003, T004 |

| Success criterion | Tasks |
|---|---|
| SC-001 | T010 |
| SC-002 | T030, T036 |
| SC-003 | T010, T022, T036 |
| SC-004 | T028, T033, T037 |
| SC-005 | T022, T033 |
| SC-006 | T029 |
| SC-007 | T037 |
| SC-008 | T038 |
| SC-009 | T017, T028 |

## Slice status

**Completed**: Phase 1 partially (T001, T002, T004) and Phase 2 in full (T005-T012), delivered as
the backup validation gate. T003 is deliberately still open: this slice needed only a
zero-write spy, and the per-call failure seam it describes is first required by the phases that
inject write failures.

**Phase 3 complete**: shopping, consumption, prepared components and special plans now roll their
context back on any replace failure, matching today-plan and weekly-plan. T003 is closed by the
one-shot DEBUG save seam those tests needed.

**Correction to the Phase 3 rationale, from running the tests**: the unique-id collision described
by `SwiftDataTodayPlanPersistence` and carried into `research.md` R5 did **not** reproduce on this
SwiftData version — with the cleanup removed, a compensating replace over a dirty context still
succeeded. The hazard that is real here, verified by removing the cleanup and watching all four
domains go red, is that a failed replace stays readable from the same context as though it had
been saved. The requirement FR-025 states is unchanged and still satisfied; only the mechanism
named in the rationale was narrower than reality. Phase 4 should rely on the proven behaviour
rather than on the collision story.

**Discovered during implementation, an input to Phase 6**: the oldest real v1 files omit
`exportedAt`, so `KitchenBackupPayload` substitutes the decode-time date. The preview required by
FR-007 must therefore treat a missing backup date honestly rather than presenting today's date as
the backup's. This does not contradict the spec; research R2 already establishes that v1 files
omit keys legitimately.
