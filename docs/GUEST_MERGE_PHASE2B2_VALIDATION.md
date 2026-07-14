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

## A confirmed follow-up (not fixed in this round)

Designing the real dataset surfaced that `InventoryMergeCandidate.applyingChoice(.keepBoth)`
on a **same-id** conflict sets `action = .create` but does not allocate a new
id — staging it would target an entity id that already exists remotely at a
non-zero version, which the server should correctly reject as a stale-version
conflict rather than produce an independent second record. `keepBoth` is only
well-defined today for the **different-id** (ambiguous-duplicate) case, where
the candidate's own id is already distinct. This round's smoke dataset uses
`keepLocal`/`keepRemote` for same-id conflicts (the sensible choices when
identity is certain) and reserves `keepBoth` for the ambiguous case, so the
gap was not exercised. Fixing `keepBoth` to allocate a genuinely new id for a
same-id candidate is real, additional Phase 2B-work, out of scope for this
validation round, and not touched here.

## Safety boundary

`GuestMergeSmokeRunner` and `GuestMergeSmokeConfiguration` are compiled only
for Debug builds (`#if DEBUG`). The runner has no App-startup, login, timer,
or background hook — it is only ever invoked by the Debug-only
`HostedGuestMergeSmokeTests.testControlledDevelopmentGuestMergeSmoke`, which
itself `XCTSkip`s unless both smoke flags and two real test-account
credential pairs are explicitly supplied via an ignored environment file. A
thrown error at any stage triggers a best-effort soft-delete sweep of every
marker id the run has created so far before rethrowing, so an interrupted run
does not require manual cleanup; a one-off `scripts/cleanup-guest-merge-smoke-markers.mjs`
(authorized user-level API only, no service-role key, no physical delete) is
also available for recovering from an already-interrupted prior run.

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
