# Quickstart: GuestMergeSmoke direct-call consistency window

**Feature**: 004 | **Branch**: `codex/004-guest-merge-smoke-consistency`

This is a validation guide. It does not contain implementation code.

## Prerequisites

- macOS with Xcode and the iOS 26.0 SDK
- Node 22 or 24 for the repository guard
- Hosted acceptance only: two development test accounts and the ignored local configuration that
  supplies them. Without those, the hosted tests legitimately `XCTSkip`.

## 1. Deterministic correctness (always runnable, no network)

Run the iOS unit test target and confirm the new tests in
[`GuestMergeSmokeConsistencyTests.swift`](../../ios-native/Kitchen Manager/KitchenManagerTests/GuestMergeSmokeConsistencyTests.swift) pass:

    xcodebuild -project "ios-native/Kitchen Manager/Kitchen Manager.xcodeproj" \
      -scheme "Kitchen Manager" -destination 'platform=iOS Simulator,name=iPhone 16' test

Expected: every scenario in Success Criteria SC-002 through SC-006 is covered and green —
protection open before the first durable write, conflicting edit refused, reconciliation on
success and on every failure path, reconcile failure leaving the store locked, nested windows not
unlocking early, and zero outbound echo.

The same suite carries the two prerequisite repairs (SC-010): each affected runner's baseline
confirms and is not retained as the active rollback-capable session, the next preview is a fresh
scenario preview, and a default-window control still exposes an ordinary completed merge as the
active rollback-capable session.

## 2. Call-site guard (always runnable, no network)

    npm test

Expected: the guard in [`ios-native-guest-merge-phase2b1.test.mjs`](../../test/ios-native-guest-merge-phase2b1.test.mjs) passes, and
fails with a named call if an unprotected direct persistence call is reintroduced into
[`GuestMergeSmoke.swift`](../../ios-native/Kitchen Manager/KitchenManager/Synchronization/GuestMergeSmoke.swift).

To prove the guard actually bites, temporarily move one protected call outside its window, rerun
`npm test`, confirm the failure, then restore the file.

## 3. Flag safety

Confirm every committed configuration still defaults sync, merge, smoke, dogfood and diagnostics
flags to `NO`:

    rg -n 'SYNC_ENABLED|INVENTORY_SYNC_ENABLED|GUEST_MERGE_SMOKE_ENABLED|SYNC_SMOKE|DOGFOOD|DIAGNOSTICS' ios-native --glob '*.xcconfig'

Expected: no committed value changed by this feature.

## 4. Hosted development acceptance (optional layer, never a substitute)

Only when the task warrants it and credentials are confirmed. Enable the smoke gates in the
**ignored local configuration only**, then run the five hosted runners in
`HostedGuestMergeSmokeTests`:

1. `run` — the full Phase 2B-2 matrix
2. `runIdentityForkMinimalSmoke`
3. `runInventoryCrudSyncMinimalSmoke`
4. `runInventoryDogfoodMinimalSmoke`
5. `runProductionRemotePreviewMinimalSmoke`

Expected for each: it reaches its existing final checkpoint with unchanged checkpoint semantics,
and baseline seeding now completes rather than aborting the run.

Afterwards, without exception:

- restore every flag to `NO` or its original value;
- verify zero marker residue, or record the exact residual entity ids;
- print no credentials;
- distinguish a runtime `XCTSkip` from a test that was excluded or compiled out.

## 5. What a green run does and does not mean

It means the harness is trustworthy enough to participate in the pre-dogfood acceptance gate.

It does not mean sync is enabled, dogfood has started, production is ready, production Supabase
exists, or that Stage 1 or Stage 2 is approved.

