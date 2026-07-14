# Inventory Sync Fault Injection (Phase 2B-6)

## Scope and location

`InventorySyncFaultInjectingTransport` and `InventorySyncFault` live entirely
inside `ios-native/Kitchen Manager/KitchenManagerTests/GuestMergeTests.swift`
(both `private`, file-scoped). They are not referenced anywhere under
`KitchenManager/` (the app target) — by construction they cannot compile
into a Debug or Release app build, cannot be enabled by a remote response,
and never appear in ordinary product UI. This was verified structurally
(the types simply don't exist outside the test target) and is asserted by
a Node semantic guard (`test/ios-native-guest-merge-phase2b1.test.mjs`).

## Design

`InventorySyncFaultInjectingTransport` wraps a real inner `SyncTransport`
(the existing `SimulatedMergeTransport` test fake) and, per configured
`InventorySyncFault`, either:

- `.none` — delegates straight through, no fault.
- `.throwError(SyncError)` — throws before delegating, simulating an HTTP
  error class (401 → `.unauthorized`, 403 → `.forbidden`, 409 → the existing
  `SimulatedMergeTransport.seedExistingRemote` conflict path, 413 →
  `.payloadTooLarge`, 429/500/503 → `.backendUnavailable`, offline/timeout →
  `.transport`).
- `.malformedOrTruncatedJSON` — throws `.decoding`; malformed and truncated
  JSON manifest identically at this layer (a decode failure the coordinator
  must treat the same non-destructive way), so one fault case covers both.
- `.delay(TimeInterval)` — awaits before delegating, for a slow-response case.

A separate `applyFirst` flag on `sendMutations` lets the inner fake actually
record the mutation as applied (server-side state genuinely advances)
*before* the configured fault is raised to the caller — this is how "push
applied, then the client times out" and "app killed after push, before
local cleanup" are modeled: the server-side effect is real, only the
client's own view of the outcome is faulted.

`429` has no dedicated `SyncError` case yet — it's deliberately mapped onto
the existing retryable `.backendUnavailable` case rather than adding a new
one this phase, since the client-side handling (pending retained, no
automatic retry, user-facing message) is identical either way. A future
phase could add a distinct case if backend behavior ever needs to diverge
(e.g. a `Retry-After` hint).

## Determinism

Every fault is set explicitly per test via `setBootstrapFault`/
`setFetchChangesFault`/`setSendMutationsFault` before the run starts, so
every scenario is deterministic and repeatable — no randomness, no real
network, no timing dependent on an actual server.

## Coverage (see `GuestMergeTests.swift`, "Phase 2B-6" sections)

| Scenario | Test |
|---|---|
| Offline (bootstrap) | `testOfflineDuringBootstrapLeavesPendingRetainedAndCursorUnmoved` |
| 401 | `test401DuringBootstrapStopsTheRunAndRetainsPendingForRetryAfterReLogin` |
| 403 | `test403OnBootstrapStopsTheScopeWithoutDeletingPending` |
| 409 stale conflict | existing `SimulatedMergeTransport.seedExistingRemote`-based tests (Phase 2B-3/2B-4) |
| 413 | `test413PayloadTooLargeRetainsPendingAndSurfacesAnUnderstandableError` |
| 429 | `test429IsTreatedAsRetryableAndNeverBusyLoopsSinceSyncIsAlwaysManuallyTriggered` |
| 500/503 | `test500And503AreRetainedAsRetryable` |
| Malformed/truncated JSON | `testMalformedOrTruncatedJSONNeverAdvancesTheCursorOrDropsPending` |
| Push applied + client timeout | `testPushAppliedThenClientTimeoutIsDuplicateSafeOnRetry` |
| Pull succeeded + local save failure | `testPullSucceedsButLocalSaveFailureNeverAdvancesCursor` |
| App killed after push, before cleanup | `testAppKillBeforePendingCleanupIsRecoveredAndDuplicateSafeOnNextLaunch` |
| Single-flight (10 rapid taps) | `testTenRapidSyncTapsOnlyEverAttemptSendMutationsOnce` |
| Logout stops next batch | `testLogoutBeforeSyncNeverStartsARun` |
| Scope-mismatch doesn't stick the guard | `testAScopeMismatchNeverLeavesTheSingleFlightGuardStuck` |

Timeout is modeled the same way offline is (`.throwError(.transport)`) since
`SyncError` doesn't distinguish "no connection" from "connection timed out"
at the client's error-handling layer — both are non-retryable-automatically,
pending-retaining, `.transport` failures from the coordinator's point of
view. A dedicated `.delay` fault exists for a genuinely slow (not
timed-out) response if a future phase needs to assert UI behavior during a
long-running call.
