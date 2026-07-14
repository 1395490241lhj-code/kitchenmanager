# Inventory Sync Scale / Performance Results (Phase 2B-6)

## Method

All measurements are local, in-process XCTest timings on the development
machine's iPhone 17 Pro (iOS 27.0) simulator — never against a real device
or the hosted backend, and never using real user data. These are sanity
bounds to catch an obvious algorithmic regression (e.g. an accidental
O(n²)), not a performance SLA or an absolute promise about real-device or
real-network behavior, which depends on hardware, thermal state, and
network conditions this phase does not attempt to characterize.

## Results

| Scenario | Rows | Measured | Local bound asserted | Result |
|---|---|---|---|---|
| `InventorySyncConsistencyChecker.check` | 1000 `SyncMetadata` rows, 0 pending | Single-pass wall time | < 2.0s | Passed — completed in well under 100ms in practice |
| `InventorySyncEligibility.evaluate` | 500 calls at `currentPendingCount: 500` | Wall time for 500 calls | < 1.0s | Passed — each call is O(1) (no iteration over existing pending rows; the caller supplies the count) |
| `GuestMergeController.diagnosticsSnapshot` | 500 pending mutations (100 with matching conflicted metadata) | Single snapshot build wall time | < 2.0s | Passed |
| Queue-cap pressure | 250 attempted creates against a 200 cap | End-to-end `handleInventoryDidChange` × 250 | (no explicit time bound; correctness-focused) | Passed — held exactly at 200, no growth |

## What was not measured this phase

- 100/1000-item **merge preview** construction time (`InventoryMergePlanner.makePlan`) at scale — the planner's own complexity was last characterized in earlier phases (`testSnapshotIsCappedButPlanStillCoversEveryLocalItemBeyondTheCap` exercises the existing preview cap, but this phase did not add a fresh 1000-item timing assertion for it).
- Manual sync **batch pagination** behavior at 500+ pending mutations against a real or even simulated paginating backend (the existing `SimulatedMergeTransport` fake does not model `maxBatchSize` pagination on the push side).
- Real memory-growth profiling (Instruments) at any scale — the 500-pending diagnostics test is a wall-clock timing check only, not a memory profile.
- Any measurement on a physical device.

## Findings

- No O(n²) hotspot was found in the code paths exercised: `InventorySyncConsistencyChecker.check` builds two dictionaries (`Dictionary(uniqueKeysWithValues:)`, `reduce`-style grouping) in a single pass over `allMetadata` and `allPendingMutations` each, then does O(1) dictionary lookups per row — the whole function is O(n), not O(n²).
- `InventorySyncEligibility.evaluate` never iterates any collection itself — `currentPendingCount` and `hasExistingPendingMutationForEntity` are precomputed by the caller (`GuestMergeController.stageMutationIfEligible`, which does its own single `pendingMutations(scope:maxAttempts:)` query per call) — so the queue-cap check added this phase is O(1) per call, not a new hotspot.
- `diagnosticsSnapshot` does a small, fixed number of persistence queries (`allPendingMutations`, `allMetadata`, `cursor(for:)`) each once, then filters/maps them in memory — linear in the row count, not quadratic.
- None of the code exercised here runs inside a SwiftUI `body` — `diagnosticsSnapshot`/`consistencyCheck` are both `async` methods called from `.task` modifiers in `InventorySyncDiagnosticsView.swift`, never computed synchronously during view rendering.
- No blocking of the main thread was observed in these tests, since every method involved is either a pure/synchronous value-type function (`InventorySyncConsistencyChecker.check`, `InventorySyncEligibility.evaluate` — both fast enough to be safe even off an actor) or an `async` actor-hop (`diagnosticsSnapshot`) that already runs off the render path.

## Conclusion

Nothing found this phase requires a blocking fix. The gaps above (merge
preview at scale, batch pagination modeling, real memory profiling,
physical-device timing) remain open evidence gaps for a future phase, not
known defects.
