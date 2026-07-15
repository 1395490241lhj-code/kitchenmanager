# Inventory Merge Remote Preview — Fix Design (Phase 2B-7B)

**Status: implemented in Phase 2B-8.** See
`docs/INVENTORY_MERGE_REMOTE_PREVIEW_PHASE2B8_VALIDATION.md` for what was
actually built, validated, and deferred. This document is kept as the
original design record; the sections below describe the problem and
proposed fix as understood at design time.

## Problem statement

The production Guest-merge preview (`GuestMergePromptView`'s `.task` →
`GuestMergeController.preparePreview(userId:householdId:kitchenStore:)`)
is the only call site for `preparePreview` in the entire app, and it never
passes a `remoteTransport`. `fetchKnownRemoteItems` (`GuestMergeController.swift:152-156`)
short-circuits to `[]` when `transport` is `nil`, so `knownRemoteItems` is
always empty in production. This means:

- The preview always shows "家庭云端库存 0条" regardless of what actually
  exists remotely.
- `InventoryMergePlanner.makePlan`'s quantity/expiry/metadata-mismatch and
  ambiguous-duplicate detection — all thoroughly unit-tested — can never
  fire in production, because it depends entirely on comparing local
  candidates against `knownRemoteItems`.
- The server enforces optimistic concurrency **per-`entityId` only** —
  there is no business-key (name+unit) deduplication anywhere in the
  contract. A local `create` for a business-equivalent item with a
  different id succeeds unconditionally.
- **Net effect**: a real silent-duplicate risk exists in production as
  currently shipped, whenever a Guest-merge candidate happens to already
  have a business-equivalent counterpart remotely (e.g., two family
  members' devices both independently create "牛奶" before either has
  merged).

This was deliberate, documented behavior from Phase 2B-2/2B-3 (preview was
built to be genuinely zero-network, and the pre-merge read capability was
added only for the smoke-test harness's own deeper validation) — not a
silently-introduced bug. But its production-safety implications were not
fully worked through at the time, and Phase 2B-7's physical-device
validation is what surfaced them for the first time.

## Design goal

Wire a real, **read-only** pre-merge remote check into the production
preview path, so `knownRemoteItems` reflects reality before a merge
decision is ever presented to the user — while preserving every existing
safety property (preview still never writes, tokens still never touch a
View, feature flags still default off).

## Proposed call chain

```
GuestMergePromptView (.task)
  → GuestMergeController.preparePreview(
        userId: UUID,
        householdId: UUID,
        kitchenStore: KitchenStore,
        remoteTransport: (any SyncTransport)?   // now supplied in production too
    )
  → fetchKnownRemoteItems(householdId:, transport:)
  → SyncTransport.fetchChanges(scope:after:limit:)   // authenticated GET, read-only
```

The `remoteTransport` the production call site passes should be
constructed the same way `syncNow`/`confirmMerge` already do it today —
via the existing `AuthStoreCredentialProvider`/`transportFactory` pattern
already present on `GuestMergeController` — **not** a new mechanism. The
View itself still never touches a token; it only ever calls
`controller.preparePreview(...)`, exactly as today, with the controller
internally deciding whether/how to construct a transport.

## Requirements (all must hold simultaneously)

1. **Read-only GET only** — the pre-merge read must only ever call
   `fetchChanges`; it must never call `sendMutations` or any other
   write-capable endpoint.
2. **Preview remains zero-write** — this changes preview from
   zero-network to network-but-zero-write; it must never stage a
   mutation, advance the pull cursor, or write any `SyncMetadata`/
   `PendingMutation` record as a side effect of the read.
3. **Household scope validated** — every page of the read must assert
   `response.scope == scope` (mirroring `fetchKnownRemoteItems`'s existing
   check at line 166) before trusting any of its contents.
4. **Pagination + max-page guard** — reuse the existing pattern
   (`maxPages = 50`) already present in `fetchKnownRemoteItems`; this
   already exists and should not regress.
5. **Decode failure blocks preview, never silently degrades to "0 known
   remote items."** This is the single most important requirement — a
   network or decode failure must never be indistinguishable from "the
   household really has nothing yet." Concretely: if the read throws, the
   preview must surface an explicit, plain-language error and refuse to
   show a plan at all, rather than falling back to an empty
   `knownRemoteItems` array. **A network failure must never look like an
   empty household.**
6. **`remoteVersion` flows into each candidate** exactly as it already
   does for the smoke-harness path today (`RemoteInventorySnapshotItem.remoteVersion`
   → `InventoryMergeCandidate.remoteVersion`) — no new field needed, just
   used unconditionally in production too.
7. **Remote snapshot fingerprint included in the plan hash.** Today's
   `planHash` is local-data-only (per `InventoryMergePlanner.isPlanStillValid`).
   It must be extended to also fingerprint the remote snapshot used to
   build the plan (e.g. a hash of `knownRemoteItems`' ids+versions), so a
   plan built against stale remote data is detectable, not just a plan
   built against stale local data.
8. **Confirm must re-verify freshness before writing anything.**
   `confirmMerge` must re-fetch (or at minimum re-validate the remote
   snapshot fingerprint from requirement 7) immediately before staging any
   upload — not trust a plan that may have been generated minutes or hours
   earlier against now-stale remote state.
9. **A plan invalidated by remote drift must behave exactly like a plan
   invalidated by local drift already does today** — regenerate rather
   than silently proceed (`preparePreview`'s existing
   `InventoryMergePlanner.isPlanStillValid` check already does this for
   local drift; extend the same mechanism to cover remote drift via
   requirement 7's fingerprint).
10. **No automatic conflict resolution** — this fix only makes conflicts
    *detectable*; it must never make the app pick `keepLocal`/`keepRemote`/
    `keepBoth` on the user's behalf.
11. **Different-id, same business key → `.ambiguousDuplicate`**, exactly as
    `InventoryMergePlanner` already implements today for the case where
    `knownRemoteItems` is populated (already unit-tested — this fix makes
    that existing logic reachable, it doesn't add new logic).
12. **View never reads a token.** The transport construction stays inside
    `GuestMergeController`, using the existing credential-provider pattern
    — no new token-handling code path in any View.
13. **Token never persisted** — unchanged from today; nothing about this
    fix introduces new token storage anywhere.
14. **No automatic sync introduced** — this is a read triggered by opening
    the merge prompt/preview (already a manual, user-initiated action,
    exactly as today) — it must never be triggered by app launch, login,
    a timer, or a background task.
15. **No automatic conflict resolution** (restated from 10 for emphasis,
    per the task's own list) — never silently pick a side.
16. **Feature flags remain default `NO`** — this fix must not change any
    flag's default; it activates only when `INVENTORY_SYNC_ENABLED` +
    `INVENTORY_MERGE_UI_ENABLED` are already on, exactly as the merge flow
    already requires today.

## Confirm-time safety gate (new)

`confirmMerge` currently has **no re-validation step** before staging
uploads — it trusts whatever plan is attached to the session, however old.
The audit in Phase 2B-7A specifically asked: *if preview showed
`remoteCount=0` because of the zero-network bug, and remote actually
already has a same-name record, does confirm blindly create a duplicate?*
Per the code as it stands today: **yes** — nothing in `confirmMerge`
re-checks remote state before staging `stageUpsert` calls. This is the
core of the release-blocker finding.

The fix must add an explicit gate at the top of `confirmMerge`, before any
`stageUpsert`/`stageDelete` call, that validates all of:

- **Local plan hash** — unchanged from today (already implemented).
- **Remote snapshot hash/version** — new; per requirement 7/8 above, a
  fresh remote read (or at minimum a version-check against the recorded
  fingerprint) must confirm the remote state the plan was built against is
  still current.
- **Current user / household match** — the session's `userId`/`householdId`
  must match the authenticated caller's current identity; never trust a
  session created under a different identity.
- **Session owner** — the session must belong to the currently
  authenticated user; never let one account confirm another's session.
- **Unresolved conflicts** — any candidate still `needsDecision == true`
  with no `userChoice` must block confirm entirely for the whole session,
  not just for that one candidate.
- **Planned item count** — the number of candidates about to be uploaded
  must match what was shown to the user at preview time (ties into the
  plan-hash check, but should be asserted explicitly too, as a
  defense-in-depth belt-and-suspenders check).
- **Active-merge uniqueness** — confirm must refuse to run if another
  merge/sync operation for the same scope is already in flight (this
  already exists via the single-flight `isSyncing` guard on
  `GuestMergeController`, and should continue to apply here unchanged).
- **Stale-preview rejection** — if any of the above checks fail, confirm
  must refuse with a clear, plain-language error (e.g. "远端数据已变化，请重新
  查看合并预览") and require the user to re-open preview — never proceed
  with a partial or best-effort merge.

## Required new tests (design only — not written yet)

1. Production UI call site passes a non-`nil` transport (a source-level
   assertion, mirroring the existing Node semantic-guard pattern that
   already checks `runOnce` call-site counts).
2. Remote item count is displayed correctly in preview when remote data
   genuinely exists (currently untestable in production; would become
   testable after this fix).
3. Same name/unit, different quantity, different id → produces an
   ambiguous/quantity-flagged candidate in the real preview (not just in
   `InventoryMergePlanner` unit tests).
4. Same id, quantity conflict → produces `.quantityMismatch` in the real
   preview.
5. Expiry mismatch → produces `.expiryMismatch` in the real preview.
6. Metadata mismatch → produces `.metadataMismatch` in the real preview.
7. Multiple remote candidates matching one local business key → still
   flagged as ambiguous, never auto-picked.
8. A remote-fetch failure during preview must **block** preview from
   showing any plan at all — must never silently degrade to "0 remote
   items known."
9. Pagination — multi-page remote reads still produce a correct combined
   `knownRemoteItems` set (the existing `fetchKnownRemoteItems` pagination
   logic already covers this structurally; needs a production-preview-path
   test, not just the existing internal one).
10. Malformed/undecodable response during the pre-merge read must be
    treated the same as requirement 8 (block, never silently empty).
11. Remote data changes after preview was generated but before confirm →
    confirm must reject with a clear error, not silently proceed on stale
    data (this is the confirm-time safety gate's core new test).
12. Preview must still perform **zero writes** even though it now performs
    network reads (regression test against the existing "preview performed
    zero network writes" assertion already used in the hosted smoke tests
    — must continue to pass unchanged).
13. No View ever reads a token as part of this new code path (extend the
    existing Node semantic-guard regex check).
14. With `INVENTORY_SYNC_ENABLED`/`INVENTORY_MERGE_UI_ENABLED` off, none of
    this new behavior activates (regression against existing
    feature-flag-off tests).
15. User A/B isolation — the pre-merge read must only ever return items
    within the authenticated user's own household scope; a cross-account
    isolation regression test analogous to the existing
    `testUserBHouseholdScopeNeverReceivesUserAsInventoryMutation`.
16. Household isolation — analogous cross-household regression test.
17. **Silent-duplicate regression test** — the specific scenario this
    audit surfaced: seed a remote item, create a local business-equivalent
    item with a different id, confirm, and assert **no duplicate remote
    row exists afterward** (this is the single most important new test
    this fix must add, since it directly targets the release blocker).
18. **Stale-preview regression test** — generate a preview, mutate remote
    state (e.g. via another simulated session), then attempt confirm
    against the now-stale preview and assert it is rejected with a clear
    error rather than silently succeeding.

## Severity

**Blocker** for any future production rollout (Stage 3+ per
`docs/INVENTORY_SYNC_DOGFOOD_PLAYBOOK.md`). Not a blocker for continued
**Stage 1/2 dogfood** (developer-only, small internal cohort, manual sync
only) as long as dogfood participants are aware Guest merge in its current
form does not detect pre-existing remote conflicts and could create a
duplicate if two sessions merge the same business item independently.
