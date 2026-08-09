# Inventory Sync Final Go / No-Go (Phase 2B-7, updated after manual round; Conflict UI severity elevated in Phase 2B-7B; blocker fixed in code in Phase 2B-8; physical-device-validated in Phase 2B-8C; Rollback physical-device-validated in Phase 2B-9B)

> **Phase 2B-7B correction**: Conflict UI is reclassified from
> "architectural gap, not exercised" to a **confirmed production release
> blocker** — see `docs/INVENTORY_MERGE_REMOTE_PREVIEW_FIX_DESIGN.md` for
> the root cause and fix design. Separately, a read-only reconciliation
> found that an earlier claim ("this round's confirm inadvertently
> uploaded 2 real personal inventory items") is not supported by the
> change-feed evidence and has been retracted in
> `docs/INVENTORY_SYNC_PHYSICAL_DEVICE_RESULTS.md` — those items already
> existed before this round's confirm; their origin remains unknown.
> Rollback is now stated as **UNSAFE TO ROLLBACK**, not merely "not
> exercised."

> **Phase 2B-8 update**: the release blocker described below is now **fixed
> in code, simulator-validated, and hosted-development-validated for real**
> — the production preview performs a real authenticated remote read
> (verified end-to-end against the real development Supabase project/Render
> deployment through the actual `GuestMergeController.preparePreview(...
> authStore:)` production call chain: non-zero remote count, conflict
> reachability, zero-write preview, stale-preview rejection, fresh-preview
> recovery, and clean marker teardown all confirmed for real), a
> remote-fingerprint concept invalidates stale plans, and `confirmMerge`
> revalidates the fingerprint before staging any mutation. See
> `docs/INVENTORY_MERGE_REMOTE_PREVIEW_PHASE2B8_VALIDATION.md` for full
> detail. Rollback remains untested and unsafe to attempt on the old,
> pre-existing session referenced below; Phase 2B-8 did not touch or
> attempt to explain that session.

> **Phase 2B-8C update**: physical-device Conflict UI revalidation is now
> **complete and PASS** — remote count, conflict reachability, correct
> local/household values, all four choices, and no internal-ID leakage are
> all confirmed on real hardware for the first time. A second, previously
> invisible bug (resolving the last conflict left the session permanently
> stuck with no way to confirm again) was found and fixed in the same
> round. An unplanned, single, out-of-protocol exercise of Rollback also
> occurred during this round (the device operator tapped it after the fix
> made confirm reachable again) — the observed outcome was clean (no
> orphaned/duplicate data), but this is not a substitute for the formal
> Rollback validation, which **remains the only open item** before this can
> become Production Go. See
> `docs/INVENTORY_SYNC_PHYSICAL_DEVICE_RESULTS.md`'s "Phase 2B-8C" section
> for the full account.

> **Phase 2B-9 update**: the formal, deliberate Rollback validation flagged
> above as the only remaining open item was attempted this round and
> **FAILED** — the on-screen "已回滚本次新增的记录。" success message was
> false. A read-only query against the server's own `sync_mutations` audit
> ledger proved no `delete` operation was ever sent for the entity; it
> remained live remotely with only its version bumped by an unrelated
> upsert. Root cause (confirmed via two offline reproduction tests, no
> device/network involved): `activeGuestMergeSession` treated a `.completed`
> session as terminal/inactive, so a routine `preparePreview` re-check —
> with no app relaunch required — could silently replace the completed
> session and orphan its `createdEntityIds`/`rollbackAvailableUntil`, and
> `rollback()` never verified the staged delete actually applied before
> reporting success. **Both are now fixed in code and regression-tested**
> (see `docs/INVENTORY_SYNC_PHYSICAL_DEVICE_RESULTS.md`'s "Phase 2B-9"
> section for the full account). Physical-device re-validation of Rollback
> against the fixed code is still required before this item can be marked
> PASS — this round only fixed and offline-verified the bug.

> **Phase 2B-9B update**: formal Rollback validation is now **complete and
> PASS** on real hardware. Before the retest, the old Phase 2B-9 marker was
> soft-deleted via a read-only-gated, exact-entity-ID delete (never a prefix
> sweep or broad delete). Getting to a genuinely fresh session surfaced two
> real, non-correctness findings that required stopping and investigating
> rather than guessing: (1) the old, already-cleaned-up session kept being
> recovered by the Phase 2B-9 fix (correct in isolation, since it was still
> within its 24h rollback window) and shadowed the new local marker's own
> preview — resolved by a full uninstall/reinstall, which also reset the
> account's permanent local `.enrolled` flag; (2) that same enrolled flag
> meant a new local item auto-syncs via ordinary CRUD, bypassing Guest merge
> entirely — the accidentally-created entity was cleaned up the same safe
> way. A minor, genuinely silent UI gap was also found and fixed:
> `InventoryMergeResultView` never displayed a failed rollback's error
> message at all. None of this involved a false success, data loss, a
> crash, or cross-account leakage. On the actual fresh session: the Rollback
> tap was independently verified via the server's own `sync_mutations`
> ledger to target the correct, newly-created entity and apply a genuine
> `delete` (change-feed `operation=delete` with `deletedAt` populated,
> unlike the original bug's `operation=upsert`); local Guest data was
> retained; unrelated remote data was unchanged; flags were restored to
> `NO`. See `docs/INVENTORY_SYNC_PHYSICAL_DEVICE_RESULTS.md`'s "Phase 2B-9B"
> section for the full account. **Conclusion upgraded to Production Go
> Candidate** — not Production Enabled; see below.

## Conclusion: **Production Go Candidate** (was Dogfood Go / Production No-Go)

A real iPhone 17 Pro (iOS 27.0) ran the full automated test suite
(including the hosted dogfood smoke) for real, plus a genuine OS-level
app-kill/relaunch cycle — and, this update, a full **human-driven manual
verification round**: the device's operator personally tapped through
login, Guest-merge prompt/skip/recovery/preview, explicit confirm,
create/update/delete + manual sync, offline/reconnect, Wi-Fi/cellular
switch, background/foreground, lock/unlock, force-quit/restart, User A/B
account switching and isolation, diagnostics + export redaction, and final
cleanup — reporting each result back step by step. **A real product bug was
found and fixed during this round** (see below). Two items were explicitly
**not** exercised and are honestly reported as such: the on-screen Conflict
UI (no naturally-occurring conflict existed to show it) and rollback
(skipped rather than risk acting on an ambiguous UI state). Per this
phase's own rule, that means the decision stays at **Dogfood Go, not
Production Go** — not because anything failed, but because two items are
still open rather than verified.

## Why this wasn't a full Production Go (historical — both items below are now resolved as of Phase 2B-9B; kept for the full audit trail)

Two checklist items remained unverified on-screen at the time this section
was written — one was a specifically diagnosed architectural finding, the
other remained genuinely untested. Conflict UI was fixed and confirmed on
real hardware in Phase 2B-8/2B-8C; Rollback was found to have a real bug in
Phase 2B-9, fixed, and confirmed on real hardware in Phase 2B-9B. See the
Phase 2B-9B update note near the top of this document and the Conclusion
above.

1. **Conflict UI — confirmed architecturally unreachable, not just
   "no conflict occurred."** A second attempt this phase deliberately
   engineered an ambiguous-duplicate scenario (a real remote item seeded
   via the authenticated API, a matching local item created on-device).
   The real preview still showed zero cloud items and zero conflicts —
   because `GuestMergeController.preparePreview`'s own source confirms the
   ordinary in-app preview never performs the pre-merge remote read needed
   to detect this at all (`remoteTransport` defaults to `nil` and is,
   per its own doc comment, "never called by the ordinary in-app preview
   flow"). This is deliberate, pre-existing, documented behavior from an
   earlier phase, not a bug introduced here — but it means the
   thoroughly-unit-tested conflict-detection logic in
   `InventoryMergePlanner` is **structurally unreachable from the shipped
   app** regardless of what data exists. See
   `docs/INVENTORY_SYNC_PHYSICAL_DEVICE_RESULTS.md` for the full
   investigation, including an observed predicted-vs-actual mismatch during
   the confirm that followed (which was not further chased down, per the
   stop-on-ambiguity rule).
2. **Rollback** — two separate attempts across two sessions were both
   interrupted before reaching the on-screen rollback flow: first by a
   stale/cached preview screen, second by the confirm-outcome ambiguity
   from the Conflict-UI investigation above (an unclear predicted-vs-actual
   merge result, plus unexplained pre-existing items in the test
   household). Both times, the operator/assistant correctly stopped rather
   than act on unclear state. Rollback logic remains covered by automated
   tests (including on-device), but the on-screen rollback flow itself is
   still untested on a physical device.

Everything else in the human-facing checklist — including the step that
initially crashed — was tapped through for real and passed.

## Full criteria table

| Criterion | Status |
|---|---|
| 真机全流程通过 (full physical-device flow, including UI taps) | ✅ **met (Phase 2B-9B)** — every human-tap step, including Rollback, has now been exercised for real on a physical device and passed; see below |
| 断网恢复通过 (offline recovery) | ✅ **met** — Airplane Mode on/off, offline create, reconnect + sync, all tapped through for real and passed |
| Wi-Fi/cellular 切换通过 | ✅ **met** — tapped through for real, passed |
| 前后台/锁屏恢复通过 | ✅ **met** — backgrounding mid-sync, lock/unlock, all tapped through for real, passed |
| App kill 恢复通过 | ✅ met — a real force-quit with a pending item, relaunch, and sync, tapped through for real and passed (in addition to the earlier `devicectl`-level kill and the simulated in-flight-mutation test) |
| account isolation 通过 | ✅ **met** — User A/B switch tapped through for real: User B correctly showed unmerged state, no leak of User A's synced status; User A's state correctly recovered after re-login |
| conflict UI 通过 | ✅ **met (Phase 2B-8C)** — fixed in code (Phase 2B-8), hosted-validated, and now confirmed for real on a physical device: remote count, conflict reachability, correct local/household values, all four choices, and no internal-ID leakage. A second dead-end bug (found during this same physical-device round) is also fixed. See `docs/INVENTORY_SYNC_PHYSICAL_DEVICE_RESULTS.md`'s "Phase 2B-8C" section |
| rollback 通过 | ✅ **PASS (Phase 2B-9B)** — formally re-attempted on a genuinely fresh physical-device session after the Phase 2B-9 fix, and passed: the Rollback tap was independently verified via the server's own `sync_mutations` ledger to target the correct entity and apply a real `delete` (change-feed shows `operation=delete` with `deletedAt` populated). Local Guest data retained, unrelated remote data unchanged, flags restored. Idempotency verified via existing offline regression rather than a second physical tap (the button had already vanished) |
| diagnostics 脱敏 | ✅ **met** — the operator opened the real diagnostics screen and reviewed the actual export JSON directly: confirmed only counts/statuses/timestamps, no email/password/token/full UUID/household ID/mutation ID/item name |
| consistency checker clean | ✅ met — reported clean during the automated round; not independently re-checked via a fresh on-screen tap this round beyond opening the diagnostics screen |
| hosted dogfood 通过 | ✅ met (unchanged from the automated round) |
| archive safety 通过 | ✅ met (Phase 2B-6, unchanged) |
| production config audit 通过 | ✅ met (Phase 2B-6, unchanged) |
| 0 release blocker | ✅ **met (Phase 2B-9B)** — the Conflict UI release blocker (Phase 2B-8/2B-8C) and the Rollback bug (Phase 2B-9, fixed and physical-device-validated in Phase 2B-9B) are both closed. The inventory-delete crash and the post-conflict dead-end bug were also both fixed, regression-tested, and re-verified. No open release blocker remains. |
| 所有默认 flags 仍为 NO | ✅ met — the device was rebuilt and reinstalled with flags `NO`, verified via `plutil` on the compiled `Info.plist` |
| marker 0 残留 | ✅ met — `scripts/cleanup-guest-merge-smoke-markers.mjs` (now also covering the `__inventory_device_dogfood_` prefix) found 0 rows |

## A real bug was found and fixed this round

Deleting an inventory item from its own detail screen (after that screen
had rendered a Toggle, e.g. "设为常备食材") crashed the app — a stale
array-index captured by a SwiftUI `Binding` closure went out of range once
the array shrank. This is a **pre-existing product bug, unrelated to
sync/dogfood** — reachable in ordinary use independent of any account or
sync state. Root-caused from real crash logs pulled off the device
(`devicectl device info files --domain-type systemCrashLogs`), fixed in
`InventoryItemDetailView` (`KitchenManager/PantryStaples.swift`) by having
every field binding resolve the item fresh by id rather than trusting a
captured index, covered by a new regression UI test
(`testDeletingInventoryItemAfterTogglingStapleDoesNotCrash`), and
re-verified for real on the same physical device. See
`docs/INVENTORY_SYNC_PHYSICAL_DEVICE_RESULTS.md` for full detail.

## What was still needed for Production Go Candidate (both now done as of Phase 2B-9B)

1. **Conflict UI** — fixed in code (Phase 2B-8) and confirmed on real
   hardware (Phase 2B-8C). See `docs/INVENTORY_MERGE_REMOTE_PREVIEW_FIX_DESIGN.md`.
2. **Rollback** — the underlying bug (session orphaned by a routine
   `preparePreview` re-check; success reported without verifying the delete
   actually applied) was fixed in code and offline-regression-tested in
   Phase 2B-9, then formally re-validated on a genuinely fresh physical
   session in Phase 2B-9B: predicted-vs-actual `createdEntityIds`, remote
   soft-delete, and local Guest retention were all verified on hardware
   (independently confirmed via server-side ledger/change-feed evidence,
   not the on-screen message alone). Idempotency was verified via existing
   offline regression rather than a second physical tap.

## What remains before Production Enabled (not attempted, not part of this Go/No-Go)

Reaching **Production Go Candidate** is not the same as enabling production
for real users. Actually flipping any production-facing flag, rolling out
to real accounts, or removing the dogfood-only gating are all separate,
deliberate decisions outside the scope of any Phase 2B round to date — none
of that has been attempted, discussed as ready, or implied by this
conclusion.

## What would change this to No-Go

Any of: the conflict UI or rollback flow, once actually exercised, crashing
or behaving destructively; a new crash discovered anywhere else; data
loss; duplicate creation; cross-account leakage; a secret appearing
on-screen or in a log; or the diagnostics/consistency checker showing
anything other than clean during a real human-driven run.

## Status wording to use anywhere this is referenced

**"Production Go Candidate — not Production Enabled. The Conflict-UI
release blocker (preview was structurally zero-network, and the server has
no business-key deduplication, so a silent duplicate was possible) is fixed
in code, simulator-validated, hosted-development-validated, and
physical-device-validated for real (Phase 2B-8/2B-8C). Formal, deliberate
Rollback validation was attempted in Phase 2B-9 and initially **FAILED** —
the on-screen success message was false, and no delete mutation ever
reached the server — root-caused to a completed session being silently
orphaned by a routine preview re-check, plus Rollback never verifying its
staged delete actually applied. Both were fixed in code, then formally
re-validated on a genuinely fresh physical-device session in Phase 2B-9B and
**PASSED**: the actual Rollback network request was independently verified
via the server's own audit ledger to target the correct entity and apply a
real delete/tombstone; local Guest data was retained; unrelated remote data
was unchanged; flags were restored to `NO`. Getting to that fresh session
also surfaced two non-correctness findings along the way (a still-valid
rollback window on the old, already-cleaned-up session kept getting
recovered by the Phase 2B-9 fix; a permanent local `.enrolled` flag routes
new items through ordinary CRUD sync instead of Guest merge) and one real,
minor, silent-failure UI gap (`InventoryMergeResultView` never displayed a
failed rollback's error message) — all documented and the UI gap fixed in
`docs/INVENTORY_SYNC_PHYSICAL_DEVICE_RESULTS.md`'s Phase 2B-9B section. One
real crash bug (inventory-delete) was found, fixed, and re-verified
on-device in an earlier round. Reaching Production Go Candidate status does
not enable production for real users — that remains a separate, deliberate,
not-yet-attempted decision."** Never shorten this to "production ready" or
"production enabled," and never cite the retracted "2 real personal items
uploaded" claim — see the correction earlier in
`docs/INVENTORY_SYNC_PHYSICAL_DEVICE_RESULTS.md`.
