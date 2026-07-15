# Inventory Sync Final Go / No-Go (Phase 2B-7, updated after manual round)

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

Two checklist items remain genuinely unverified on-screen:

1. **Conflict UI** — the test account had no pre-existing remote data, so
   preview always showed 0 conflicts; the on-screen conflict-resolution
   screen was never actually rendered or tapped through this round. The
   underlying conflict *logic* (all 4 conflict reasons/choices, including
   same-id fork) is covered extensively by automated tests — including
   running for real on this same physical device — but the visual UI layer
   itself is unconfirmed.
2. **Rollback** — a stale/cached preview screen was encountered while
   looking for a rollback entry point; the operator correctly backed out
   without tapping either "确认合并库存" or "取消本次合并" rather than risk
   acting on ambiguous state. Rollback logic is covered by automated tests
   (including on-device), but the on-screen rollback flow was not
   exercised.

Everything else in the human-facing checklist — including the step that
initially crashed — was tapped through for real and passed.

## Full criteria table

| Criterion | Status |
|---|---|
| 真机全流程通过 (full physical-device flow, including UI taps) | ⚠️ **Nearly met** — every human-tap step passed except Conflict UI (no conflict occurred to show it) and Rollback (deliberately not attempted this round) |
| 断网恢复通过 (offline recovery) | ✅ **met** — Airplane Mode on/off, offline create, reconnect + sync, all tapped through for real and passed |
| Wi-Fi/cellular 切换通过 | ✅ **met** — tapped through for real, passed |
| 前后台/锁屏恢复通过 | ✅ **met** — backgrounding mid-sync, lock/unlock, all tapped through for real, passed |
| App kill 恢复通过 | ✅ met — a real force-quit with a pending item, relaunch, and sync, tapped through for real and passed (in addition to the earlier `devicectl`-level kill and the simulated in-flight-mutation test) |
| account isolation 通过 | ✅ **met** — User A/B switch tapped through for real: User B correctly showed unmerged state, no leak of User A's synced status; User A's state correctly recovered after re-login |
| conflict UI 通过 | ❌ **not exercised** — no conflict occurred to display; not a failure, an untested gap |
| rollback 通过 | ❌ **not exercised** — deliberately skipped this round rather than act on ambiguous state |
| diagnostics 脱敏 | ✅ **met** — the operator opened the real diagnostics screen and reviewed the actual export JSON directly: confirmed only counts/statuses/timestamps, no email/password/token/full UUID/household ID/mutation ID/item name |
| consistency checker clean | ✅ met — reported clean during the automated round; not independently re-checked via a fresh on-screen tap this round beyond opening the diagnostics screen |
| hosted dogfood 通过 | ✅ met (unchanged from the automated round) |
| archive safety 通过 | ✅ met (Phase 2B-6, unchanged) |
| production config audit 通过 | ✅ met (Phase 2B-6, unchanged) |
| 0 release blocker | ✅ met — the one real bug found (inventory-delete crash) was fixed, regression-tested, and re-verified on-device before this phase closed |
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

Exercise the two remaining items for real: (a) trigger a genuine conflict
(e.g. edit the same marker item from two signed-in sessions before
syncing) and tap through the actual conflict-resolution screen, and (b)
exercise rollback from a clean, unambiguous state right after a merge
completes. Neither is expected to behave differently from the
already-passing logic underneath — but that expectation isn't a
substitute for observing it.

## What would change this to No-Go

Any of: the conflict UI or rollback flow, once actually exercised, crashing
or behaving destructively; a new crash discovered anywhere else; data
loss; duplicate creation; cross-account leakage; a secret appearing
on-screen or in a log; or the diagnostics/consistency checker showing
anything other than clean during a real human-driven run.

## Status wording to use anywhere this is referenced

**"Dogfood Go / Production No-Go — the full human-driven physical-device
checklist passed except Conflict UI and Rollback, which were not
exercised (not failed); one real crash bug was found, fixed, and
re-verified on-device during this round."** Never shorten this to
"physical device fully validated" or "production ready."
