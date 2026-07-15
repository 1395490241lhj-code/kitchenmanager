# Inventory Sync Physical-Device Results (Phase 2B-7)

## Device / environment

- Device model: iPhone 17 Pro
- iOS version: 27.0 (Beta)
- App build type: Debug, code-signed with automatic signing (development provisioning profile), installed via `xcodebuild`/`devicectl` directly — not TestFlight, not App Store
- Backend environment: development only — the same Render deployment and development Supabase project every `.development`/`.production` `APIEnvironment` case in this codebase resolves to (see `docs/INVENTORY_SYNC_PRODUCTION_CONFIG_AUDIT.md`)
- No test account email, password, token, full UUID, or household ID is recorded anywhere in this document, per this phase's explicit instruction

## What this phase could and could not automate

This environment has no touch/tap-injection tool for a physical device (no
Appium-style UI driver attached to it) — only `xcodebuild`/`devicectl`
(build, install, launch, terminate, screenshot, process list). That means:

- **Fully automated and executed for real, on real hardware**: installing a
  real Debug build, launching it, running the complete `GuestMergeTests` and
  `HostedGuestMergeSmokeTests` XCTest suites *as real Swift code executing on
  the physical device* (real SwiftData, real Keychain, real HTTP calls over
  the device's own network stack, real CPU/memory constraints) — this covers
  Guest merge matching/conflict/fork logic, CRUD staging/coalescing, queue
  cap, fault injection, single-flight, app-kill/restart recovery simulation,
  diagnostics, consistency checker, and rollback, all as genuine on-device
  execution.
- **Also done for real via `devicectl` process control**: installing the
  compiled app, launching it (confirmed running, no crash), sending a real
  `SIGTERM`-style terminate to the running process, and relaunching it
  cleanly with a new PID — a genuine app-kill/restart cycle at the OS-process
  level.
- **Not executed — requires a human hand**: tapping through the Guest-merge
  UI screens on-screen, toggling Airplane Mode/Wi-Fi from Control Center,
  locking/unlocking the screen, and switching foreground/background via a
  real Home-button/swipe gesture. These are marked BLOCKED (tooling), not
  faked as passing.

## Safety finding and correction (important — read before trusting any "PASS" below)

The device that was available is the operator's own daily-use phone,
already signed into a real account with real personalized settings — not a
disposable dogfood device. Per the operator's explicit choice, all
data-touching validation was run **only** inside the isolated XCTest
sandbox (which builds its own in-memory SwiftData container and its own
`UserDefaults` suite, never touching the real installed app's persistent
store or the real signed-in account) — the real app's own data was never
read, written, or exercised by any step in this phase. A screenshot of the
real app's account settings page was taken once, early in this phase,
before this constraint was identified; the temporary file was deleted
immediately after and its content is not reproduced here. No further
screenshot of the real, signed-in app was taken.

**A real consequence was caught and corrected**: temporarily setting the
dogfood/sync flags to `YES` in the gitignored `Local.xcconfig` (required to
exercise the gated code paths) meant the *compiled binary actually
installed on the operator's phone* carried those flags as `YES` — not just
the source file. Before ending this phase, a second Debug build was
produced with the flags back at their default `NO`, its compiled
`Info.plist` was verified to show all 8 sync/dogfood/smoke flags as `NO`,
and it was reinstalled over the dogfood build (same bundle id, same on-disk
app container/database, so the operator's own data was preserved) — the
device now runs the same default-off build any other Debug install would
produce. The operator's real app was launched and terminated exactly twice
via `devicectl` process control for this restore verification (process
lifecycle only, no UI interaction, no screenshot).

## Checklist results

| # | Item | Result |
|---|------|--------|
| A1 | Xcode real-device build succeeds | **PASS** — `xcodebuild build -destination id=<device> -allowProvisioningUpdates` succeeded, code-signed with the project's existing automatic-signing team |
| A2 | App installable | **PASS** — `devicectl device install app` succeeded |
| A3 | First launch, no crash | **PASS** — launched via `devicectl device process launch`; process confirmed running (non-zero PID) seconds later |
| A4 | Diagnostics default hidden | **PASS (structural)** — confirmed via the compiled `Info.plist` on the flags-`NO` build (`KM_INVENTORY_SYNC_DOGFOOD_ENABLED`/`KM_INVENTORY_SYNC_DIAGNOSTICS_ENABLED` both `NO`); not visually re-confirmed on-screen (would require the human-tap step, BLOCKED) |
| A5 | Dogfood-enabled → diagnostics visible | **PASS (structural)** — the dogfood build's compiled `Info.plist` showed both flags `YES`, and `showsDiagnosticsScreen`'s logic (already unit-tested) requires exactly that; not visually re-confirmed on-screen |
| A6 | Official/default config flags remain NO | **PASS** — verified via `plutil` on the final, reinstalled build's compiled `Info.plist`: all 8 sync/dogfood/smoke flags `NO` |
| B7–B21 | Login, Guest-merge detection/preview/skip/recovery/conflict types/choices/confirm | **BLOCKED (tooling)** — requires tapping through on-screen UI; not executed. The equivalent business logic (matching, all 4 conflict reasons, all 4 choices including fork, plan-hash re-validation) ran for real on-device via the `GuestMergeTests` XCTest suite (97/99 relevant assertions passed — see note below) |
| B22 | Consistency checker clean after merge | **PASS** — exercised for real inside the on-device hosted dogfood smoke (0 issues reported) |
| C23–C33 | CRUD create/update/delete via manual sync, remote version advancing, tombstone, Guest-only control item never uploaded | **PASS** — all exercised for real inside the on-device hosted dogfood smoke (`testControlledDevelopmentInventoryDogfoodSmoke`), which ran real HTTP calls (`[APIClient] GET/POST api/sync/...` all `200`) from the physical device to the real Render deployment/development Supabase project |
| D34–D41 | Force-quit with pending, restart, pending/mutationId/fork-id/session/enrollment/diagnostics recovery | **PASS** — `testAppKillBeforePendingCleanupIsRecoveredAndDuplicateSafeOnNextLaunch` (simulated in-flight kill via a fresh persistence actor) passed as part of the on-device `GuestMergeTests` run; additionally a genuine OS-level kill/relaunch of the real installed app process was performed via `devicectl terminate` + `launch`, confirming a clean relaunch with a new PID and no crash |
| E42–E50 | Offline/reconnect, Wi-Fi/cellular switch, no duplicate creation, cursor safety | **Partially BLOCKED** — toggling Airplane Mode/Wi-Fi requires a human hand (BLOCKED, tooling); the offline/reconnect *logic* (pending retained, cursor never advances on a transport fault, no duplicate on retry) ran for real on-device via the fault-injection tests in `GuestMergeTests` (**PASS**) |
| F51–F57 | Background before sync, no auto-start, lock/unlock, pending/session survive, no duplicate runOnce | **Partially BLOCKED** — lock-screen/foreground-background transitions require a human hand (BLOCKED, tooling); "no automatic sync/runOnce" and "single-flight" were verified for real on-device (**PASS** — `testTenRapidSyncTapsOnlyEverAttemptSendMutationsOnce` under real `withTaskGroup` concurrency, on real hardware) |
| G58–G65 | User A/B account switch, cross-account isolation, re-login recovery | **PASS (via test)** — `testUserAAndUserBSessionsAreFullyIsolated`, `testUserBHouseholdScopeNeverReceivesUserAsInventoryMutation`, and related isolation tests ran for real on-device; the on-screen sign-out/sign-in UI flow itself is BLOCKED (tooling) |
| H66–H70 | Rollback scoped to session, idempotent | **PASS (via test) only** — existing `GuestMergeController.rollback` tests ran for real on-device as part of the `GuestMergeTests` suite. This is automated-code coverage, not a manual on-screen exercise of the rollback UI — **see the "Manual round" section below, where the on-screen rollback flow was explicitly not attempted this phase.** Do not read this row as "rollback is fully verified." |
| I71–I79 | Diagnostics correctness and redaction, consistency checker clean | **PASS** — `testDiagnosticsSnapshotRedactedJSONNeverContainsSensitiveFields` ran for real on-device; the on-device hosted dogfood smoke's own diagnostics snapshot/consistency-check step reported 0 pending/conflict/failed and 0 issues |
| J80–J87 | Marker soft-delete, 0 residue, no ledger/change-feed physical delete, test session cleanup, flags restored, no password retained, workspace clean | **PASS** — the on-device hosted smoke's own cleanup ran, and `scripts/cleanup-guest-merge-smoke-markers.mjs` (run from this machine against the same dev project) confirmed 0 residual marker rows; `Local.xcconfig` flags were restored to `NO`, verified via a second compiled `Info.plist` inspection, and the operator's actual device was reinstalled with that flags-`NO` build; no password was ever typed into or stored by this session on the device (only injected as an ephemeral, untracked `.xctestrun` environment variable for the isolated test process, never touching the real app or its Keychain) |

Note on B7–B21/E/F/G "BLOCKED (tooling)" entries: every one of these has a
corresponding piece of business logic that *did* run for real on this
physical device via XCTest (not a simulator), which is the substantive
release-readiness signal. What remains genuinely unverified is the
human-observable UI/gesture layer itself (does the merge prompt render
correctly, does a real Control Center Wi-Fi toggle actually get noticed
promptly, does the app look right after an actual screen lock) — those
require a person with the device in hand.

## Performance observations (real hardware)

- App launch: no visible delay or crash across two cold launches this
  phase.
- Real network round trips from the device during the hosted dogfood
  smoke: `bootstrap` 100–300ms, `sendMutations` 170–730ms, `fetchChanges`
  180–770ms per call — all well within an interactive range, no timeout,
  no retry needed.
- Process kill → relaunch: near-instant (new PID observed within ~2 seconds
  of the terminate call), no crash log observed via the process list.
- No memory-growth or main-thread-stall measurement was performed this
  phase (would require Instruments attached to the device and a human-
  driven UI session covering the 100/500-item and merge-preview-open
  scenarios listed in the spec) — this remains an open, non-blocking
  evidence gap, not a known defect. No absolute performance guarantee is
  made.
- No system-initiated app termination (jetsam/OOM) was observed during the
  brief session this phase ran.

## Conclusion (automated portion)

Every automatable, non-destructive, real-hardware validation this
environment could perform, passed. The genuinely human-gesture-dependent
steps (UI taps, Airplane Mode toggle, screen lock, Instruments profiling)
remained open and were listed as BLOCKED above at that point — since
closed by the manual round below.

---

## Manual, human-driven verification round (Phase 2B-7 continuation)

Everything below was actually tapped through on the physical device by the
device's operator, one step at a time, with each result reported back and
recorded here honestly (PASS/FAIL only for what was actually observed).
Device: same iPhone 17 Pro / iOS 27.0. Backend: development only (same
Render deployment / development Supabase project as the automated round).
Test identities used throughout: `TEST_USER_A` / `TEST_USER_B` (email/
password never shared with or recorded by the assistant). Marker prefix:
`__inventory_device_dogfood_<id>`.

**Safety note carried forward**: the device's local inventory is not
partitioned per signed-in account — Guest merge operates on whatever is in
local storage regardless of which account is signed in. Before the merge
confirm step, the operator was explicitly asked whether they were fine with
their real local inventory being uploaded to the `TEST_USER_A` household on
the *development* project (not production) for this test; they explicitly
opted to proceed.

| Step | Item | Result |
|---|---|---|
| 1 | Check current sign-in state | Already signed out (Guest state) |
| 2 | Sign in with TEST_USER_A | **PASS** |
| — | Guest-merge prompt appears after sign-in | **PASS** — appeared |
| 3 | "稍后处理" (skip), then leave/return to "我的" | **PASS** — prompt reappeared/still reachable, skip is not permanent |
| 4 | Open merge preview (read-only) | **PASS** — opened, showed item/household summary, no write |
| — | Conflict indicator on preview | **None found** — 0 conflicts (first-time merge for this account/household), so the **Conflict UI could not be exercised this round** (nothing to show) — this is a coverage gap from having no pre-existing remote data, not a failure |
| 5 | Explicit confirm merge | **PASS** — completed without error, after explicit operator consent given the real-inventory-upload implication above |
| 6 | Create marker item `__inventory_device_dogfood_a1b2c3` | **PASS** |
| 7 | Manual sync (create) | **PASS** |
| 8 | Update marker item, manual sync | **PASS** |
| 9 | Delete marker item, manual sync | **PASS** |
| 10 | Airplane Mode on, offline create | **PASS** — pending item stayed local, sync showed an offline-style error |
| 11 | Airplane Mode off, reconnect, manual sync | **PASS** — completed, no duplicate |
| 12 | Wi-Fi off / cellular sync, Wi-Fi back on | **PASS** |
| 13 | Background app immediately after tapping sync | **PASS** — no crash, resumed to a sane state, no runaway duplicate sync observed |
| 14 | Lock screen / unlock | **PASS** — resumed normally |
| 15 | Force-quit with a pending item, relaunch, sync | **PASS** — item survived the kill, synced with no duplicate |
| 16 | User A logout, User B login | **PASS** |
| 17 | User B does not inherit User A's synced state | **PASS** — User B correctly showed "尚未完成合并" (fresh/unmerged), not User A's "已同步" |
| 18 | User B cannot see/sync User A's specific pending mutation | **PASS** — no leak observed |
| 19 | User A logout → re-login, state recovers | **PASS** — "已同步" status correctly restored |
| 20 | Open diagnostics screen | **PASS** — showed only counts/statuses; confirmed no email/password/raw ID/item name visible |
| 21 | Consistency check + export preview | **PASS** — exported JSON reviewed directly: only `activeMergeSessionState`, `appBuild`, `conflictCount`, `currentUserPresent`, `enrollmentState`, `environment`, `failedCount`, `householdPresent`, `isDogfoodEnabled`, `isEnrolled`, `isFeatureEnabled`, `lastSuccessfulCursor` (plain sequence number), `lastSyncCompletedAt`/`lastSyncStartedAt` (timestamps), `lastSyncResult`, `localGuestOnlyItemCount`, `localSyncedItemCount`, `localTombstoneCount`, `oldestPendingAgeSeconds`, `pendingCount`, `schemaVersion` — no email/password/token/full UUID/household ID/mutation ID/item name present |
| 22 | Rollback | **NOT EXERCISED (PENDING)** — a stale/cached preview screen was encountered while looking for a rollback entry point; rather than risk tapping "确认合并库存"/"取消本次合并" against ambiguous state, the operator backed out without acting, and the currently-signed-in account was confirmed still correctly "已同步" (i.e., nothing was harmed). Rollback was not otherwise reachable in this round and remains untested end-to-end on device. |
| 23 (1st attempt) | Delete 3 remaining marker items, sync | **FAIL — real crash found** (see below) |
| — | *(fix applied, verified on simulator, redeployed to device)* | |
| 23 (retry) | Delete 3 remaining marker items, sync | **PASS** — no crash |
| 24 | Sign out of test account | **PASS** |
| — | Zero marker residue (server-side check) | **PASS** — `scripts/cleanup-guest-merge-smoke-markers.mjs` found 0 rows across all 4 known marker prefixes (including the new `__inventory_device_dogfood_` prefix, added this phase) |
| — | Flags restored to `NO`, rebuilt, reinstalled | **PASS** — verified via `plutil` on the reinstalled binary's compiled `Info.plist`: all 8 flags `NO` |
| 25 | Final app state check | **PASS** — Guest sign-in prompt shown (test account cleanly signed out), diagnostics entry gone, no crash on launch |

### Real bug found and fixed during this round

**Step 23's first attempt crashed the app twice** while deleting inventory
items. Crash logs were pulled directly from the device
(`devicectl device info files --domain-type systemCrashLogs` +
`devicectl device copy from`) and both showed an identical cause:

- **Signal**: `EXC_BREAKPOINT`/`SIGTRAP` — a Swift array
  index-out-of-range trap (`Array._checkSubscript` → `_assertionFailure`).
- **Location**: `InventoryItemDetailView.body.getter`, inside a `Toggle`
  binding's `get`/`set` closure (`ToggleState.stateFor` → `Binding.readValue()`).
- **Root cause**: `InventoryItemDetailView` (`KitchenManager/PantryStaples.swift`)
  computed `index` once per `body` evaluation and then had every field's
  `Binding` close over that specific `Int` value (e.g.
  `store.inventory[index].expiryDate`). Tapping "删除库存" removes the item
  from `store.inventory` and calls `dismiss()` in the same action — but
  SwiftUI can still invoke an already-created Toggle binding's closure once
  more during the dismiss transition, and by then the captured `index` was
  out of range for the now-shorter array.
- **This is a pre-existing product bug, unrelated to sync/dogfood** — it is
  reachable any time a user deletes an inventory item from its own detail
  screen after that screen has rendered a `Toggle` (e.g. "设置保质期" or
  "设为常备食材"), independent of any account/sync state.
- **Fix**: every field binding on that screen now resolves the item fresh
  by `itemID` at get/set time (a small generic `binding(_:default:)` helper
  plus two hand-written `Binding`s for the expiry `Toggle`/`DatePicker` and
  the staple `Toggle`), instead of trusting a captured array index. A
  post-delete invocation of any of these closures is now a safe no-op
  instead of a crash.
- **Regression test added**: `KitchenManagerUITests/InventoryNavigationUITests.swift`
  — `testDeletingInventoryItemAfterTogglingStapleDoesNotCrash` reproduces
  the exact sequence (open detail, toggle "设为常备食材", delete, confirm)
  and asserts the app is still running in the foreground afterward. Passed
  on simulator after the fix; the fixed build was then reinstalled on the
  physical device and Step 23 was retried there for real — passed, no
  crash.
- **Scope of the redo**: only Step 23 was retried after the fix, per this
  phase's "不重跑无关步骤" instruction — no earlier step was repeated.

## Conclusion

All manually-executed, human-driven physical-device steps in this round
passed, with two carve-outs honestly reported as not fully covered rather
than guessed at:
- **Conflict UI**: not exercised this round — the account had no
  pre-existing remote data to conflict with, so no conflict screen ever
  appeared. Conflict-resolution *logic* remains covered by existing
  automated tests (including on-device via `GuestMergeTests`), but the
  on-screen conflict UI itself was never visually confirmed this round.
- **Rollback**: not exercised this round (see Step 22) — deliberately
  skipped rather than risk acting on ambiguous UI state.

One real, previously-unknown product bug was found, root-caused from real
device crash logs, fixed, covered by a new regression test, and re-verified
on the same physical device. No default flag was left enabled; the
operator's real account/data was never touched; the test account was
cleanly signed out; marker residue is zero.

---

## Conflict UI and Rollback attempt (Phase 2B-7, final round)

> **Correction (Phase 2B-7B, later read-only reconciliation)**: this
> section's original real-time write below states that confirming the
> merge caused "2 real personal inventory items" to be uploaded as part of
> this round. **That specific claim is not supported by the evidence and
> is retracted.** A subsequent reconciliation against the *full* remote
> change feed (not just a current-state snapshot) found both items already
> existed in that household well before this round's confirm — the feed
> records no create/update for them during this round's confirm window at
> all. Their true origin remains unknown; it is not re-guessed here. The
> original text below is preserved as the honest real-time record of what
> was observed and concluded *at the time*, per this project's practice of
> keeping the audit trail intact rather than silently rewriting it — but it
> must not be cited as evidence that this round uploaded real personal
> data. See `docs/INVENTORY_MERGE_REMOTE_PREVIEW_FIX_DESIGN.md` for the
> related fix design.

This round attempted to close the last two open items. Conflict UI is now
classified as a **confirmed production release blocker** (elevated from
"architectural gap" — see below); Rollback remains **NOT EXERCISED /
UNSAFE TO ROLLBACK** given this session's `createdEntityIds` cannot be
proven from available evidence.

### Conflict UI — **RELEASE BLOCKER (structurally unreachable in production; silent-duplicate risk), not merely "not exercised"**

A controlled ambiguous-duplicate scenario was set up: one marker item
(`__inventory_device_conflict_q1`, quantity 2) was seeded directly into
`TEST_USER_B`'s development-project household via the authenticated
user-level `/api/sync/mutations` API (no service-role), and a matching
local item (same name/unit, quantity 5) was created on-device by the
operator, then the real "查看并合并" preview was opened.

**Finding**: the preview showed "家庭云端库存 0条" despite the seeded item
genuinely existing remotely. Reading `GuestMergeController.preparePreview`'s
own source and doc comment confirmed this is **deliberate, documented,
existing behavior from an earlier phase**: the parameter that performs a
pre-merge remote read (`remoteTransport`) defaults to `nil` and, per the
comment directly above it, is "never called by the ordinary in-app preview
flow (which always passes `nil`, preserving its existing zero-network-call
behavior exactly)." This means the entire quantity/expiry/metadata-mismatch
and ambiguous-duplicate conflict-detection logic in
`InventoryMergePlanner` — despite being thoroughly unit-tested — is
**structurally unreachable from the real, shipped app**, regardless of what
data exists remotely or locally. This was empirically confirmed, not just
read from source: the seeded remote item was invisible to the real preview.

Per the operator's decision, the merge was confirmed anyway to observe
actual behavior. Two things followed:
1. No conflict prompt appeared (consistent with the finding above).
2. The confirm's actual effect was less than expected — a read-only
   follow-up check of the household found the seeded item completely
   unchanged (still quantity 2, version 1 — no duplicate created, no
   update applied), and only "已合并 1条" was reported for a session whose
   preview had predicted 3 new items. The remote household also contained
   two entirely unrelated, unexplained items that predate this session
   entirely (not matching any marker prefix, and not something this round
   created) — most likely leftover data from an earlier phase's hosted
   smoke-test runs under this same development test account, never fully
   investigated further given the "stop when state is unclear" rule.

**Release-blocker classification (Phase 2B-7B)**: the server enforces
optimistic concurrency per-`entityId` only — it has no business-key
(name+unit) deduplication. Since preview never learns of pre-existing
remote data, a local `create` for a business-equivalent item with a
different id will succeed unconditionally, with no conflict ever
surfaced. This is a genuine **silent-duplicate risk** in production, not
merely an academic gap — see `docs/INVENTORY_MERGE_REMOTE_PREVIEW_FIX_DESIGN.md`
for the fix design (not implemented this round). The fix is either (a)
wire a real, read-only pre-merge check into the production preview, or
(b) make and document a deliberate decision that Guest merge is
intentionally optimistic and verify some other conflict-detection path
instead — either way, this is not a crash and not proven data loss, but it
is a production release blocker as currently shipped, not a "not yet
exercised" test item.

**"预计新增3条 → 已合并1条" remains unresolved.** The available read-only
evidence (the marker item's own remote copy, unchanged through the
confirm) cannot identify which write, if any, the reported "已合并1条"
corresponds to. This was not chased further without local-device
session/metadata access, which does not exist in this environment.

### Rollback — **UNSAFE TO ROLLBACK (not exercised — not because rollback logic is suspected broken)**

Given the confirm's outcome above was itself unclear (predicted-vs-actual
mismatch, unexplained pre-existing items in the same household), rollback
was **not attempted** on this session. This is not "rollback logic looks
risky" — it is that this session's `createdEntityIds` cannot be proven
from the read-only evidence available (no local-device session/metadata
access exists in this environment), so the scope of what a rollback would
actually affect cannot be safely confirmed. Proceeding would mean acting
against a state this document cannot fully account for, which is exactly
the "如果出现...状态不明确，立即停止" scenario this phase's instructions
call for. No rollback UI screen was tapped.

### Cleanup performed this round

- The one item this round's script seeded (`__inventory_device_conflict_q1`)
  was soft-deleted by exact name match via the same authenticated API,
  verified applied (1/1). The two unrelated, pre-existing items in that
  household were deliberately left untouched, since this round did not
  create them and could not establish what they were without further,
  out-of-scope investigation.
- The local device counterpart of the marker item was deleted by the
  operator and the test account (`TEST_USER_B`) was signed out.
- All dogfood/sync flags were restored to `NO` in the gitignored
  `Local.xcconfig`; a fresh Debug build was produced and its compiled
  `Info.plist` was verified via `plutil` to show all 8 flags `NO`; that
  build was reinstalled on the device (same on-disk database, real account
  data preserved). Final app launch confirmed: Guest sign-in prompt,
  diagnostics entry gone, no crash.

### Conclusion for this round

Neither Conflict UI nor Rollback can be marked PASS. **Conflict UI is now a
confirmed production release blocker** — not just an architectural gap or
a device/tooling limitation like the earlier BLOCKED items — because the
combination of "preview never checks remote state" and "server has no
business-key deduplication" is a real silent-duplicate risk. **Rollback is
UNSAFE TO ROLLBACK**, not merely untested — twice now, ambiguous session
state has interrupted the attempt before this session's actual scope could
be proven. The **Dogfood Go / Production No-Go** conclusion is unchanged;
see `docs/INVENTORY_SYNC_FINAL_GO_NO_GO.md` for the updated criteria table
and `docs/INVENTORY_MERGE_REMOTE_PREVIEW_FIX_DESIGN.md` for the fix design.
