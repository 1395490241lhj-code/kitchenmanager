# Requirements Quality Checklist: GuestMergeSmoke direct-call consistency window

**Purpose**: Reviewer-owned requirements-quality review for feature 004 before implementation.
**Created**: 2026-09-12
**Feature**: [spec.md](../spec.md)

**Review Ownership**: This is a requirements-quality artifact. Mark an item `[x]` only when the
reviewer determines the criterion is satisfied. `[x]` does not mean implementation is complete.

## Scope and boundaries

- [ ] CHK001 The bounded change is stated explicitly and the out-of-scope list names every
      excluded area the request called out (sync enablement, Supabase provisioning, schema
      migration, backend, R4, rollout, account migration, Redis rate limiting, unrelated sync
      cleanup, requeue/crash-window debt, `KitchenStore` rewrite, D-028/D-029 semantics)
- [ ] CHK002 The completion boundary distinguishes "harness is trustworthy" from "sync is
      enabled / dogfood started / production ready / Stage 1 or Stage 2 approved"
- [ ] CHK003 FR-011 is identified as a discovered prerequisite with its rationale, rather than
      silently absorbed scope

## Contract integrity

- [ ] CHK004 Every guarantee attributed to D-028 is traceable to the canonical Decision or to
      current implementation, and no requirement rewrites it
- [ ] CHK005 D-029 rollback semantics are preserved and explicitly covered by a requirement
- [ ] CHK006 No requirement weakens a confirmation step, a safety default, local-first behavior
      or an existing data protection
- [ ] CHK007 No requirement changes a flag default, and FR-012 states this as a checkable outcome

## Operation boundaries

- [ ] CHK008 Every direct persistence-affecting call is classified A, B, C or D with no
      unexplained Category D remaining
- [ ] CHK009 Each proposed window names its first persistence-affecting call and its last, and no
      scenario-construction local edit falls inside any window
- [ ] CHK010 Requirements cover all exits — normal completion, thrown error and early return
- [ ] CHK011 Reconciliation failure has a defined safe state rather than an assumed one
- [ ] CHK012 Nested and overlapping operations have a stated requirement, not an assumption

## Scenario preservation

- [ ] CHK013 The duplicate-retry contract the smoke exists to exercise is protected by its own
      requirement
- [ ] CHK014 The simulated second-device and stale-preview behavior is protected by its own
      requirement, and the analysis states why reconciliation cannot erase the test condition
- [ ] CHK015 Cleanup semantics define "complete" observably, and residue is reported as exact ids
      when it cannot be proven absent

## Testability

- [ ] CHK016 Every success criterion is measurable and technology-agnostic
- [ ] CHK017 Every functional requirement has at least one task that would demonstrably fail if
      the requirement were violated
- [ ] CHK018 Deterministic coverage is the merge gate and hosted runs are an additional layer,
      never a substitute
- [ ] CHK019 The test feasibility claims (smoke configuration, DEBUG environment, injectable
      transport, constructible signed-in auth) are verified against current code rather than
      assumed

## Ambiguity

- [ ] CHK020 No requirement contains an unresolved `NEEDS CLARIFICATION` marker
- [ ] CHK021 No requirement implies that sync gets enabled as part of this feature
- [ ] CHK022 The one open owner decision (whether FR-011 stays in this feature) is stated in the
      handoff rather than decided silently

## Notes

- Leave items unchecked while they still require reviewer evaluation.
- `/speckit-implement` reads checkbox state as a gate and must not modify markers.

