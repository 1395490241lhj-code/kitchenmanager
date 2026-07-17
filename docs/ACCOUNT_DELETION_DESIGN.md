# Account Deletion Design (Phase 2D-2)

Status: **designed, backend implemented, iOS UI implemented, local/offline
tests passing, local Docker-based Supabase validation passing. Not
validated against the real hosted development Supabase project (no
`SUPABASE_SERVICE_ROLE_KEY` is configured in this environment — see §7).
No production Supabase project exists to validate against. Not an App
Store submission requirement closure until the items in §11 are also
resolved.**

## 1. Original account lifecycle audit (before this phase)

- **Registration**: Supabase Auth email/password sign-up
  (`SupabaseAuthService`); `handle_new_auth_user()` trigger creates one
  `profiles` row, one personal `households` row, and one `owner`
  `household_members` row atomically and idempotently.
- **Sign-in**: Supabase Auth email/password; session stored via the
  `supabase-swift` SDK's own Keychain-backed storage
  (`KeychainLocalStorage`, service `com.lianghongjing.kitchenmanager.auth`,
  storage key `kitchenmanager.auth.session`) — this app defines no
  additional Keychain schema of its own.
- **Sign-out**: `AuthStore.signOut()` calls the SDK's `client.auth.signOut()`
  (invalidates the session server-side, clears the SDK's own Keychain
  entry) then clears only `AuthStore`'s in-memory state (`session`,
  `status`, `account`, `accountMessage`). **It does not touch any
  SwiftData** — `SyncMetadataRecord`, `PendingMutationRecord`,
  `SyncCursorRecord`, or any domain persistence record. This is
  intentional per existing `CODING_RULES.md` ("login/logout must not
  auto-upload, clear, or switch local kitchen data").
- **SwiftData**: three sync-bookkeeping `@Model` types
  (`SyncMetadataRecord`, `PendingMutationRecord`, `SyncCursorRecord`) plus
  `GuestMergeSessionRecord` and `InventorySyncEnrollmentRecord`; domain
  models (inventory, shopping, today-plan, consumption, weekly-plan, user
  recipes) are separate persistence stores, shared between Guest and
  signed-in use — sign-in/out never distinguishes "whose" local row a
  given item is.
- **Supabase Auth user record**: exists in `auth.users`; `profiles.id`
  references it `on delete cascade`.
- **`household_members`**: composite PK `(household_id, user_id)`, `role
  in ('owner','admin','member')` — a real owner concept, enforced at the
  RLS level (see §5).
- **Household ownership**: exactly the `role='owner'` row(s) in
  `household_members` — no separate `households.owner_id` column.
  `households.created_by` only records who created it historically, never
  used for authorization.
- **`inventory_items` (and the other 6 household-scope business tables)**:
  owned by `household_id`, attributed by `created_by`/`updated_by` — both
  were `on delete restrict` against `profiles` before this phase (see §7).
- **`sync_changes`**: the change feed; `changed_by` was also `on delete
  restrict` before this phase.
- **`sync_mutations`**: the idempotency ledger, keyed `(user_id,
  mutation_id)`.
- **Guest merge / rollback session**: `GuestMergeSessionRecord` (local
  SwiftData) — rollback is documented (§`docs/RLS_SECURITY_VERIFICATION.md`)
  as an ordinary delete mutation through the same `apply_sync_mutation`
  RPC, not a separately tracked server-side entity.
- **Diagnostics**: `InventorySyncDiagnostics`/`InventorySyncDiagnosticsView`
  — local-only, no server component found.
- **Receipts/recipes/shopping/planning**: all 7 household-scope business
  tables plus `user_recipes` are household-owned; `recipe_favorites`/
  `frequent_recipes` are personal (`user_id`-scoped).
- **A separate personal `profiles` table**: yes, distinct from
  `auth.users`.
- **Server-side account-deletion endpoint**: **did not exist** before this
  phase.
- **Supabase Auth admin delete usage**: **did not exist** before this
  phase; `SUPABASE_SERVICE_ROLE_KEY` was parsed/validated at backend
  startup but functionally unused anywhere (confirmed by grep across
  `src/server/`).
- **In-app deletion entry point**: **did not exist**.
- **Data export**: does not exist (out of scope for this phase).
- **Retention policy / deletion waiting period**: not defined before this
  phase — see §13 for what's now defined (an immediate-deletion strategy
  was chosen, not a waiting-period one — see §4).
- **Re-authentication requirement**: did not exist.
- **Multi-person household ownership transfer**: **did not exist** —
  added this phase (`transfer_household_ownership` RPC, §5).
- **Last-owner-deletion problem**: **existed as a real, unhandled gap**
  before this phase — `household_members_delete_for_managers`'s RLS
  policy already blocked deleting any `role='owner'` row via ordinary
  client DML (by design), but nothing handled what should happen when the
  owner is the one being removed. This phase closes it (§5).
- **Was "sign out" ever conflated with "delete account"?** No — confirmed
  by reading `AuthStore.swift`; the existing sign-out UI copy already says
  "退出登录不会删除本机的库存、计划、购物清单或菜谱" (sign-out does not
  delete local data), correctly distinct from deletion.
- **Could "clear local data" delete server-side data?** No such feature
  existed before this phase — `KitchenStore.clearAllLocalData()` (used
  now by successful account deletion, see §10) only ever touches local
  SwiftData, never calls any network endpoint.
- **Could old tokens access data after deletion?** Before this phase: N/A
  (no deletion existed). After this phase: an already-issued JWT is
  rejected by Supabase's own token verification once the Auth user row is
  gone (a Supabase Auth guarantee, not something this app re-implements);
  during the window between business-data cleanup and Auth deletion, the
  sync-freeze guard (§12) independently blocks `/api/sync/*` regardless of
  token validity.
- **Could a pending mutation replay after deletion?** Addressed directly —
  see §12.
- **Can the local app safely return to Guest mode after deletion?** Yes —
  validated by `AccountDeletionControllerTests` (real `AuthStore`, real
  in-memory SwiftData, asserting `.guest` status and empty domain data
  after a successful confirm).

## 2. Deletion semantics — five distinct actions, never merged

| Action | Deletes remote account? | Deletes remote household data? | Deletes local data? | Where |
|---|---|---|---|---|
| **A. Sign Out** | No | No | No (user's choice, not automatic) | Existing `AuthStore.signOut()` — unchanged |
| **B. Clear Local Data** | No | No | Yes, local SwiftData/cache/diagnostics only | Existing `KitchenStore.clearAllLocalData()` — unchanged, reused as a building block |
| **C. Leave Household** | No | No (household continues for remaining members) | No | `request_account_deletion`'s membership-departure path applies this same logic when the actor isn't the sole owner — a **standalone** "leave household" UI entry point (separate from account deletion) is **not built this phase**; the underlying safe primitive (`household_members` row removal without deleting the household) already exists correctly in the RLS-governed schema and is exercised by the account-deletion flow, but no dedicated non-owner "leave household" button exists yet in the UI — flagged as a real, separate follow-up, not silently assumed done |
| **D. Delete Account** | Yes | Only households the actor owned *alone* (no other members) — see §5 | Yes, automatically, only on real success | New this phase — full design below |
| **E. Delete Household** | N/A | Yes, all of it | N/A | **Not implemented this phase** — the architecture doesn't strictly require it for account deletion to work correctly (see §5's "owner deletes alone" case, which reuses the same household-delete SQL path but only ever as a side effect of the *owner's own* account deletion, never as a standalone "delete this household while keeping my account" action) |

Only D is a new, user-facing feature this phase. C's underlying safety
(no orphaned ownership) is proven by the same code path D uses, but no
separate "Leave Household" button exists in the UI yet — a real,
explicitly acknowledged gap, not a silent omission.

## 3. Why deletion needed a two-step saga, not one transaction

Supabase Auth (`auth.users`) is owned by GoTrue, which also manages
sessions, identities, and refresh tokens in tables this application does
not control. Deleting `auth.users` via raw SQL from a `SECURITY DEFINER`
Postgres function would bypass that cleanup and is not a supported
pattern; the only correct way to delete an Auth user is the Admin API
(`DELETE /auth/v1/admin/users/{id}`), which requires the service-role key
— a credential that must never reach iOS and must stay backend-only
(confirmed: `AuthConfiguration.swift` already runtime-rejects any key
containing `"service_role"`, and grep confirms
`SUPABASE_SERVICE_ROLE_KEY` was previously unused anywhere in
`src/server/`).

Since the Admin API call cannot participate in the same Postgres
transaction as the business-data cleanup, deletion is a two-step saga:

1. **`request_account_deletion`** (SQL RPC, user's own JWT) — one atomic
   transaction: validates the preview is still fresh, resolves ownership
   (§5), deletes/anonymizes business data (§9), and marks the ledger row
   `business_data_cleaned`.
2. **Express backend, service-role credential** — calls the Auth Admin
   API to delete the user, then calls the service-role-only
   `mark_account_deletion_finalized` RPC to record the outcome.

If step 2 fails (network blip, transient Admin API error), step 1's work
is **not lost or repeated** — the ledger row already shows
`business_data_cleaned`, and a retry (same `idempotencyKey`) skips
straight to attempting step 2 again. If the Auth user was already deleted
by a prior attempt whose response was lost, the Admin API call returns
404, which is treated as success (idempotent), not a failure.

**What's retryable/idempotent**:
- Step 1: fully idempotent by `(user_id, idempotencyKey)` — a duplicate
  call with the same key returns the same result without re-running the
  cleanup (verified in `supabase/tests/account_deletion_test.sql` and
  `test/account-deletion-phase2d2.test.mjs`).
- Step 2: idempotent by treating "user already gone" (404) as success;
  `mark_account_deletion_finalized` itself re-validates the idempotency
  key before writing.

## 4. Deletion strategy comparison and recommendation

| Option | App Store compliance | GDPR/PIPEDA-style principles | Household collaboration | Recoverability | Complexity | Stage-1 feasible (no background worker)? |
|---|---|---|---|---|---|---|
| 1. Immediate hard delete of Auth user + all data | Meets Guideline 5.1.1(v) directly | Strong (no retained personal data) | Breaks other members' households if not handled first | None | Medium | Yes, if ownership is resolved first |
| 2. Immediate identity deletion, anonymized business data | Meets 5.1.1(v) | Strong (identity removed; remaining data is non-identifying) | Preserved (shared households keep functioning) | None for the deleted user; households/data survive for others | Medium-high (anonymization logic) | **Yes — chosen** |
| 3. Soft delete + 7/14/30-day recovery window | Meets 5.1.1(v) only if the window is disclosed and short | Weaker (personal data lingers deliberately) | Preserved | Yes, within the window | High (needs a scheduled sweep — a background worker) | **No** — this phase explicitly has no background worker |
| 4. Mark-deleted + async background cleanup | Meets 5.1.1(v) eventually | Weaker until cleanup runs | Preserved | Limited | High | **No** — same reason as 3 |
| 5. Force "leave all households" first, then delete | Meets 5.1.1(v) | Strong | Requires a separate, earlier user action | None | Lower, but worse UX (two steps, and leaving alone doesn't resolve orphaned ownership) | Yes, but strictly worse than option 2 |

**Recommendation: Option 2 — immediate, synchronous, atomic deletion of
the identity, with business data anonymized (not deleted) where other
members still depend on it, and deleted outright where it's exclusively
personal.** This is what's implemented. Rationale:

- Meets the App Store's account-deletion requirement directly and
  immediately — no disclosed waiting period to manage or explain in
  Review Notes.
- Never requires a background worker, matching this project's explicit
  Stage-1 constraint and existing architecture (no scheduled jobs exist
  anywhere in this codebase).
- Preserves shared households and their sync history for *other* members
  — deleting a household just because one member left would be
  destructive and surprising to the people who didn't ask for it.
- The mutation ledger, tombstones, and change feed all continue to work
  unmodified for surviving data — anonymization only rewrites attribution
  columns, never the sync protocol's own invariants (version, cursor,
  tombstone semantics are all untouched).
- Token revocation is immediate and real (the Auth user genuinely stops
  existing), not merely a client-side flag.

## 5. Household ownership rules (implemented)

Schema fact (audited, not assumed): ownership is `household_members.role
= 'owner'`; there is no `households.owner_id` column. RLS already
prevented an ordinary client from ever deleting an owner's own membership
row (`household_members_delete_for_managers` explicitly excludes
`role='owner'`), so all of the rules below are enforced by new
`SECURITY DEFINER` functions, not by relaxing that RLS policy.

1. **Non-owner may leave**: `request_account_deletion`'s membership
   cleanup simply deletes the actor's own `household_members` row when
   they aren't the sole owner — no special-casing needed.
2. **Owner with other members must transfer first**:
   `private.account_deletion_preview` sets `requiresOwnershipTransfer =
   true` whenever the actor owns a household that has any other member;
   `request_account_deletion` re-checks this at confirm time (not just at
   preview time) and rejects with `OWNERSHIP_TRANSFER_REQUIRED` if still
   true.
3. **Owner alone may proceed**: `requiresHouseholdDeletion = true` in that
   case, and confirming deletion also deletes that household (cascading
   its business rows via the existing `household_id … on delete cascade`
   foreign keys — no new cascade logic needed).
4. **No zero-owner household**: guaranteed structurally — a solely-owned
   household is deleted outright (removing the whole row, not just the
   owner), and a household with other members can only reach this code
   path after a transfer already assigned it a new distinct owner.
5. **No multi-owner state introduced**: `transfer_household_ownership`
   promotes the new owner and demotes the caller to `admin` in the same
   function call/transaction — verified in
   `supabase/tests/account_deletion_test.sql`
   ("exactly one owner remains after transfer").
6. **Ownership transfer is transactional**: the whole function body is
   one implicit Postgres transaction (function, not procedure) — a crash
   mid-way rolls back entirely.
7. **User A cannot transfer User B's household**: `transfer_household_ownership`
   requires `private.has_household_role(p_household_id, actor,
   array['owner'])` where `actor = auth.uid()` — there is no code path
   that accepts an arbitrary caller-supplied "acting as" id.
8. **Non-member cannot receive ownership**: the function requires
   `private.is_household_member(p_household_id, p_new_owner_user_id)`
   before promoting — a pending invitation (this schema has none today)
   or an arbitrary UUID cannot be promoted.
9. **Deletion never crosses into another household's data**: every query
   in `request_account_deletion` is scoped by `actor`'s own membership
   rows or by `household_id`s the actor's own `household_members` rows
   name — there is no household-id parameter accepted from the client at
   all.
10. **Household data deletion is explicit and auditable**: the
    solely-owned-household deletion path is a single, readable `DELETE …
    WHERE h.id IN (SELECT …)` statement (see the migration file); nothing
    about it is implicit or scattered.

## 6. Backend API (implemented)

- `POST /api/account/delete/preview` — returns the coarse, non-identifying
  summary defined in `docs/ACCOUNT_DATA_LIFECYCLE.md` §"Preview response
  fields."
- `POST /api/account/list-transfer-candidates` — `{ householdId }` →
  `{ members: [{ userId, role, displayName }] }`, owner-only, used to
  populate the iOS ownership-transfer picker (existing `profiles` RLS
  would otherwise hide other members' display names from a plain client
  read).
- `POST /api/account/transfer-ownership` — `{ householdId, newOwnerUserId }`.
- `POST /api/account/delete/reauthenticate` — `{ confirmationVersion }` → a
  short-lived one-use proof, only after Express verifies the Supabase-signed
  recent password-authentication AMR claim for the current user.
- `POST /api/account/delete/confirm` — `{ idempotencyKey,
  confirmationVersion, reauthenticationProof }` → `{ status: "completed" |
  "auth_deletion_pending" }` or a `4xx` with one of the error codes below.

All four require the same `authenticateRequest` + `createRequireAuthRole
(['authenticated'])` middleware every other authenticated route uses, and
a dedicated rate limiter (`ACCOUNT_DELETION_RATE_LIMIT_MAX = 10` per
window, keyed `userId:IP` exactly like `/api/me`'s limiter).

**Error codes** (exactly as suggested, implemented as-is):
`OWNERSHIP_TRANSFER_REQUIRED`, `HOUSEHOLD_ACTION_REQUIRED`,
`ACCOUNT_DELETION_REAUTH_REQUIRED`, `ACCOUNT_DELETION_REAUTH_FAILED`,
`ACCOUNT_DELETION_REAUTH_EXPIRED`, `STALE_DELETION_PREVIEW`,
`ACCOUNT_DELETION_IN_PROGRESS`, `ACCOUNT_DELETION_BLOCKED` (generic
fallback used only if the SQL layer ever returns an error code this
Express layer doesn't specifically recognize — never fabricated).
`ACCOUNT_DELETION_FAILED` is reserved for a true internal-error fallback
in `sendAccountDeletionError` but is not itself a code the SQL layer
emits.

**Confirm never returns raw database errors** — `AccountDeletionError`
always maps to one of the above or a generic
`account_deletion_rpc_failed`/`account_deletion_network_error`/etc.,
matching the existing `SyncError`/`SyncRepositoryError` pattern in this
codebase.

## 7. Supabase Auth deletion boundary

- iOS ships **only** the anon/publishable key — confirmed both by
  `AuthConfiguration.swift`'s existing runtime guard (rejects any key
  containing `"service_role"`) and by this phase's own service layer
  (`APIAccountDeletionService`/`AccountDeletionController` never reference
  a service-role value; `test_confirmDeletionNeverLogsOrLeaksTheAccessTokenInTheRequestBody`
  and related tests assert the access token — a much weaker secret than
  service-role — never leaks into a request body).
- The service-role key is used in exactly **one** place in the entire
  backend: `createSupabaseAccountDeletionAdmin` (this phase, new) — never
  for ordinary business reads, matching `CODING_RULES.md`'s "never use a
  service-role key in the PWA or iOS app" and extending it to "never use
  it for anything but this one privileged admin operation" on the
  backend.
- **Order**: business-data cleanup (step 1) always happens *before* the
  Auth user is deleted (step 2) — this is what makes step 1 retryable
  using the still-valid actor JWT; deleting the Auth user first would
  invalidate that JWT before cleanup could run.
- **"business data deleted but Auth user still exists"**: recoverable —
  the ledger row is `business_data_cleaned`, and a retry of confirm
  re-attempts only step 2 (step 1 is a no-op given the same idempotency
  key and an already-`business_data_cleaned` status).
- **"Auth deleted but business data still identifiable"**: cannot happen
  by construction — step 2 never runs before step 1 has already reported
  `business_data_cleaned`.
- **Not validated this phase**: the real Admin API call against the
  actual hosted development Supabase project — `SUPABASE_SERVICE_ROLE_KEY`
  is not present in this environment's `.env.development.local` (checked
  directly, not assumed). The full saga *was* validated end-to-end,
  including a real `auth.users` row deletion and its cascade, against the
  local Docker-based Supabase instance (which does have a usable local
  service-role key by default) — see `docs/PHASE2D2_VALIDATION.md` §4.

## 8. Database migration

New migration:
`supabase/migrations/20260716000100_account_deletion_lifecycle.sql`
(does not modify either prior migration file). See
`docs/ACCOUNT_DATA_LIFECYCLE.md` for the full anonymization design and
`docs/PHASE2D1_VALIDATION.md`-style validation record in
`docs/PHASE2D2_VALIDATION.md`.

## 9. Reauthentication

The only enabled provider is Supabase email/password. iOS asks the user to
re-enter the active account password and sends it directly to Supabase using
`supabase-swift`; Express never receives, logs, or persists it. The resulting
Supabase-signed JWT carries a password `amr` timestamp. Express accepts it
only when it is recent (five minutes) and not older than the current deletion
preview, then issues a process-local five-minute proof bound to that user and
preview fingerprint. Confirm consumes that proof exactly once, including on a
failed/replayed attempt. Since a token refresh retains the original AMR time,
it cannot bypass this requirement. A restart loses outstanding proofs and
therefore fails closed. OAuth/OTP providers are not enabled; if added later,
they must receive provider-native reauthentication or account deletion must
return `ACCOUNT_DELETION_REAUTH_UNSUPPORTED`.

## 10. Sync safety (implemented)

1. **Frozen after deletion starts**: `createAccountDeletionSyncGuard`
   middleware (Express layer, alongside version-gate/rate-limit) blocks
   `/api/sync/*` with `423 ACCOUNT_DELETION_IN_PROGRESS` whenever
   `account_deletion_requests.status` is `requested`,
   `business_data_cleaned`, or `auth_deletion_pending` for the caller.
2. **Pending mutations don't continue uploading**: enforced by the same
   guard — a queued client mutation hits 423 before ever reaching
   `apply_sync_mutation`.
3. **In-flight requests**: not explicitly cancelled client-side (no
   request-cancellation token exists in `ExpressSyncTransport` today) —
   an in-flight request either completes just before the guard takes
   effect (harmless, ordinary mutation) or is rejected by the guard if it
   arrives after; there is no window where a mutation writes *during*
   `request_account_deletion`'s own transaction, since that transaction
   holds an advisory lock and Postgres's own transaction isolation
   prevents interleaving.
4. **Delete-account endpoint bypasses the normal mutation ledger**:
   correct by construction — `request_account_deletion` never calls
   `apply_sync_mutation`.
5. **Bootstrap no longer sees old households**: once membership rows are
   removed, `get_sync_bootstrap` (unchanged) naturally returns an empty
   household list for that user — no special-casing needed.
6. **Old cursor cleared**: `AccountDeletionController.clearAllSyncState()`
   deletes every `SyncCursorRecord` on successful completion.
7. **Merge preview cleared**: deletes every `GuestMergeSessionRecord`.
8. **Rollback session cleared**: same call (rollback has no separate
   record type — see §1).
9. **Stale task cannot resurrect a session**: `AuthStore.signOut()` runs
   last in the success path, after local sync state is already gone — an
   app relaunch after a killed-mid-cleanup process re-derives its state
   fresh from Keychain/SwiftData, never a stale in-memory task.
10. **App relaunch never auto-retries an old mutation**: `PendingMutationRecord`
    rows are wiped before sign-out; there is nothing left to retry.
11. **Other devices' old tokens**: invalidated by Supabase Auth itself the
    moment the Auth user row is gone — this app doesn't re-implement
    token revocation.
12. **Sync recoverable if deletion fails**: the guard only blocks while
    status is one of the three in-progress values; a `failed` status (not
    currently ever set by this implementation — see the open item in
    `docs/ACCOUNT_DELETION_RUNBOOK.md`) or no row at all allows sync
    through normally.
13. **Guest local functionality after success**: proven directly by
    `AccountDeletionControllerTests.test_confirmSuccessClearsSyncStateAndLocalDataAndSignsOut`
    — `authStore.status == .guest` and `kitchenStore.inventory.isEmpty`
    after a real success.

## 11. What is NOT done this phase (explicit)

- OAuth/provider support beyond the current email/password flow — any newly
  enabled provider must gain provider-native reauthentication or return a
  stable unsupported error before account deletion. Hosted validation remains
  required before External TestFlight or App Store submission.
- A standalone "Leave Household" UI entry point for non-owners (the safe
  primitive exists in SQL; no separate button was built).
- A standalone "Delete Household" feature independent of account deletion.
- Data export.
- Validation against the real hosted development Supabase project (no
  service-role credential available in this environment) or any
  production project (none exists).
- Any retry/finalize automation — a stuck `auth_deletion_pending` state
  today only resolves via a client re-confirm or a manual operator action
  (see `docs/ACCOUNT_DELETION_RUNBOOK.md`), since there is no background
  worker in this Stage-1 architecture.
