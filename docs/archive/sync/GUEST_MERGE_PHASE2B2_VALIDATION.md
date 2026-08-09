# Guest Inventory Merge Phase 2B-2 Validation

## Scope

Phase 2B-2 adds a deliberately opt-in, Debug-only hosted smoke harness that
exercises the real Phase 2B-1 Guest inventory merge feature end to end
against the development Supabase project through the existing Render
deployment. It is not a new product feature and adds no new backend endpoint.

- `INVENTORY_SYNC_ENABLED` and the new `GUEST_MERGE_SMOKE_ENABLED` remain `NO`
  in committed and example configuration, mirroring the Phase 2A-4
  `SYNC_SMOKE_ENABLED` pattern. `GUEST_MERGE_SMOKE_ENABLED` additionally
  requires `INVENTORY_SYNC_ENABLED` to be on and the same
  `SYNC_SMOKE_ENVIRONMENT = development` marker Phase 2A-4 already uses.
- The smoke runs entirely through the real, unmodified `GuestMergeController`
  (`confirmMerge`/`rollback`/`preparePreview`) — the same code path a
  signed-in user's account page runs — never a reimplemented upload path.
- Every merge item this run touches is created inside an isolated, in-memory
  `KitchenStore`/`SwiftDataSyncPersistence` container built solely for the
  smoke run; the developer's own real local Guest inventory is never read,
  scanned, or referenced by the harness at all.
- Every item this run creates or reads back on the real backend is tagged
  `__guest_merge_smoke_<marker>_<suffix>` (an 8-character random marker per
  run) so it is trivially identifiable and never resembles real data.
- Two distinct, pre-existing real development test accounts are required
  (read from an ignored environment file, never printed or embedded in a
  launch environment); no new account is created by the smoke.

## Phase 2B-2 addition: a real pre-merge remote read

Phase 2B-1 always generated its merge plan with `knownRemoteItems` empty (by
design — see `docs/GUEST_MERGE_PHASE2B.md`), so no real conflict could ever be
produced through the ordinary product code path. Genuinely validating
quantity/expiry/metadata/ambiguous-duplicate conflicts against a real backend
required completing that deferred piece:

- `GuestMergeController.preparePreview` gained an optional `remoteTransport`
  parameter (default `nil`, so every ordinary in-app call site is unaffected
  and preview stays zero-network exactly as before). When supplied, a new
  private `fetchKnownRemoteItems` performs a read-only
  `SyncTransport.fetchChanges` pull (a GET, no writes, no persisted cursor
  advance) to learn what already exists remotely before `InventoryMergePlanner.makePlan`
  runs.
- `RemoteInventorySnapshotItem` and `InventoryMergeCandidate` both gained a
  `remoteVersion` field so `confirmMerge` can seed the correct baseVersion
  for a same-id `.update` candidate whose remote existence this device only
  just learned about (it previously had no local `SyncMetadata` for that
  entity, which would otherwise send baseVersion `0` and get correctly
  rejected as a stale-version conflict by the real server). The seed only
  ever fills in a previously-unknown local value — it never overwrites
  already-known local sync state.
- 4 new offline `GuestMergeTests` cases cover this (pre-merge read finds a
  conflict; baseVersion is correctly seeded and the update actually applies;
  an already-known local version is never overwritten by a stale
  snapshot-time value).

## Test-harness fixes found during the real hosted run

Two issues surfaced only by attempting the real end-to-end run — both were
test-harness mistakes, not product bugs, and are recorded here for context:

1. The mock transport's own duplicate-retry check initially used a brand-new
   `mutationId` for the "duplicate" resend — which the server's idempotency
   ledger (keyed on `(user_id, mutation_id)`) correctly does not treat as a
   duplicate at all, since it is a legitimately new mutation id. Fixed by
   capturing and resending the *exact same* persisted `PendingMutation`,
   mirroring `SyncSmokeRunner`'s already-proven pattern.
2. The session-resume-after-re-login check initially queried
   `activeGuestMergeSession`, which by design excludes terminal sessions —
   but by that point in the run the session is already `.completed`. Fixed
   to query `guestMergeSession(id:)`, which remains valid for terminal
   sessions as history.

## Phase 2B-2.5: same-id `keepBoth` identity fork (fixed)

The original Phase 2B-2 round confirmed but deliberately did not fix a gap:
`InventoryMergeCandidate.applyingChoice(.keepBoth)` on a **same-id** conflict
(`remoteItemId == localItemId`) set `action = .create` without allocating a
new id. Staging it would have targeted an entity id that already exists
remotely at a non-zero version — the server would correctly reject it as a
stale-version conflict (never a create, never an update, never a genuinely
new independent record), so the user's "keep both" intent could never
actually be satisfied for a same-id conflict.

**Audit of the original behavior** (traced through the real code, not just
asserted): `resolved()` in `InventoryMergePlanner.swift` always sets
`action: .skip` for every classification — `.create`/`.update` only ever
arise via `applyingChoice`, never from matching itself. For same-id
`keepBoth`, `applyingChoice` set `action = .create` while leaving
`localItemId`/`remoteItemId` untouched (both equal to the existing entity's
real id). In `GuestMergeController.confirmMerge`'s staging loop, this
candidate's local item was passed as-is to `InventorySyncAdapter.stageUpsert`,
which computes `baseVersion` from local `SyncMetadata` — nil for a Guest
device merging for the first time, so `baseVersion` came out `0`. Sent
against a real, already-versioned remote entity, the server's optimistic-
concurrency check would answer `conflict` (`stale_version`), never `applied`.
So same-id `keepBoth` always eventually resolved to **conflict** — not
create, not update, not rejected — leaving the item stuck, unresolvable
through the merge UI.

**Fix — identity fork, no new SwiftData model.** The simplest, transactionally
safe option (over a separate `InventoryIdentityFork` record type) was chosen:
`InventoryMergeCandidate` gained a `var forkedLocalItemId: UUID? = nil` field,
already `Codable` and already persisted as part of `GuestMergeSession.plan` —
no new table, no new persistence API, reusing the exact same restart-safe
JSON-encoded plan storage Phase 2B-1 already built. `applyingChoice(.keepBoth)`
now sets `forkedLocalItemId = (remoteItemId == localItemId) ? (forkedLocalItemId ?? UUID()) : nil`
— generated once, reused verbatim on every subsequent call (the `?? UUID()`
only fires the very first time; every later call, including after an App
restart re-decodes the exact same persisted candidate, sees its own
already-set value and keeps it). The different-id ambiguous-duplicate case is
completely unaffected — its own id was already distinct, so it stays `nil`
and keeps its pre-existing `.create`-with-its-own-id behavior.

`confirmMerge`'s staging loop now checks `candidate.forkedLocalItemId` first:
if set, it copies the local item's values under the forked id (`forkedItem.id
= forkedId`) and stages *that* as a plain create (guarded so a retry never
re-stages an already-created fork) — the original entity id is never touched
at all for this candidate, a true no-op exactly like `keepRemote`. The
read-back loop that populates `createdEntityIds` (used by `rollback`) was
updated to key off `forkedLocalItemId` when present, so rollback only ever
soft-deletes the fork, never the original.

**Local semantics**: the original local Guest `InventoryRecord` is never
mutated or deleted — `InventoryRecord.id` (the primary key) is never changed.
The forked item is a genuinely new, independent local record (created via the
same `stageUpsert` → `commitInventoryAndSync` path that already writes
`InventoryRecord`), so after `keepBoth`, the local inventory list shows two
distinct records: the original (still mapped to the original, untouched
remote entity) and the fork (mapped to the new remote entity it created).

**Verified idempotent and restart-safe**: repeated `resolveConflict`/
`confirmMerge` calls never mint a second fork id or a second mutation
(guarded on existing local `SyncMetadata` for the forked id); the forked id
survives a simulated App restart (persisted in the plan); rollback only
soft-deletes the fork and leaves the original remote record and the original
local Guest record untouched; the different-id ambiguous-duplicate path is
provably unaffected (dedicated regression test).

## Safety boundary

`GuestMergeSmokeRunner` and `GuestMergeSmokeConfiguration` are compiled only
for Debug builds (`#if DEBUG`). The runner has no App-startup, login, timer,
or background hook — it is only ever invoked by the Debug-only
`HostedGuestMergeSmokeTests.testControlledDevelopmentGuestMergeSmoke` (the
full 18-point matrix) or `testControlledDevelopmentSameIdKeepBothIdentityFork`
(the Phase 2B-2.5 minimal fork-only check, added via a new
`GuestMergeSmokeRunner.runIdentityForkMinimalSmoke` method — deliberately not
a repeat of the full matrix), both of which `XCTSkip` unless both smoke flags
and (for the full matrix) two, or (for the fork-only check) one, real
test-account credential(s) are explicitly supplied via an ignored environment
file. A thrown error at any stage triggers a best-effort soft-delete sweep of
every marker id the run has created so far before rethrowing, so an
interrupted run does not require manual cleanup; a one-off
`scripts/cleanup-guest-merge-smoke-markers.mjs` (authorized user-level API
only, no service-role key, no physical delete) is also available for
recovering from an already-interrupted prior run.

## Validation status — 2026-07-14

- Environment gate: workspace clean, `origin/main` matched local `HEAD`
  (both Phase 2B-1 commits present) before this round began. Confirmed the
  Render deployment has only one real backend URL, referred to throughout
  the project's own history as "development Render → development Supabase"
  — no separate production Supabase project exists yet, so there was no
  risk of the smoke reaching a production database.
- Real hosted run against the development Supabase project (via the existing
  Render deployment) passed on the second attempt (the first attempt caught
  the two test-harness issues above, whose 8 orphaned marker rows were
  cleaned up via `scripts/cleanup-guest-merge-smoke-markers.mjs` before
  retrying) and again on a third confirmation run:
  - Preview performed zero network writes (pending-mutation count and remote
    inventory count both unchanged across the preview call).
  - Create applied with the correct remote version.
  - Duplicate retry (same mutationId/entityId/payload/baseVersion) did not
    create a second record or bump the version.
  - Quantity conflict, expiry conflict, and metadata conflict were each
    correctly detected against real, already-existing remote counterparts
    (never silently auto-created or overwritten).
  - Ambiguous duplicate (2 real remote candidates sharing a business key)
    was never auto-selected.
  - An identical-content item already known remotely resolved as a true
    no-op.
  - Plan drift (a local edit before confirming) invalidated the previously
    generated plan hash and required a fresh preview.
  - A brand-new controller instance against the same persistence (simulating
    an App restart) resumed the same session id with the same conflict
    choices intact.
  - Sign-out refused a further rollback attempt without changing session
    status; re-signing in as the same account resumed the same
    (by-then-terminal) session by id.
  - A second, distinct real development account's own bootstrap returned a
    different household and could not see the first account's merge
    session.
  - Rollback reached `.rolledBack`, soft-deleting only this run's own
    created records; a final real pull observed the delete tombstone(s).
  - Guest data outside the isolated smoke dataset (shopping, today plan,
    weekly plan, user recipes, all read from the harness's own isolated
    store) was unchanged throughout.
  - After the run, `scripts/cleanup-guest-merge-smoke-markers.mjs` confirmed
    zero remaining marker rows on the real backend.
- Safety flags restored: `INVENTORY_SYNC_ENABLED = NO` and
  `GUEST_MERGE_SMOKE_ENABLED = NO` in the ignored `Local.xcconfig`; both were
  already `NO` in `Shared.xcconfig`/`Local.example.xcconfig` throughout (only
  the ignored local file was ever changed).
- Final regression with flags restored: Node 802/802 passed; iOS Unit
  507/507 passed with exactly 1 safe skip (`HostedGuestMergeSmokeTests`,
  correctly skipping without credentials/flags) and 0 failures; iOS UI 4
  tests with exactly 1 safe skip (`HostedSyncSmokeUITests`, unaffected) and
  0 failures; `ReceiptCompactListUITests` passed; Debug build 0 errors, no
  new warnings; `npm run smoke:sync` (against a locally started Express
  server) passed; `npm audit --omit=dev --audit-level=high` found 0
  vulnerabilities; `git diff --check` clean.
- No real hosted Guest merge was left in a live/pending state; no test
  account was created; no automatic sync was enabled; nothing was pushed.

## Validation status — 2026-07-14 (Phase 2B-2.5, same-id keepBoth identity fork)

- 8 new offline `GuestMergeTests` cases (forking/baseVersion-0/expiry+metadata
  variants/repeated-confirm idempotency/restart-survival/rollback-scoped-to-
  fork/keepLocal+keepRemote-never-fork/different-id-ambiguous-regression) plus
  a strengthened pre-existing test, all passing; 6 new Node semantic-guard
  assertions (fork allocation, baseVersion-0 wiring, no simultaneous
  keepRemote+create on the original id, rollback references only
  `createdEntityIds`, different-id path unaffected, no new flag needed for
  this fix) — Node 808/808, iOS Unit 515/515 (2 safe skips) + UI 4 (1 safe
  skip), 0 failures.
- Minimal real hosted smoke (`testControlledDevelopmentSameIdKeepBothIdentityFork`,
  never a repeat of the full Phase 2B-2 matrix): seeded one real baseline
  remote marker record, created a same-id local conflict, resolved it via
  `keepBoth`, and confirmed on the real backend that both the original
  (untouched, its own real id) and the forked record (a distinct real id,
  created at baseVersion 0) exist simultaneously. Rollback then soft-deleted
  only the forked record; the original was cleaned up afterward via the
  existing best-effort marker sweep. Passed on the first real attempt.
  `scripts/cleanup-guest-merge-smoke-markers.mjs` confirmed zero remaining
  marker rows both before and after.
- Safety flags restored to `NO` in the ignored `Local.xcconfig` afterward.
- Final regression with flags restored: Node 808/808; iOS Unit 515/515 (2
  safe skips — both `HostedGuestMergeSmokeTests` methods) + UI 4 (1 safe
  skip), 0 failures; `ReceiptCompactListUITests` passed; Debug build 0
  errors, no new warnings; `npm run smoke:sync` passed; `npm audit` 0
  vulnerabilities; `git diff --check` clean; no secret values in any diff.
- Still not entering Phase 2B-3; nothing pushed.
