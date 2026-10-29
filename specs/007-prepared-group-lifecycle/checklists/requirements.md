# Specification Quality Checklist: PR3 Prepared Group Lifecycle

**Purpose:** Validate the formal specification before owner review; this is not application acceptance.

**Created:** 2026-10-28

**Feature:** [spec.md](../spec.md)

## Content Quality

- [x] User journeys explain selected-group independence and old-record continuity.
- [x] Mandatory template sections are complete: scenarios, requirements, key entities, success criteria and assumptions.
- [x] Technical field/SwiftData/wire contracts are included because the owner explicitly requested a formal architecture specification; no implementation code, plan, tasks or development slices are prescribed.
- [x] Approved decisions, bounded design choices, actual baseline facts and future evidence are distinguishable.

## Requirement Completeness

- [x] Exact lifecycle fields, null/unknown handling and valid phase/timestamp combinations are specified.
- [x] All six valid state/storage/phase combinations and invalid/stale/unavailable cases have action outcomes.
- [x] Untracked legacy ordinary editing is retained; first explicit successful action opts in; measured groups always remain protected.
- [x] Active-thaw split behavior, UUIDs, allocation, timestamps, expiry, consume/delete and no-yield boundaries are explicit.
- [x] Expiry review/defaults/explicit extensions and immediate-meal versus future-use availability are defined.
- [x] Genuine pre-PR2 and PR2 old-layout upgrade evidence is required; nil new-layout rows cannot substitute.
- [x] Original JSON v1/v2/v3 matrix requires explicit v3 lifecycle nulls and rejects old-version lifecycle keys before decoding/re-encoding.
- [x] Preview canonicalization, old-reader rejection, new/old recovery copies, compensation, process cuts and downgrade limits are covered.
- [x] Requirements map to measurable outcomes and focused future acceptance gates; no test results are invented.
- [x] Scope, non-goals, dependencies, stale edits, accessibility limitations and stop conditions are explicit.

## Review and Readiness

- [x] Independent design reviewer has inspected the document against the owner's instructions and merged owning source.
- [x] Independent review returned GO with no P1/P2 findings or unresolved owner questions; the review and bounded author tightenings are recorded in [review.md](../review.md).
- [x] No implementation plan, native test execution or restricted delivery action is authorized by this checklist.

## Notes

The generic Spec Kit checklist's technology-free/no-architecture-detail wording is adapted to the owner's explicit request for exact lifecycle, persistence and backup contracts. This is an architecture specification, not a coding plan. The repository's existing active-feature metadata and branch remain untouched; later authorized planning can select this explicit feature directory. No extension configuration/hooks existed at intake.

Application acceptance gates in spec.md remain unexecuted. Existing PR2 runtime evidence is historical and has not been relabeled PR3 validation.
