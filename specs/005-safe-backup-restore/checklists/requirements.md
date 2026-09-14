# Requirements Quality Checklist: Safe backup restore

**Purpose**: Reviewer-owned requirements-quality review for feature 005 before implementation.
**Created**: 2026-09-14
**Feature**: [spec.md](../spec.md)

**Review Ownership**: This is a requirements-quality artifact. Mark an item `[x]` only when the
reviewer determines the criterion is satisfied. `[x]` does not mean implementation is complete.

## Scope and boundaries

- [ ] CHK001 The bounded change is stated explicitly, and the out-of-scope list names every
      excluded area the request called out: clear-local-data aggregation, cloud backup, sync,
      GuestMerge, scheduled backup, encryption, signing, payload expansion to user recipes,
      merge-style restore, true cross-domain atomicity, persistence-architecture unification,
      broad schema redesign, arbitrary historical migration, Settings visual redesign
- [ ] CHK002 Clear-local-data appears only as a deferred item, and no requirement or task changes
      its behaviour
- [ ] CHK003 No requirement expands `KitchenBackupPayload`'s domains
- [ ] CHK004 The Settings P1 information architecture and its test-locked copy are preserved, and
      no requirement restyles Settings

## Truthfulness of the product contract

- [ ] CHK005 No requirement, success criterion or task describes restore as atomic
- [ ] CHK006 No requirement promises recoverability the chosen strategy cannot deliver, and the
      residual failure mode is named rather than designed away
- [ ] CHK007 The word "merge" is not used for an operation that replaces
- [ ] CHK008 The guarantee is stated as "successful restore or a truthful, proven recovery result"

## Pre-mutation safety

- [ ] CHK009 The point of no return is defined as an ordered list of preconditions and is stated
      to be observable in tests
- [ ] CHK010 Every requirement that rejects input also states the zero-mutation consequence
- [ ] CHK011 Validation is distinguished from decoding, and "decoded" is never treated as "valid"
- [ ] CHK012 `{}` and unrelated JSON objects are covered by an explicit requirement, not left to
      a general "malformed" case
- [ ] CHK013 The version policy is explicit about rejecting newer versions, with rationale for
      strictness rather than accidental forward compatibility
- [ ] CHK014 A legitimately empty v1 backup is distinguished from an empty object, and remains
      restorable

## User agency

- [ ] CHK015 The preview's required content is specified in observable terms: creation date,
      per-domain counts, replacement scope, untouched domains
- [ ] CHK016 Abandoning the restore before confirmation is a requirement with a zero-mutation
      consequence
- [ ] CHK017 Confirmation is required as a distinct act from file selection
- [ ] CHK018 Accessibility of the destructive confirmation and of the outcome message is a
      requirement, not an implementation note

## Failure and recovery

- [ ] CHK019 The result states are enumerated, mutually exclusive, and each is reachable
- [ ] CHK020 Proven recovery and unproven state are required to read differently to the member
- [ ] CHK021 A recovery or rollback failure is required to be surfaced and is never silent
- [ ] CHK022 The behaviour after an unproven outcome is specified for what the member sees, not
      only for what is stored
- [ ] CHK023 The recovery copy's location, creation point, lifetime, removal and member-visible
      path of use are all specified
- [ ] CHK024 Failure of recovery preparation is specified as zero mutation and reported distinctly

## Correctness preconditions

- [ ] CHK025 The four persistences needing save-failure cleanup are named, with the reason tied to
      this feature's recovery contract rather than to opportunistic cleanup
- [ ] CHK026 That requirement is expressed as behaviour, not as a mandated API call
- [ ] CHK027 The sequencing reason for repairing persistence before building recovery is stated

## Preserved data

- [ ] CHK028 User recipes, favourites and frequent records are required to remain unchanged, with
      acceptance coverage required rather than assumed
- [ ] CHK029 That coverage spans successful, recovered and unproven restore paths

## Testability

- [ ] CHK030 Every functional requirement is observable and could fail a test
- [ ] CHK031 Requirements avoid naming specific types, APIs or UI components except where the
      existing architecture makes it unavoidable
- [ ] CHK032 Deterministic failure injection is a requirement, and tests are not permitted to rely
      on provoking real persistence faults
- [ ] CHK033 Every success criterion is measurable without knowing the implementation
- [ ] CHK034 Every functional requirement maps to at least one task, and every task traces back to
      a requirement or success criterion

## Evidence integrity

- [ ] CHK035 Every governing fact in the Problem section is traceable to current code rather than
      to a prior report
- [ ] CHK036 The premise re-verification task exists and is permitted to stop the work if a
      premise has changed
- [ ] CHK037 No NEEDS CLARIFICATION marker remains in the package
