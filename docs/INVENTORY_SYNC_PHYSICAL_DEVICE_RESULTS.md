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
| H66–H70 | Rollback scoped to session, idempotent | **PASS (via test)** — existing `GuestMergeController.rollback` tests ran for real on-device as part of the `GuestMergeTests` suite |
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

## Conclusion

Every automatable, non-destructive, real-hardware validation this
environment could perform, passed. The genuinely human-gesture-dependent
steps (UI taps, Airplane Mode toggle, screen lock, Instruments profiling)
remain open and are listed as BLOCKED above, not claimed as passed.
