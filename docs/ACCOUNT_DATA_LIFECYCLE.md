# Account Data Lifecycle (Phase 2D-2)

Status: **defined and implemented per `supabase/migrations/20260716000100_account_deletion_lifecycle.sql`
and `src/server/account/*`. Not validated against a real hosted/production
Supabase project — see `docs/ACCOUNT_DELETION_DESIGN.md` §7.**

This document does not promise "immediately purged from every backup" —
see §"Retention & backups" for what's actually true.

## 1. Data processing matrix (real ownership model, not a blanket "delete everything")

| Data | Treatment on account deletion | Why |
|---|---|---|
| Supabase Auth user (`auth.users`) | Deleted via Admin API (saga step 2) | Only supported way to remove GoTrue-owned identity/session state |
| `profiles` row | Cascades from the Auth user delete (`on delete cascade`) | 1:1 with the Auth user; nothing else should reference it once gone |
| `household_members` (actor's own rows) | Deleted | Membership is inherently personal; no other row depends on it existing |
| Household the actor **owned alone** | Deleted (cascades all its business rows via `household_id … on delete cascade`) | No one else has any claim to it |
| Household the actor **owned with others**, or was a plain member/admin of | Survives untouched, minus the actor's own membership row | Other members' access, data, and sync history must not be collateral damage |
| `inventory_items`/`shopping_items`/`today_plan_items`/`consumption_records`/`weekly_meal_plans`/`weekly_meal_plan_items`/`user_recipes` in a surviving household | Row survives; `created_by`/`updated_by` set to `NULL` if they pointed at the actor | The data belongs to the household, not to any one member; NULL (not a fabricated id) is the honest "no longer attributable" value the relaxed FK now permits |
| `recipe_favorites`/`frequent_recipes` (personal, `user_id`-scoped) | Deleted outright | Exclusively the actor's own data; no one else will ever read it |
| `sync_changes` (household-scope rows) | Row survives; `changed_by` set to `NULL`; the historical JSONB `record_data` snapshot's `created_by`/`updated_by` keys are rewritten to a shared, non-resolvable placeholder UUID (`00000000-0000-0000-0000-000000000000`) | The change feed itself is business-consistency data other members' sync depends on; only the personally-identifying attribution is removed. A **shared** placeholder (not a per-deletion-unique one) is used deliberately — a unique value could itself become a correlation key across which historical entries belonged to the same deleted user; a shared constant cannot |
| `sync_changes` (personal-scope rows, `user_id = actor`) | Deleted outright | Exclusively the actor's own change history; no one else ever reads it |
| `sync_mutations` (idempotency ledger, keyed by `user_id`) | Deleted outright | Personal to the actor; retaining it serves no future purpose once the actor can never submit another mutation |
| Guest merge / rollback session (`GuestMergeSessionRecord`, local SwiftData) | Cleared on-device on successful deletion | Local-only bookkeeping tied to the now-deleted account |
| Local SwiftData (sync bookkeeping: `SyncMetadataRecord`/`PendingMutationRecord`/`SyncCursorRecord`) | Cleared on-device on successful deletion | Prevents a stale pending mutation from ever being retried against data that no longer exists server-side |
| Local domain data (inventory, shopping, plans, recipes) | Cleared on-device on successful deletion via the existing `KitchenStore.clearAllLocalData()` | Matches the explicit step in the account-deletion flow (distinct from ordinary sign-out, which deliberately does *not* clear this) |
| Keychain session | Cleared via the existing `AuthStore.signOut()` call, invoked last in the success path | Standard sign-out behavior, reused rather than duplicated |
| Diagnostics (`InventorySyncDiagnostics`) | Local-only; cleared incidentally as part of local SwiftData/domain clearing where it's stored there; nothing server-side to clean up | No server component was found for this feature |
| Crash breadcrumbs | Never contain personal identity — this codebase's crash-reporting abstraction only ever logs a `userHash` (irreversible sha256 prefix), never a raw id, and only when a real provider is eventually integrated (still a no-op today) | No change needed; already designed this way in Phase 2C-2 |
| Backend request logs | Redacted (allowlist logger, `userHash` only) and subject to whatever retention the hosting provider (Render) applies — this project does not run its own log retention/rotation policy | Nothing new to build; already true from Phase 2C-2 |
| Receipts | No separate receipt storage exists in this schema beyond `inventory_items`/`user_recipes` entries created from receipt import — covered by the household-owned row treatment above | Receipts aren't a distinct entity type in the sync contract |
| Recipes/favorites | `user_recipes` is household-owned (see above); `recipe_favorites`/`frequent_recipes` are personal (deleted outright) | Matches each table's actual `household_id` vs. `user_id` scoping |
| Shopping/planning | `shopping_items`/`today_plan_items`/`weekly_meal_plans`/`weekly_meal_plan_items` are all household-owned (see above) | Same |
| Test/smoke markers (`GUEST_MERGE_SMOKE_ENABLED`-style data) | Unaffected — this feature has no interaction with the existing smoke-marker cleanup scripts | Out of scope; different subsystem |

## 2. Preview response fields (exact shape, never more)

```json
{
  "canDelete": true,
  "blockingReason": null,
  "householdCount": 1,
  "ownedHouseholdCount": 0,
  "requiresOwnershipTransfer": false,
  "requiresHouseholdDeletion": false,
  "pendingMutationCountBucket": "0",
  "confirmationVersion": "<sha256 hex>"
}
```

Never returned: household id/name, inventory or recipe content, email,
a full/raw database row, or a token. `pendingMutationCountBucket` is a
coarse bucket (`"0" | "1-10" | "11-100" | "100+"`) computed from the
*server's* `sync_mutations` ledger row count for the actor — it is a
diagnostic approximation, not a live count of the device's own local
pending queue (the server has no visibility into that).

## 3. Retention & backups (no unfulfillable promises)

- **`account_deletion_requests` row**: retained indefinitely today (no
  automatic purge exists) — it contains no raw email, no token, and no
  content snapshot, only status/timestamps/a coarse anonymized-actor
  marker and the (non-secret) idempotency key/fingerprint. Kept as an
  audit trail of "a deletion happened," not personal data.
- **Backend request logs**: retained per Render's own hosting-provider
  defaults; this project does not layer its own retention/rotation
  policy on top (unchanged from Phase 2C-2's own documented posture).
- **`sync_mutations`/`sync_changes` anonymization**: applied immediately
  and synchronously as part of the same transaction that reports
  `business_data_cleaned` — not a scheduled/eventual job.
- **`userHash` (crash/log correlation)**: irreversible (sha256, truncated)
  by construction — once a deletion occurs, no code path exists to map
  that hash back to the (now-deleted) user id, since nothing stores the
  original id alongside the hash for later reversal.
- **Supabase's own database backups / PITR** (Point-In-Time Recovery, if
  ever enabled on a real project): **this document makes no promise that
  deleted data is immediately purged from every backup.** A managed
  Postgres backup/PITR window (whatever the hosting provider's actual
  retention period is, once a real production project exists) could
  still contain the pre-deletion state until that backup itself expires
  or is rotated out — this is normal for any managed database and is
  disclosed honestly rather than glossed over. **This project has no
  production Supabase project yet**, so no real backup retention period
  can even be stated today; this must be documented for real once one is
  provisioned.
- **How a user requests further deletion**: not built this phase (no
  contact-form/support-ticket flow exists in this codebase) — the
  `docs/APP_STORE_METADATA_TEMPLATE.md` Support URL is the only channel
  today, and it's a placeholder, not yet live.
- **Review-notes-facing language**: must say "your account and
  identifiable data are deleted immediately from our live database;
  backups are retained per our infrastructure provider's standard policy
  and are not immediately purged" once a real production project and
  backup policy exist — never "all data is immediately and permanently
  erased from all systems everywhere."
