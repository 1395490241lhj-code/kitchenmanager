# PR3 Implementation Plan — Independent Review and Disposition

**Date:** 2026-10-29 (America/Toronto)

**Plan:** [plan.md](plan.md)

**Approved design:** [spec.md](spec.md), [specification review](review.md), [quality checklist](checklists/requirements.md). These pre-existing documents remain unchanged by this planning task.

**Implementation baseline:** `ef23d688c8e72107b60acff0c2e7755289994bd0`, merged PR2. Fresh remote main and canonical vault head anchor matched. The older dirty primary checkout was preserved; a read-only archive of the baseline supplied owning-source evidence.

**Independent reviewer:** Separate fresh Codex agent `Lovelace`, ID `01a185da-99ed-71d2-9bf9-87573efbc884`, without a full-history fork. It received approved scope, the plan/design documents and exact-source archive, and was asked for concrete P1/P2 defects without a preferred verdict. It could read but not edit or run builds/tests/devices/fixtures/network operations.

## Verdict

**Final: GO for owner plan review.** Initial review returned HOLD for two P2 validation-ownership gaps, with no P1 finding. Both P2 findings and the minor precision corrections below were resolved in the plan and independently rechecked. No unresolved owner question was identified. The final recheck also explicitly confirmed the pure-value/MainActor-helper distinction and four-new-files Slice 1 boundary.

This GO establishes planning completeness/source consistency, not compilation, migration, backup, process, rendered UI or accessibility acceptance. All A01–A14 runtime gates remain future work under separately authorized slices.

## Material Findings and Resolution

| Finding | Mechanism / consequence | Resolution in final plan | Recheck |
| --- | --- | --- | --- |
| **P2-01 — Existing migration comparator omitted from Slice 2** | `PreparedPortionGroupingSchemaUpgradeTests.snapshot` excludes the newly added PR2 grouping column but would include the new lifecycle column. Comparing an upgraded store to its frozen original would then fail on an added null field, even if old data survived; running only the new suite would postpone discovery until the final full gate. | §3 and Slice 2 explicitly own and target the existing suite. Demonstrate comparator mismatch, then exclude only newly added lifecycle alongside its existing grouping exclusion; retain all 18-table/Prepared/UUID/order assertions. The new actual-PR2-origin comparator still compares its pre-existing grouping blobs. New suite separately asserts column presence/nil and both genuine layouts. Frozen fixture remains unchanged. | Closed by independent re-review. |
| **P2-02 — Actual safe-restore producer and normal-import route not qualified** | `SafeRestoreFixture.swift` was absent from the map. Its historical `legacy` bytes use moving supportedVersion while omitting Prepared, already invalid under v2; dated data follows the evolving encoder. Existing UI helper opens outstanding-copy recovery preview, not normal file import, whose confirmation has different re-encoding behavior. | Add the exact DEBUG producer plus `SafeRestoreFixtureTests` to Slice 3/4. Pin literal v1/v2 original shapes and explicit v3/malformed variants; unit-qualify original bytes before UI use. Split automated recovery-preview/export evidence from the separately required actual normal fileImporter→handler→preview→confirmation→restart receipt. If a supported picker/known-file-delivery flow is unavailable, A08 normal-route evidence stays HOLD; recovery screenshots/unit encoding never clear it. | Closed by independent re-review. |

The corrected plan does not repair these source/test fixtures now; it names the exact later work and truthful evidence boundary.

## Minor Corrections and Author Self-Review

- Correct the callback owner to `HomeQuickMealSection.onUsePreparedPortion`; preserve the displayed full expected row through the sole decrement rather than retrieving a fresh row on tap.
- Name `BackupRestoreView.exportRecoveryCopy()` as the method owner in `MainFeatureViews.swift`.
- Explicitly update the host runner's baseline line-150 new-copy expectation from2 to3 for the PR3 app; retain qualified outstanding old-copy expectations1/2 and use truthful new case/version labels. Keeping the old CLI/default operation path does not freeze obsolete version assertions; historical PR2 receipts remain untouched.
- Pin chronology boundaries: completion equal to start/cooking equal to completion succeed; earlier values reject; cooking recorded before a later thaw stays valid. Add independent fixed Toronto DST versus UTC expected dates, not retry-equality assertions alone.
- Separate immutable/nonisolated metadata/intent/result values from the default-MainActor transition namespace that reuses the existing advisory suggestion helper. The reviewer confirmed this keeps deterministic explicit-input behavior without editing existing helper annotations/day tables or expanding Slice 1 beyond four new files. Later code must explicitly pass captured event time/calendar rather than use helper defaults.
- Distinguish native Swift/build-input changes that invalidate full-unit source binding from host comparator/report-only repairs that require only affected process reruns; retain both actual producer hashes.

No approved architecture was reversed. Active-thaw split inheritance, untracked legacy editing until committed opt-in, measured-group protection, original allocation/no yield, reviewed expiry, original-JSON v3 completeness and seven-domain recovery limits are preserved.

## Review-Ready Outputs and Recommended First Slice

The final plan has five dependency-ordered slices, exact file/interface ownership, targeted RED→GREEN assertions, compatibility/failure/HOLD conditions and complete FR-01–FR-14 → A01–A14 mapping. Reviews occur at pure-contract, genuine-migration, data-contract, source/rendered-UI and final evidence boundaries. One full native unit gate is reserved for stabilized shared inputs; PR2 receipts are infrastructure/provenance references, never fresh PR3 acceptance.

**Recommend Slice 1 only:** `PreparedLifecycle.swift`, `PreparedLifecycleTransition.swift`, `PreparedLifecycleTests.swift`, `PreparedLifecycleTransitionTests.swift`. No active Prepared property, schema, fixture production, store/backup/UI wiring or production state effect. The owner must authorize that bounded slice before any implementation or native execution.

Expected later capability/evidence holds include genuine two-origin migration/write/restart proof, normal system-picker import receipt, actual VoiceOver/focus acceptance, process cuts and Release DEBUG exclusion. These are explicit future gates, not unresolved product choices or results obtained here. Existing power-loss, old-binary downgrade, real-user restore, editor-warning and global-atomicity limitations remain as specified.

## Verification and Preservation

Obtained in this planning task: approved document/current instruction reads; exact merged owning code/test/fixture/runner inspection; independent review and correction recheck; documentation structure/FR/gate/link/whitespace checks; preservation checks on all 16 pre-existing dirty/untracked paths, including approved PR3 artifacts. Only this file and `plan.md` are task-created repository changes.

No Swift/schema/test/backup implementation changed; no native suite/build, fixture generation, simulator/device action, cache creation, branch/commit/PR, push/merge/deployment, canonical status/vault write or production-data operation occurred. No automated setup hook or extra Spec Kit feature pointer/research/tasks artifact was created.

The only scratch path was `/var/folders/q6/xkjcyzf9655_2gcmqk471rrm0000gn/T/km-pr3-plan-codex-11meoanz`, 10,651,111 logical bytes, owned by Codex / Kitchen Manager PR3 plan. It was a reproducible read-only merged-source snapshot, containing no original evidence. After closing the reviewer, archive equality was verified and the disposable snapshot was removed. No task temporary output/cache remains. Original PR2 worktrees, fixtures, evidence, caches and canonical records remain preserved.

## Exit Boundary

Stop after the reviewed plan. No implementation has started. Await owner authorization of Slice 1; this review does not authorize later slices or restricted Git/live-system actions.
