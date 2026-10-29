# PR3 Formal Specification — Independent Design Review

**Date:** 2026-10-28 (America/Toronto task date)

**Subject:** [007-prepared-group-lifecycle/spec.md](spec.md)

**Baseline:** `ef23d688c8e72107b60acff0c2e7755289994bd0`, merged PR2. Remote main and canonical `Current Status.md` matched this baseline during intake. The older dirty primary checkout was not treated as current implementation evidence.

**Reviewer:** Separate fresh Codex review agent `Jason`, agent ID `01a185ca-48f6-7da3-8581-ea83191d6102`. No full conversation fork was supplied. The reviewer received the owner's exact approved scope/revisions, the specification and the isolated read-only merged-source snapshot. It was asked to identify material defects without a preferred verdict and had no write authorization.

## Verdict and scope

> GO for owner specification review. No P1/P2 findings and no unresolved owner decision identified.

The reviewer read the complete specification and quality checklist, and checked implementation claims against the merged snapshot's PR2 acceptance/closeout, model, persistence/store, backup/preview, meal-policy and upgrade-fixture owning sources. It explicitly considered the final tightening of recovery-copy export behavior, strict lifecycle keys and the distinction between 18 record types and seven restore domains.

This is an independent agent review of specification completeness and consistency. It is not an independent build, runtime test, migration proof, accessibility pass or implementation/planning authorization.

## Findings and disposition

No material findings required a repair round. The review confirmed:

| Contract | Independent assessment |
| --- | --- |
| Legacy compatibility / FR-03 | Ordinary editing survives only while both grouping/lifecycle are nil. Successful explicit action opts in; cancellation/failure does not. Measured groups always remain protected. Stale editors cannot strip metadata or overwrite newer lifecycle/expiry facts. |
| History / FR-02 and FR-04 | Unknown events remain unknown; event fields/validity and supported forward transitions are consistent. Already-cooked food can thaw without becoming prepped or receiving a fabricated cooking date. |
| Active-thaw split / FR-05 | Exact lifecycle/expiry inheritance preserves the existing clock and original allocation; resulting groups can complete/cook independently. No group/source UUID or cooked-yield invention. |
| Expiry / FR-06 | Earlier-date defaults avoid silent extension; completion does not reset the clock; unchanged retries preserve event time/calendar/date; stale actions require renewed review. |
| Backup/recovery / FR-09–FR-11 | Original-byte checks precede normalization; v3 explicitly encodes nil; v1/v2 lifecycle keys reject; validated old candidates become v3 for preview confirmation. Newly generated recovery exports become v3 without rewriting unresolved original bytes or misrepresenting provenance. |
| Meal availability / FR-12 | Per-group filtering precedes source selection, future-use records remain available, and expected-row/eligibility checking stays inside the sole decrement's serialized boundary. |
| Evidence boundaries / FR-08 and FR-14 | Genuine pre-PR2 and PR2 old-layout origins, all 18 record types, seven-domain rollback limits, unsupported live-store downgrade, rendered UI and actual VoiceOver/focus requirements remain explicit. PR2 evidence is historical. |

## Bounded author checks incorporated before final review

These are author tightenings, not issues falsely attributed to the independent reviewer:

- Require exactly the five lifecycle keys and reject unknown/missing payload fields to avoid silently dropping metadata under an unchanged version.
- Explain that the merged normal preview re-encodes the decoded candidate: only originally validated v1/v2 candidates can be normalized to v3. Missing v3 lifecycle keys must never be repaired by re-encoding null.
- Apply the owner's new-export v3 rule to exporting old outstanding recovery contents while preserving the on-device original byte-for-byte. The merged `exportRecoveryCopy()` currently exports raw bytes; future implementation must satisfy the new contract.
- Use “18 record types” for schema-preservation evidence and “seven domains” for backup/restore. Include small-phone Light alongside the existing appearance/accessibility requirements.
- Link PR2 evidence to the exact merged Git revision because copies in the preserved older primary checkout can be stale or absent.

The independent reviewer was notified of these changes and explicitly included the updated text in its final GO. After that verdict, only specification status, checklist completion and this review record were finalized; no behavior/compatibility contract was changed.

## Remaining owner questions and exit boundary

**None identified.** The bounded design choices are explicit in the specification: active-thaw splits inherit metadata; count-only quantity corrections remain ordinary corrections after opt-in while lifecycle/state/storage are protected; no new yield/refreezing/reverse/direct-frozen action is introduced.

The owner must review the formal specification before separately authorizing an implementation plan/development slices. Neither this GO nor the completed checklist starts that next phase.

## Validation actually obtained

- Fresh remote-main identity and canonical-vault anchor inspection, plus exact merged-source/PR2 evidence reads.
- Specification structure, requirement/gate identifiers, JSON fragments, links, placeholders and whitespace checked as documentation.
- Independent design review above; no material unresolved findings.
- Pre-existing dirty-file/symlink fingerprints and Git state checked for preservation; only the new `specs/007-prepared-group-lifecycle/` documents belong to this task.

No Swift production/schema/test/backup implementation changed. No native build/test suite, simulator/device action, new old-layout fixture production, CI rerun, commit, push, PR, merge, deployment or production data action ran. All runtime gates in the specification are future requirements. Existing PR2 VoiceOver/focus, editor-warning, power-loss and downgrade limitations remain open as documented.

## Artifact and temporary-output lifecycle

Retain this specification, checklist and review as the requested reviewable deliverables. No `plan.md`, `tasks.md`, branch, feature-pointer/configuration rewrite or canonical-vault mutation was created. The local template/constitution was used with the owner's explicitly requested architecture detail; extension configuration/hooks were absent.

The sole task-created scratch path was `/var/folders/q6/xkjcyzf9655_2gcmqk471rrm0000gn/T/km-pr3-spec-codex-759948js` (8,775,021 logical bytes), owned by Codex / Kitchen Manager PR3 specification. It held a reproducible read-only merged-source archive and no original evidence. After closing the reviewer, all 626 snapshot files were verified unchanged against the exact merged archive and the disposable snapshot was removed. No task temporary output/cache remains. Original PR2 worktrees, fixtures and evidence remain outside that disposable snapshot and are preserved.
