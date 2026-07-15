# Inventory Sync Phase 2B-6 Validation

> **Phase 2B-7 update**: the "physical-device dogfood — pending" section
> below has since been partially closed — a real iPhone 17 Pro ran the
> automated/business-logic and hosted-dogfood portions of physical-device
> validation for real. See `docs/INVENTORY_SYNC_PHYSICAL_DEVICE_RESULTS.md`
> and `docs/INVENTORY_SYNC_FINAL_GO_NO_GO.md` for the current status
> (still Dogfood Go / Production No-Go, narrowed to the human-gesture UI
> layer only).

## Scope

Phase 2B-6 closes as many of Phase 2B-5's evidence gaps as this environment
allows: fault injection, single-flight/lifecycle drills, scale/performance
sanity checks, a queue-cap stress test, a real hosted development dogfood
run, and a read-only production config + archive audit. It adds no new
product feature, changes no default flag, and does not enable production.

## Readiness gap audit (before implementation)

| Gap (from Phase 2B-5) | Automatable? | Result this phase |
|---|---|---|
| Weak-network/error-injection tests | Yes | Built `InventorySyncFaultInjectingTransport` (test-only) + 11 fault-injection tests |
| App-kill/restart recovery drill | Yes (simulated) | `testAppKillBeforePendingCleanupIsRecoveredAndDuplicateSafeOnNextLaunch` |
| Single-flight under real concurrency | Yes | `testTenRapidSyncTapsOnlyEverAttemptSendMutationsOnce` (real `withTaskGroup` concurrency, not sequential calls) |
| Performance/scale at 500–1000 rows | Yes (local/mock only) | 4 new tests; see `docs/INVENTORY_SYNC_SCALE_RESULTS.md` |
| Queue-cap pressure at scale | Yes | `testQueueCapAt200HoldsFirmAgainst250AttemptedCreatesAndDeletesAreNeverDropped` |
| Hosted development dogfood | Yes (real backend reachable) | Ran for real — **PASS** (see below) |
| Production config audit | Yes (read-only) | Done — see `docs/INVENTORY_SYNC_PRODUCTION_CONFIG_AUDIT.md` |
| Archive/Release safety | Yes (unsigned archive buildable) | Done — see below |
| **Physical-device dogfood** | **No — no physical device attached to this environment** | Not executed; checklist prepared — see `docs/INVENTORY_SYNC_PHYSICAL_DEVICE_CHECKLIST.md` |

No known product defect was found during this audit. Everything fixed this
phase was test/evidence infrastructure (fault injection transport, new
tests) — no change to `InventorySyncEligibility`'s production logic beyond
what Phase 2B-5 already added, no change to `SyncCoordinator`, no change to
`InventorySyncConsistencyChecker`'s production logic.

**Triage**: nothing this phase rose to Blocker or High against the
*existing* implementation — every finding was an evidence gap (tests/audits
not yet run), which is exactly what this phase was scoped to close except
for the one item structurally impossible here (physical device).

## Fault injection results

See `docs/INVENTORY_SYNC_FAULT_INJECTION.md` for architecture and the full
scenario table. Summary: offline, 401, 403, 413, 429 (mapped to
`.backendUnavailable`), 500/503, malformed/truncated JSON, push-applied
then client-timeout, pull-succeeded then local-save-failure, and
app-killed-before-cleanup were all exercised. In every case: pending
mutations were never lost, the cursor never advanced on a decode/persistence
failure, no duplicate mutation record was ever created on retry, and no raw
response body or credential was logged by the fault-handling path (it
doesn't touch logging at all — errors flow through the existing
`SyncError`/`userFacingSyncError` mapping).

## Duplicate-safe recovery

Confirmed by test: after a "push applied then client timeout" fault, the
inner fake shows the mutation really was applied server-side
(`appliedCount() == 1`) while the client still sees `.failed(.transport)`
and keeps the *same* `mutationId`; retrying (fault cleared) resolves that
same mutation and leaves no second pending row for the entity.

## App-kill / restart recovery

Confirmed by test: a mutation marked `.inFlight` (simulating a kill mid-push,
before any result was ever recorded) is still returned by
`pendingMutations(scope:maxAttempts:)` from a brand-new `SwiftDataSyncPersistence`
actor over the same container (simulating relaunch), and a fresh manual
sync resolves it without creating a duplicate.

## Single-flight

Confirmed under real concurrency (`withTaskGroup`, 10 concurrent `syncNow`
calls): exactly one `sendMutations` call ever happened. A scope-mismatch
attempt (household the transport doesn't recognize) resolves rather than
hanging, and does not leave the guard stuck for the next, correctly-scoped
call.

## Queue-cap pressure

250 attempted creates against a 200 cap: exactly 200 pending mutations
remain (never more). A delete for an already-staged item still fully
cancels the create (Phase 2B-4 rule), and coalescing an update into an
already-staged create still succeeds — neither is blocked by the cap being
full, confirming the cap only ever blocks a genuinely *new* mutation.

## Scale / performance

See `docs/INVENTORY_SYNC_SCALE_RESULTS.md`. No O(n²) hotspot found in the
code paths exercised (consistency checker, eligibility queue-cap check,
diagnostics snapshot assembly) — all are linear in row count. No absolute
performance guarantee is made.

## Hosted development dogfood — **PASS**

Executed for real against the actual development Supabase project and the
real Render deployment (the same backend `.development`/`.production` both
resolve to — see the production config audit). Used marker prefix
`__inventory_dogfood_<8-char-id>` throughout, never real personal inventory.
Flow: create → sync → update → sync → offline-stage (local-only edit,
no network call) → reconnect + sync → simulated restart (fresh persistence
actor/controller over the same container) → duplicate-safe no-op sync →
delete → sync → tombstone confirmed → diagnostics snapshot clean (0
pending/conflict/failed) → consistency checker clean (0 issues) → cleanup.
Ran via `HostedGuestMergeSmokeTests.testControlledDevelopmentInventoryDogfoodSmoke`
(`GuestMergeSmokeRunner.runInventoryDogfoodMinimalSmoke`), gated behind the
same `GUEST_MERGE_SMOKE_ENABLED` + `INVENTORY_SYNC_ENABLED` + development-
environment flags as every other hosted smoke in this codebase, temporarily
set to `YES` only in the gitignored `Local.xcconfig` and reverted to `NO`
immediately after the run. Credentials were supplied only via an
ephemeral, untracked `.xctestrun` environment-variable injection (never
written to any scheme file, tracked file, or log) — see the session
transcript for the exact mechanism if reproducing this. Passed on the first
attempt. Zero marker residue confirmed via `scripts/cleanup-guest-merge-smoke-markers.mjs`
(extended this phase to also sweep `__inventory_dogfood_` — 0 rows found).

## Physical-device dogfood — **pending**

Not executed; no physical device is attached to this automated environment.
See `docs/INVENTORY_SYNC_PHYSICAL_DEVICE_CHECKLIST.md` for the ready-to-run
30-step checklist. **Status wording to use everywhere: "simulator dogfood
passed, physical-device validation pending."**

## Production config audit

Read-only; see `docs/INVENTORY_SYNC_PRODUCTION_CONFIG_AUDIT.md`. No Blocker
found. Two pre-existing evidence gaps carried forward (sync-migration
parity verification, no min-app-version enforcement) — neither is new to
this phase and neither is a data-loss/security defect.

## Archive / Release safety

Built a real unsigned archive this phase (`xcodebuild archive ...
CODE_SIGNING_ALLOWED=NO`) and inspected it directly:
- Compiled `Info.plist`: all 8 sync/dogfood/smoke flags `NO`.
- Binary `strings` scan: zero occurrences of `service_role`, test email
  addresses, the test password literal, or any of the three smoke marker
  prefixes.
- No `.xcconfig` file present anywhere inside the compiled `.app` bundle.
- Diagnostics screen is compiled into both Debug and Release, but is
  entirely runtime-gated by two flags both confirmed `NO` — see
  `docs/INVENTORY_SYNC_PRODUCTION_CONFIG_AUDIT.md` item 10 for the exact
  reasoning.

## Data consistency / recovery drills (section 十五 of the spec)

| Drill | Result |
|---|---|
| A. Remote applied, local pending not yet cleared | Covered by the push-applied-then-timeout fault test — retry resolves without duplicating |
| B. Local save failure | Covered by the pull-succeeds-then-local-save-fails fault test — cursor doesn't advance |
| C. Stale conflict | Covered by existing Phase 2B-3/2B-4 conflict tests (never auto-overwrites) — not re-run fresh this phase |
| D. Create+delete before sync | Covered by existing Phase 2B-4 test (`testCreateThenDeleteCancelsEntirelyWithNoRemoteWrite`) and re-exercised inside the queue-cap-at-scale test this phase |
| E. Update+delete | Covered by existing Phase 2B-4 coalescing test; re-exercised in the hosted dogfood run (update → delete → tombstone) |
| F. Queue full, delete still enqueues | `testQueueCapAt200HoldsFirmAgainst250AttemptedCreatesAndDeletesAreNeverDropped` |
| G. Logout, pending retained | `testLogoutBeforeSyncNeverStartsARun` (this phase) + existing Phase 2B-3 logout tests |
| H. User A/B scope isolation | Existing Phase 2B-4 isolation tests, unmodified and still passing |
| I. Rollback scoped to session | Existing `GuestMergeController.rollback` tests, unmodified |
| J. Consistency checker finds issues, then clean after recovery | Exercised for real in the hosted dogfood run (checker returns 0 issues after a full clean flow); a dedicated "checker finds an issue, then clean after fix" unit test was not added fresh this phase — the checker's own 5 Phase 2B-5 unit tests already cover issue-detection in isolation |

## Test count

- `GuestMergeTests`: 99/99 (was 82 after Phase 2B-5; +17 new this phase:
  11 fault-injection, 3 single-flight/lifecycle, 3 scale, 1 queue-cap-at-scale
  — see the exact list in `docs/INVENTORY_SYNC_FAULT_INJECTION.md`).
- Full iOS Unit: 568/568 (4 safe skips) — was 550 after Phase 2B-5.
- Full iOS UI: 5/5 (1 safe skip) — unchanged.
- Node: see `PROJECT_STATUS.md`/`CHANGELOG.md` for the exact count after
  this phase's semantic-guard additions.

No existing test was reduced, deleted, or weakened.
