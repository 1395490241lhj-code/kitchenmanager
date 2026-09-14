# Feature Specification: Safe backup restore

**Feature Branch**: `codex/005-safe-backup-restore`

**Feature ID**: 005

**Created**: 2026-09-14

**Status**: Draft

**Input**: Make local backup import safe, understandable and recoverable enough for normal users:
select file -> validate -> preview replacement scope -> explicit confirmation -> restore ->
truthful result.

## Problem

Importing a kitchen backup is today the most destructive reachable action in the native iOS app,
and it is the one with the least user agency. The Settings Data Safety archaeology at
`dbb7bce` established the following as facts of the current implementation.

`KitchenBackupPayload` carries `format` and `version`, and **no code anywhere reads either one**.
Its decoder resolves every field with `decodeIfPresent ?? []`, so any file that is a JSON object
decodes successfully; unrecognised keys are ignored and absent keys become empty. `{}` is a
fully valid input that produces a payload with seven empty domains.

`BackupRestoreView` hands the selected file straight to `restoreBackupData`. Between the moment
the user taps a file in the system picker and the first irreversible write there is no preview,
no confirmation, no summary and no cancel. The consequence is that picking the wrong `.json`
file in Files -- another app's export, a recipe file, a config -- runs to completion without any
error and reports `厨房数据已恢复。` while the kitchen has been emptied.

The mutation itself is seven sequential `replaceX` calls, each committing on its own
`ModelContext`. It is not one transaction. Failure partway leaves a compensating rollback that
is best-effort and entirely silent (`try?`). Four of the participating persistences -- shopping
list, consumption records, prepared components and special plans -- hold long-lived contexts
with no cleanup on save failure, so the compensating write runs against a context still holding
the failed attempt's deletes and inserts, against records whose `id` is a unique attribute. That
is the exact failure mode the today-plan persistence documents its own rollback as existing to
prevent. On failure the in-memory store keeps the old values while persistence may hold a mix,
and nothing surfaces that divergence until the next launch.

User recipes, favourites and frequent-recipe records are genuinely outside the payload and are
never touched by restore. That is the one part of the current contract that is already true and
must stay true.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A wrong or unrelated file cannot destroy the kitchen (Priority: P1)

A member wants to restore last month's backup. In the Files picker they tap the wrong document --
another app's export, a stray JSON, or a file that only looks like a backup. The app tells them
this is not a usable Kitchen Manager backup and nothing about their kitchen changes.

**Why this priority**: This is the catastrophic path, and it needs no failure and no edge case to
reach. It is reachable by a single mis-tap today and destroys seven data domains silently.

**Independent Test**: Drive the import entry point with `{}`, with an unrelated JSON object, with
a wrong `format`, with an unsupported `version`, and with malformed bytes. Assert each is refused
and that every backup-scoped domain is byte-identical afterwards.

**Acceptance Scenarios**:

1. **Given** a kitchen with data in every backup-scoped domain, **When** the member selects a file
   whose contents are `{}`, **Then** the app reports that the file is not a usable backup and no
   domain changes.
2. **Given** the same kitchen, **When** the member selects a JSON object belonging to another
   application, **Then** the file is refused before any write and no domain changes.
3. **Given** the same kitchen, **When** the member selects a file whose `format` is not the
   supported Kitchen Manager backup format, **Then** it is refused before any write.
4. **Given** the same kitchen, **When** the member selects a backup whose `version` is not a
   supported version, including a higher future version, **Then** it is refused before any write
   and the reason is distinguishable from an unreadable file.
5. **Given** the same kitchen, **When** the member selects bytes that are not valid JSON, **Then**
   it is refused before any write.

---

### User Story 2 - The member decides, with the facts in front of them (Priority: P1)

A member selects a real backup. Before anything is replaced, the app shows when the backup was
made, what will be replaced and how much of it, and what will be left alone. The member can back
out, and nothing has changed. Only an explicit confirmation starts the restore.

**Why this priority**: Validation alone stops the catastrophic case but still leaves the member
unable to tell a January backup from a March one before overwriting their kitchen with it. Agency
is the second half of the same problem, and restoring the wrong *valid* backup is unrecoverable
without it.

**Independent Test**: Select a valid backup, assert no persistent change has occurred at the
moment the preview appears, assert the preview's counts equal the payload's counts, cancel, and
assert the kitchen is unchanged.

**Acceptance Scenarios**:

1. **Given** a valid backup is selected, **When** the preview appears, **Then** no backup-scoped
   domain has changed yet.
2. **Given** the preview is shown, **Then** it states the backup's creation date and, for each
   domain that will be replaced, how many items the backup contains.
3. **Given** the preview is shown, **Then** it states plainly that restoring replaces the local
   data inside the backup's scope, and names user recipes, favourites and frequent records as
   unchanged.
4. **Given** the preview is shown, **When** the member cancels, **Then** nothing is written and
   they return to Backup & Restore normally.
5. **Given** the preview is shown, **When** the member confirms through the destructive
   confirmation, **Then** and only then does the restore begin.

---

### User Story 3 - A failed restore tells the truth and leaves a way back (Priority: P2)

A restore fails partway through. The app does not claim success, and it does not flatten the
outcome into one vague error. It distinguishes "your original data is back" from "your data may
be incomplete", and in the second case it offers the member the pre-import copy it took before it
started.

**Why this priority**: Lower than P1 because it requires a persistence failure to reach, but it is
the difference between a recoverable incident and permanent silent corruption. It is also the
only part of the feature that can honestly justify the word "safe".

**Independent Test**: Inject a deterministic failure at each domain write in turn; assert the
result state, whether recovery was proven, and what the member is told and offered.

**Acceptance Scenarios**:

1. **Given** recovery preparation cannot be completed, **When** the member confirms, **Then** the
   restore does not begin and no domain changes.
2. **Given** a restore fails after one or more domains were written and the original state is
   provably back, **Then** the member is told the restore did not complete and their data was
   restored.
3. **Given** a restore fails and recovery cannot be proven, **Then** the member is told the local
   data may be incomplete, and is offered the pre-import copy.
4. **Given** recovery itself fails, **Then** that failure is surfaced; it is never swallowed.
5. **Given** an unproven-recovery outcome, **When** the member returns to the app, **Then** what
   they see reflects what is actually stored, not the pre-import values the app happened to still
   hold in memory.

---

### Edge Cases

- The member dismisses the system file picker without choosing anything: a normal outcome, no
  mutation and no error surface.
- A backup is valid but every domain is empty because the kitchen was empty when it was exported.
  This is legitimate and must remain restorable; it is distinguishable from `{}` by its `format`
  and `version`, and the preview must show the zero counts honestly so the member can decline.
- A backup contains repeated ids inside one domain.
- A backup is large enough that preview counting must not block the interface.
- The member confirms a restore while an inventory consistency window is open: the existing
  refusal stays in force and is reported as a pre-mutation failure.
- A recovery copy already exists from an earlier failed attempt when a new restore begins.

## Requirements *(mandatory)*

### Functional Requirements

**Validation, before any persistent write**

- **FR-001**: The system MUST reject a selected file whose bytes are not structurally valid for
  the backup format, before any persistent write.
- **FR-002**: The system MUST reject a payload whose format identifier is not exactly the
  supported Kitchen Manager backup format.
- **FR-003**: The system MUST reject a payload whose version is not an explicitly supported
  version, including any version newer than the app supports.
- **FR-004**: The system MUST reject a structurally decodable object that carries no recognisable
  Kitchen Manager backup content, including an empty object.
- **FR-005**: Any validation failure MUST result in zero persistent mutation in every domain.
- **FR-006**: The system MUST distinguish validation failure reasons to the member at least as
  "cannot be read", "not a Kitchen Manager backup", and "from a newer version of the app".

**Agency, before any persistent write**

- **FR-007**: After validation succeeds and before any persistent write, the system MUST present
  the member with the backup's creation date and, per domain to be replaced, the number of items
  the backup contains.
- **FR-008**: That presentation MUST state that restoring replaces the local data within the
  backup's scope.
- **FR-009**: That presentation MUST name user recipes, favourites and frequent records as data
  the restore will not change.
- **FR-010**: The member MUST be able to abandon the restore from that presentation with zero
  persistent mutation.
- **FR-011**: Selecting a file MUST NOT by itself mutate any domain; an explicit member
  confirmation MUST be required to begin the restore.
- **FR-012**: The confirmation MUST carry the platform's destructive-action treatment and MUST be
  operable and comprehensible with assistive technology and at accessibility text sizes.

**Point of no return**

- **FR-013**: No persistent mutation may begin until, in order, the file read succeeded, the
  payload decoded, validation passed, the presentation was shown, the member confirmed, and
  recovery preparation succeeded. This boundary MUST be observable in tests.
- **FR-014**: If recovery preparation cannot be completed, the restore MUST NOT begin and the
  outcome MUST be reported distinctly from a validation failure.

**Recovery**

- **FR-015**: Before the first persistent write, the system MUST capture a copy of the current
  backup-scoped data that survives termination of the app process.
- **FR-016**: When a restore ends without proven recovery, the member MUST be able to act on that
  captured copy from within the app, and MUST be able to take it out of the app as a file.
- **FR-017**: The captured copy's lifetime MUST be defined and bounded: it MUST persist for at
  least as long as an unresolved unsafe outcome, and MUST NOT accumulate without limit.

**Truthful results**

- **FR-018**: Every restore attempt MUST end in exactly one distinguishable outcome: success;
  validation failed with no mutation; preparation failed with no mutation; failed with the
  original state proven restored; or failed without proven recovery.
- **FR-019**: The interface MUST NOT collapse those outcomes into a single generic failure
  message; in particular a proven-recovered outcome and an unproven outcome MUST read differently.
- **FR-020**: A recovery or rollback failure MUST be surfaced to the member and MUST NOT be
  silently discarded.
- **FR-021**: Member-facing copy MUST NOT describe restore as a merge, as atomic, or as fully
  recoverable.

**State consistency**

- **FR-022**: After a successful restore, what the member sees MUST reflect the restored data.
- **FR-023**: After a failure with proven recovery, what the member sees MUST reflect the original
  data, and it MUST match what is stored.
- **FR-024**: After a failure without proven recovery, the app MUST NOT continue presenting its
  pre-restore in-memory values as trustworthy; it MUST re-establish what it shows from what is
  actually stored, and if it cannot, it MUST say so and keep the recovery path available.

**Persistence hygiene**

- **FR-025**: When a domain write fails, the failure MUST NOT leave that domain's persistence in a
  state where the immediately following compensating write is rejected or corrupted by residue of
  the failed attempt. This MUST hold for the shopping list, consumption records, prepared
  components and special plans, matching the behaviour the today-plan and weekly-plan persistences
  already provide.

**Preserved contracts**

- **FR-026**: Restore MUST leave user recipes, favourites and frequent records unchanged, and this
  MUST be proven by acceptance coverage rather than assumed.
- **FR-027**: The exported backup payload's domains MUST NOT change in this feature.
- **FR-028**: Dismissing the file picker without choosing a file MUST be treated as a normal
  outcome: no mutation, and no failure surface.
- **FR-029**: The implementation MUST provide deterministic seams that let tests force validation
  outcomes and per-domain write failures without relying on real persistence faults.

### Key Entities

- **Validated backup**: the result of proving that decoded bytes are a supported Kitchen Manager
  backup. Distinct from "decoded": decoding is a syntax result, validation is an identity and
  compatibility result. Carries the creation date and the per-domain counts the preview needs.
- **Restore outcome**: the single result of an attempt, drawn from the five states in FR-018,
  carrying enough detail to tell the member which domains were involved and whether recovery was
  proven.
- **Pre-restore recovery copy**: a durable copy of the backup-scoped data as it stood immediately
  before the first write, with a defined location, creation point, lifetime and member-visible
  path of use. Its contract is decided in `research.md` R3.

`data-model.md` is deliberately absent: this feature adds no persisted domain model and does not
change `KitchenBackupPayload`. The three entities above are contracts, and the recovery copy's
storage and lifetime are specified in `research.md` R3 rather than duplicated.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Every non-Kitchen-Manager JSON object tested, including an empty object, is refused
  with zero change to all seven backup-scoped domains.
- **SC-002**: Before confirming, a member can state the backup's date and how many items each
  affected domain will be replaced with, without leaving the confirmation surface.
- **SC-003**: Across every path that ends before confirmation -- picker dismissal, unreadable
  file, wrong format, unsupported version, empty object, member cancellation -- zero persistent
  writes occur.
- **SC-004**: Every restore attempt reports exactly one of the five outcomes, and a member reading
  the message can tell whether their original data is back or may be incomplete.
- **SC-005**: After any restore that ends without proven recovery, the member has an in-app action
  that targets the pre-import copy, and can export that copy as a file.
- **SC-006**: User recipes, favourites and frequent records are unchanged after every restore path
  exercised, successful and failed alike.
- **SC-007**: The replacement warning and the outcome message are fully readable at the largest
  accessibility text size without truncation, and are announced by the screen reader.
- **SC-008**: Dismissing the file picker never produces an error message.
- **SC-009**: A forced write failure in each of the seven domains in turn produces a reported
  outcome, never a success message and never a silent swallow.

## Assumptions

- Version 1 is the only backup version that has ever been written by a shipped build, so there is
  no historical backup that a strict version rule would strand. See `research.md` R2.
- The app's own container is not user-browsable (no file-sharing entitlement is declared), so a
  recovery copy kept there is not discoverable by the member without an in-app affordance. This is
  why FR-016 requires both an in-app action and an export.
- A member who imports a backup expects replacement, not merge; the current copy already says so
  and this feature does not change that expectation.
- Restoring a legitimately empty backup remains allowed; emptiness is a member decision surfaced
  by the preview, not a validation failure.

## Out of Scope

Explicitly deferred, and not to be absorbed during implementation:

- Clear-local-data cross-store result aggregation, and any other change to clear semantics. It was
  found in the same archaeology and is deliberately a separate concern.
- True cross-domain atomic transactional restore, and any unification of the persistence layer's
  context architecture to achieve it.
- Cloud backup, scheduled or automatic backup, encryption, and cryptographic signing or integrity
  proofs.
- Supabase, sync, and GuestMerge in any form.
- Adding user recipes, favourites or frequent records to the backup payload.
- Merge-style restore.
- Migration of historical backup versions beyond what version 1 safety requires.
- Any Settings visual redesign, and any change to the Settings P1 information architecture.
