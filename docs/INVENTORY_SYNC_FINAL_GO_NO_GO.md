# Inventory Sync Final Go / No-Go (Phase 2B-7, updated after manual round; Conflict UI severity elevated in Phase 2B-7B; blocker fixed in code in Phase 2B-8; physical-device-validated in Phase 2B-8C)

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

## Conclusion: **Dogfood Go / Production No-Go**

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

## Why this isn't a full Production Go

Two checklist items remain unverified on-screen — one is now a specifically
diagnosed architectural finding, the other remains genuinely untested:

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
| 真机全流程通过 (full physical-device flow, including UI taps) | ⚠️ **Nearly met** — every human-tap step passed except Conflict UI (confirmed architecturally unreachable via the shipped preview) and Rollback (two attempts both stopped on ambiguous state, per the stop-on-uncertainty rule) |
| 断网恢复通过 (offline recovery) | ✅ **met** — Airplane Mode on/off, offline create, reconnect + sync, all tapped through for real and passed |
| Wi-Fi/cellular 切换通过 | ✅ **met** — tapped through for real, passed |
| 前后台/锁屏恢复通过 | ✅ **met** — backgrounding mid-sync, lock/unlock, all tapped through for real, passed |
| App kill 恢复通过 | ✅ met — a real force-quit with a pending item, relaunch, and sync, tapped through for real and passed (in addition to the earlier `devicectl`-level kill and the simulated in-flight-mutation test) |
| account isolation 通过 | ✅ **met** — User A/B switch tapped through for real: User B correctly showed unmerged state, no leak of User A's synced status; User A's state correctly recovered after re-login |
| conflict UI 通过 | ✅ **met (Phase 2B-8C)** — fixed in code (Phase 2B-8), hosted-validated, and now confirmed for real on a physical device: remote count, conflict reachability, correct local/household values, all four choices, and no internal-ID leakage. A second dead-end bug (found during this same physical-device round) is also fixed. See `docs/INVENTORY_SYNC_PHYSICAL_DEVICE_RESULTS.md`'s "Phase 2B-8C" section |
| rollback 通过 | ❌ **UNSAFE TO ROLLBACK** — not merely untested; this session's `createdEntityIds` cannot be proven from available read-only evidence, so rollback scope cannot be safely confirmed |
| diagnostics 脱敏 | ✅ **met** — the operator opened the real diagnostics screen and reviewed the actual export JSON directly: confirmed only counts/statuses/timestamps, no email/password/token/full UUID/household ID/mutation ID/item name |
| consistency checker clean | ✅ met — reported clean during the automated round; not independently re-checked via a fresh on-screen tap this round beyond opening the diagnostics screen |
| hosted dogfood 通过 | ✅ met (unchanged from the automated round) |
| archive safety 通过 | ✅ met (Phase 2B-6, unchanged) |
| production config audit 通过 | ✅ met (Phase 2B-6, unchanged) |
| 0 release blocker | ✅ **met (Phase 2B-8C)** — the Conflict UI release blocker is now fixed in code and confirmed on real hardware (see above). The inventory-delete crash found in an earlier round, and the post-conflict dead-end bug found in Phase 2B-8C, were both fixed, regression-tested, and re-verified. Formal Rollback validation remains the only still-open item (see below). |
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

## What would change this to Production Go

1. **Conflict UI** — this one now requires a product/architecture decision,
   not just another test attempt: either wire a real pre-merge remote read
   into the production preview call site (`GuestMergeViews.swift`'s call to
   `preparePreview`), or make a deliberate, documented decision that Guest
   merge in production is intentionally optimistic (no pre-check) and that
   conflicts are meant to be caught some other way (e.g., a later
   sync-time version check) — then verify that path instead. Simply
   "trying again" won't reach the conflict screen, since the gap is
   structural, not incidental. See `docs/INVENTORY_MERGE_REMOTE_PREVIEW_FIX_DESIGN.md`
   for the full proposed design and required test plan (design only —
   not implemented).
2. **Rollback** — needs a clean, unambiguous merge session (ideally on a
   fresh test account with no leftover data from earlier phases) taken all
   the way through confirm with a verified, predictable outcome, then
   rollback exercised immediately after.

## What would change this to No-Go

Any of: the conflict UI or rollback flow, once actually exercised, crashing
or behaving destructively; a new crash discovered anywhere else; data
loss; duplicate creation; cross-account leakage; a secret appearing
on-screen or in a log; or the diagnostics/consistency checker showing
anything other than clean during a real human-driven run.

## Status wording to use anywhere this is referenced

**"Dogfood Go / Production No-Go — the Conflict-UI release blocker (preview
was structurally zero-network, and the server has no business-key
deduplication, so a silent duplicate was possible) is now fixed in code,
simulator-validated, hosted-development-validated, and
physical-device-validated for real (Phase 2B-8/2B-8C) — see
`docs/INVENTORY_MERGE_REMOTE_PREVIEW_PHASE2B8_VALIDATION.md` and
`docs/INVENTORY_SYNC_PHYSICAL_DEVICE_RESULTS.md`'s Phase 2B-8C section. A
second dead-end bug (post-conflict resolution) was found and fixed during
that physical-device round. Formal, deliberate Rollback validation is the
only item still open before Production Go — an unplanned, single,
out-of-protocol Rollback was incidentally exercised during Phase 2B-8C with
an apparently clean outcome, but this does not substitute for that formal
test. Rollback remains unsafe to attempt on the older, separate
pre-2B-8 session referenced elsewhere in this document. One real crash bug
(inventory-delete) was found, fixed, and re-verified on-device in an
earlier round."** Never shorten this to "physical device fully validated"
or "production ready," and never cite the retracted "2 real personal items
uploaded" claim — see the correction in
`docs/INVENTORY_SYNC_PHYSICAL_DEVICE_RESULTS.md`.
