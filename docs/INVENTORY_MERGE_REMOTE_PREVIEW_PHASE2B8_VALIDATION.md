# Inventory Merge Remote Preview — Phase 2B-8 Validation

**Status: release blocker fixed in code, simulator-validated,
hosted-development-validated, and now physical-device-validated for real
(Phase 2B-8C).** A real dead-end bug in the Conflict UI's resolution flow
was found and fixed during physical-device revalidation — see
`docs/INVENTORY_SYNC_PHYSICAL_DEVICE_RESULTS.md` for the full account,
including an unplanned, single incidental exercise of Rollback. Formal,
deliberate Rollback validation remains pending. Production remains
disabled.

## Acceptance round: hosted validation executed for real

`HostedGuestMergeSmokeTests.testControlledDevelopmentProductionRemotePreviewSafety`
(backed by `GuestMergeSmokeRunner.runProductionRemotePreviewMinimalSmoke`)
was run for real by the operator from a normal Terminal, via a
purpose-built, credential-safe runner script
(`/tmp/run_phase2b8_hosted_preview.sh`, not part of this repository) that:
temporarily set `INVENTORY_SYNC_ENABLED`/`GUEST_MERGE_SMOKE_ENABLED` to
`YES` in the gitignored `Local.xcconfig`; sourced credentials from the
gitignored `.env.development.local` into the shell only; injected them
in-place into the real, unmoved `.xctestrun` under `DerivedData/Build/Products`
(its `__TESTROOT__`/`__TESTHOST__` placeholders resolve relative to that
file's own directory, so it was edited in place rather than copied
elsewhere) for the duration of the run only; and restored everything via a
`trap cleanup EXIT INT TERM` regardless of outcome.

**Result: PASS.** Verified independently via `xcresulttool` against the
produced `/tmp/km_phase2b8_hosted_preview.xcresult` (not this repo) rather
than trusting the terminal transcript alone:

- `testControlledDevelopmentProductionRemotePreviewSafety()` — result
  `Passed`, duration **23 seconds** (a skip is always <0.01s, so this proves
  genuine execution, not a safe-skip), `passedTests: 1`, `skippedTests: 0`,
  `failedTests: 0`.
- **Marker residue**: confirmed **zero** via a read-only, throwaway Node
  script (never committed) that signed in as `TEST_USER_A` and listed the
  household's live `inventory_item` change-feed entries — 0 items matched
  the `__inventory_remote_preview_` prefix afterward.
- **Flags restored**: `Local.xcconfig`'s `INVENTORY_SYNC_ENABLED` and
  `GUEST_MERGE_SMOKE_ENABLED` both confirmed back to `NO` by direct
  inspection.
- **No credential residue**: the regenerated `.xctestrun` was inspected —
  zero occurrences of any `TEST_USER_*` key, and its file mode was back to
  the ordinary `644` (not the `600` used transiently during the run),
  confirming the in-place edit was fully reverted.

This proves the actual production call chain — the same
`GuestMergeController.preparePreview(userId:householdId:kitchenStore:authStore:)`
overload `GuestMergePromptView` calls — against a real household on the
real development backend: a non-zero remote count, an `.ambiguousDuplicate`
conflict for a business-equivalent duplicate (never a silent create), zero
network writes during preview, a stale confirm correctly rejected (zero
mutations staged, session reverted to `previewReady`), a fresh preview
recovering and completing after an explicit safe choice (`keepRemote`), and
clean marker teardown — all through `GuestMergeController` itself, never a
bespoke `InventoryMergePlanner` construction.

`npm run smoke:sync` was also re-run for real against the same development
backend as part of the final regression pass and passed (reachability +
the underlying Express/Supabase sync contract) — a separate, complementary
check; it calls the HTTP API directly and does not itself exercise
`GuestMergeController`.

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
- **Hosted development validation**: **executed for real and passed** — see
  "Acceptance round" above. Remote count, conflict reachability, zero-write
  preview, stale-preview rejection, fresh-preview recovery, and marker
  cleanup were all verified against the real development Supabase
  project/Render deployment through the actual production call chain.

## Final regression after the hosted run (re-confirmed)

- `GuestMergeTests`: **118/118 passing**.
- Full iOS Unit: **583/583 passing**, 0 failures, 5 safe skips (up from 4 —
  the new hosted test itself now also safe-skips in an ordinary,
  credential-free run).
- Full iOS UI: **6/6 executed, 5 passing, 1 safe skip** (`HostedSyncSmokeUITests`,
  no credentials), 0 failures — confirmed via a serial run (parallel runs
  can show transient simulator-contention flakes unrelated to this change).
- Debug and Release clean builds: both **0 errors**.
- Node (`test/ios-native-guest-merge-phase2b1.test.mjs` focused +
  `npm test -- --test-reporter=tap` full suite): **864/864 passing**.
- `npm run smoke:sync`: **PASS** against the real development backend.
- `npm audit --omit=dev --audit-level=high`: 0 vulnerabilities.
- `git diff --check`: clean.

## Not done this phase (deferred, not blocking)

- The 16 named UI test scenarios from the design spec (loading state, remote
  count display, fetch-failure copy, confirm disabled during fetch failure,
  per-reason conflict cards, all four choices, choice persistence, stale
  alert, retry, no internal IDs, tap targets, VoiceOver, Dynamic Type,
  hidden-when-flag-off, hosted-safe-skip) were not written as new XCUITest
  cases. The UI test target was confirmed to still compile and the existing
  6 UI tests are unaffected.
- **Formal, deliberate Rollback validation** (with predicted-vs-actual
  verification against `createdEntityIds`, per the project's established
  protocol) was not performed — see
  `docs/INVENTORY_SYNC_PHYSICAL_DEVICE_RESULTS.md` for the one unplanned,
  incidental Rollback exercised during Phase 2B-8C, and why it does not
  substitute for a formal test.
- A real-device stale-preview confirm rejection (section 八 of the Phase
  2B-8C spec) was not attempted — already hosted-validated via a focused
  XCTest in the prior Phase 2B-8 acceptance round; repeating it on-device
  was judged to add data risk without new information, and is left
  **pending**, not claimed as passed.

## Phase 2B-8C: physical-device Conflict UI revalidation

Executed for real on a physical iPhone 17 Pro (iOS 27.0, Developer Mode
enabled) against the real development Supabase project/Render deployment,
using two isolated `__inventory_device_conflict_retest_<id>` markers (both
soft-deleted afterward, zero residue confirmed via a read-only check). Full
detail, including a real bug found and fixed, is in
`docs/INVENTORY_SYNC_PHYSICAL_DEVICE_RESULTS.md`. Summary:

- **Remote count**: PASS — the production preview correctly showed the
  household's real cloud inventory count (never 0) on a real device for the
  first time.
- **Conflict UI reachability**: PASS — reachable via the existing
  "确认合并库存" path (the "可能重复" count itself is display-only by
  design, not a navigation link — this is pre-existing Phase 2B-3 behavior,
  not a defect).
- **Quantity conflict display**: PASS — local (5) and household (2) values,
  clearly labeled "本机"/"家庭", both shown correctly.
- **Four choices visible**: PASS — 保留本机/保留家庭/两条都保留/稍后处理 all
  present; no UUID, remoteVersion, mutation id, token, or household id shown
  anywhere.
- **A real bug was found**: choosing any of the four choices for the last
  remaining conflict left the session permanently stuck in `.conflict`
  status with no way to ever confirm again — `InventoryMergeConflictView`
  has no confirm/continue action of its own, and nothing transitioned the
  session status back to a state the preview screen (which has the confirm
  button) would render for. This was a pre-existing Phase 2B-3 architecture
  gap, invisible until Phase 2B-8 made the Conflict UI reachable at all.
  **Fixed**: `GuestMergeController.resolveConflict` now transitions the
  session back to `.previewReady` once every candidate has a choice,
  handing control back to the existing preview/confirm flow. Covered by a
  new regression test,
  `testResolvingTheLastConflictReturnsToPreviewReadyNotStuckOnConflict`.
- **Choice persistence / zero-write before confirm**: PASS for the
  underlying data model (verified both via the fix's regression test and
  by re-reading the real remote state after each device round — no upload,
  no version bump on either marker until an explicit confirm).
- **Stale-preview real-device gate**: not attempted this round (see "Not
  done" above) — **pending**.
- **Silent duplicate**: did not occur — the real device state after the
  round showed no orphaned/duplicate marker entities.
- **An unplanned Rollback was exercised once**, incidentally, by the
  device operator after the fix let a confirm proceed — see
  `docs/INVENTORY_SYNC_PHYSICAL_DEVICE_RESULTS.md` for the full account.
  Observed outcome was clean (no residue), but this is not a substitute for
  the formal Rollback validation still required.

## Go/No-Go

Unchanged at **Dogfood Go / Production No-Go**. The specific item that made
Phase 2B-7B classify Conflict UI as a confirmed release blocker — the
production preview's structural zero-network behavior — is now fixed in
code, simulator-validated, hosted-development-validated, and
physical-device-validated for real, including a genuine bug found and fixed
during that physical-device round. Before this can become Production Go: a
formal, deliberate Rollback validation is still required.
