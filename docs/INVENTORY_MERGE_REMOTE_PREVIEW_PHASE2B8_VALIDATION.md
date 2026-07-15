# Inventory Merge Remote Preview — Phase 2B-8 Validation

**Status: release blocker fixed in code and simulator-validated. Hosted
development validation and physical-device re-verification of the Conflict
UI/Rollback are still pending. Production remains disabled.**

## What this phase implemented

Phase 2B-7B diagnosed and documented (but did not implement) a confirmed
release blocker: the production Guest-merge preview never performed a
pre-merge remote read, so the household's cloud inventory always showed as
empty, the Conflict UI was structurally unreachable, and — since the server
only enforces per-`entityId` optimistic concurrency, never business-key
deduplication — a silent duplicate could be created in production. See
`docs/INVENTORY_MERGE_REMOTE_PREVIEW_FIX_DESIGN.md` for the original design.

Phase 2B-8 implements that design:

1. **Authenticated production call chain.** `GuestMergePromptView` now injects
   `@EnvironmentObject private var authStore: AuthStore` and calls a new
   `GuestMergeController.preparePreview(userId:householdId:kitchenStore:authStore:)`
   overload. Internally this builds `AuthStoreCredentialProvider` and the
   existing `transportFactory` — the exact same pattern `confirmMerge`/
   `syncNow` already use — and delegates to the existing
   `preparePreview(..., remoteTransport:)`. The View never reads a token,
   constructs an `Authorization` header, or stores one anywhere.
2. **Read-only remote fetch, unchanged safety envelope.** `fetchKnownRemoteItems`
   still only ever calls `SyncTransport.fetchChanges` (a GET), still never
   creates a `PendingMutation`, still never advances the persisted pull
   cursor. Two previously-silent failure modes were fixed to `throw` instead:
   - A scope mismatch (`response.scope != scope`) previously `break`-ed out of
     the pagination loop, silently returning whatever partial results had
     already accumulated. It now throws `SyncError.decoding`.
   - Exceeding the hardcoded `maxPages` (50) cap while `hasMore` was still
     `true` previously returned a truncated snapshot as if it were complete.
     It now throws `SyncError.invalidCursor`.
3. **A fetch failure can never look like an empty household.** `preparePreview`
   isolates the remote-fetch `try`/`catch` from the rest of its body. On
   failure it sets a new, dedicated `@Published previewFetchFailureMessage`
   (mapped through the existing `userFacingSyncError`), and returns
   immediately without touching `session` at all — no stale session is left
   showing, and no fresh session with an empty `knownRemoteItems` is ever
   created. `InventoryMergeFlowView` renders a new
   `InventoryMergePreviewFetchFailureView` whenever this is set, taking
   precedence over both the "没有可合并的库存" empty state and any existing
   plan, with a retry action and no confirm path reachable from it.
4. **Remote snapshot fingerprint.** `InventoryMergePlan` gained
   `remoteSnapshotHash: String?` and `remoteSnapshotFetchedAt: Date?`.
   `InventoryMergePlanner.remoteSnapshotHash(_:)` computes a canonical,
   order-independent SHA256 digest over every field relevant to
   matching/conflict detection (id, name, unit, quantity, expiry, staple
   fields, and `remoteVersion` — so a version bump alone changes the hash).
   It is `nil` whenever no real remote read happened (preserving the exact
   prior offline/no-transport behavior). `planHash` now folds this fingerprint
   in, and `isPlanStillValid` takes an optional `currentRemoteItems` so
   remote drift invalidates a plan exactly like local drift already did.
5. **Confirm-time revalidation.** `confirmMerge` now, immediately before
   staging any mutation: validates the session belongs to the currently
   authenticated user; if the plan carries a `remoteSnapshotHash`, re-fetches
   the current remote snapshot (via the same transport the upload itself
   will use) and re-hashes it; on any mismatch, reverts the session to
   `.previewReady`, shows "家庭库存已变化，请重新预览", and returns — before
   any `stageUpsert`/`stageDelete`/`sendMutations` call. No second,
   redundant transport is constructed for the revalidation fetch.
6. **Conflict UI reachability.** No changes were needed to
   `InventoryMergeConflictView`/`InventoryMergePlanner`'s matching logic —
   the quantity/expiry/metadata/ambiguous-duplicate classification already
   existed and was already correct; it was simply unreachable because
   `knownRemoteItems` was always empty in production. With a real transport
   now wired in, it is reachable from the shipped app for the first time.
7. **Silent-duplicate regression test.** A new, exactly-named test,
   `testProductionPreviewDoesNotSilentlyCreateBusinessEquivalentRemoteItem`,
   seeds a remote item and a local business-equivalent item under a different
   id, runs the production preview overload, and asserts the result is an
   `.ambiguousDuplicate` conflict (never a silent `.create`) and that
   confirming with it unresolved uploads nothing.

## A regression found and fixed during this phase

While wiring the confirm-time revalidation, `preparePreview`'s existing
local-drift check (`InventoryMergePlanner.isPlanStillValid(existingPlan,
against: localItems)`) was found to never pass the freshly-fetched remote
items in. Once a plan carried a non-`nil` `remoteSnapshotHash`, this made
`isPlanStillValid` always return `false` (since a missing `currentRemoteItems`
defaults its comparison hash to `nil`, never matching a real fingerprint) —
so **every** call to `preparePreview` against an existing session with a
remote-backed plan silently regenerated the plan from scratch, discarding any
resolved conflict choices and same-id `keepBoth` forked ids. This surfaced as
10 existing `GuestMergeTests` failures once the new remote-transport-based
tests were added. Fixed by threading the freshly-fetched `knownRemoteItems`
into the `isPlanStillValid` call inside `preparePreview`.

A related test-mock artifact was also found and fixed: several existing
tests called `SimulatedMergeTransport.clearRemoteChanges()` immediately
before `confirmMerge`, to stop the coordinator's own real pull phase from
re-processing a synthetic pre-merge-read entry. This is incompatible with
the new confirm-time revalidation (which also reads from the same mock
before the clear would have run), so the mock's `sendMutations` was changed
to drop a seeded entry once the corresponding entity is actually applied
(mirroring what a real backend's own pull would return), and the explicit
`clearRemoteChanges()` calls were removed from the affected tests. Two
tests' assertions were also updated to reflect a more accurate consequence
of a real confirm-time pull: an untouched-by-upload entity (e.g. the
original id in a same-id `keepBoth` fork) now legitimately gains
`SyncMetadata` reflecting the pre-existing remote record it was previously
unaware of, rather than staying `nil`.

## Validation performed

- **Offline/simulator XCTest**: 19 new `GuestMergeTests` cases added,
  covering production-overload wiring and non-nil transport construction,
  token-boundary (structural — the overload only ever accepts an `AuthStore`
  reference), remote count correctness, scope-mismatch/pagination-cap/401/
  offline/malformed-response preview failures (each proven to block preview
  and set `previewFetchFailureMessage`, never silently succeed with
  `knownRemoteItemCount: 0`), zero-mutation/zero-cursor-advance during
  preview, remote-fingerprint determinism/order-independence/version-change/
  create-and-delete-change, remote-drift plan invalidation via
  `isPlanStillValid`, stale-confirm rejection (zero `PendingMutation` staged,
  zero `sendMutations` calls, session reverted to `previewReady`), a
  successful confirm when the remote fingerprint is unchanged, household
  isolation of the pre-merge read, remote-fingerprint survival across a
  simulated app restart, and the silent-duplicate regression test. Full
  `GuestMergeTests` suite: **118/118 passing** (up from 99).
- **Full iOS Unit regression**: **583/583 passing** (up from 568), 0
  regressions, 0 failures.
- **iOS UI test target**: verified to still build cleanly
  (`build-for-testing`) with the new `InventoryMergePreviewFetchFailureView`
  and `authStore` environment-object wiring; the existing UI suite was not
  re-run end-to-end this phase (no new UI test cases were added — see "Not
  done this phase" below).
- **Debug and Release clean builds**: both **0 errors**.
- **Node semantic guards**: 10 new assertions added to
  `test/ios-native-guest-merge-phase2b1.test.mjs` covering the authenticated
  production call site, the transport-construction pattern, the
  no-token-in-View invariant, the isolated fetch-failure try/catch, the
  scope-mismatch/pagination-cap throw fix, the remote-fingerprint concept,
  confirm-time revalidation preceding any stage/upload call, the existence
  of the named silent-duplicate regression test, all flags remaining `NO`,
  and no service-role/automatic-sync/Shopping-Plan-Recipe wiring. Full Node
  suite: **864/864 passing** (up from 854).
- **`npm audit --omit=dev --audit-level=high`**: 0 vulnerabilities.
- **`git diff --check`**: clean.
- **Secret scan**: no credentials, tokens, or service-role strings found in
  the diff (the one regex hit was the guard test's own pattern literal).
- **Ignored files**: `.env.development.local` and
  `ios-native/Kitchen Manager/Config/Local.xcconfig` remain untracked/ignored.

## Not done this phase (deferred, not blocking)

- The 16 named UI test scenarios from the design spec (loading state, remote
  count display, fetch-failure copy, confirm disabled during fetch failure,
  per-reason conflict cards, all four choices, choice persistence, stale
  alert, retry, no internal IDs, tap targets, VoiceOver, Dynamic Type,
  hidden-when-flag-off, hosted-safe-skip) were not written as new XCUITest
  cases. The UI test target was confirmed to still compile and the existing
  6 UI tests are unaffected.
- **Hosted minimal validation** (remote count, quantity conflict, stale
  preview rejection, fresh preview + explicit resolution, marker cleanup)
  was not performed — it requires live development-environment access and
  explicit, user-driven marker seeding/cleanup with temporarily-enabled
  flags, which was out of scope for this pass.
- **Physical-device re-verification** of the Conflict UI and Rollback (both
  still open from Phase 2B-7) was not attempted — no device was available in
  this environment.
- Rollback testing was not entered, per this phase's explicit instructions.

## Go/No-Go

Unchanged at **Dogfood Go / Production No-Go**. The specific item that made
Phase 2B-7B classify Conflict UI as a confirmed release blocker — the
production preview's structural zero-network behavior — is now fixed in
code and covered by simulator-level regression tests. Before this can become
Production Go: hosted development validation (section 十八 of this phase's
spec) and a physical-device re-run of the Conflict UI and Rollback flows are
still required, exactly as before.
