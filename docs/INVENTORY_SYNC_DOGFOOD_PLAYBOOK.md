# Inventory Sync Dogfood Playbook (Phase 2B-5)

## What dogfood mode is — and isn't

Turning on `INVENTORY_SYNC_DOGFOOD_ENABLED` (+ `INVENTORY_SYNC_DIAGNOSTICS_ENABLED`)
only unlocks a read-only diagnostics screen and confirms the existing manual
paths (`INVENTORY_MERGE_UI_ENABLED`, `INVENTORY_SYNC_ENABLED`) are on. It
never turns on automatic sync, a timer, a background task, or realtime — the
only network call an end-to-end dogfood session ever makes is the user
tapping "立即同步库存" or the diagnostics screen's "重试手动同步", exactly like
today's ordinary manual-sync button.

## Preconditions for enrolling a device in dogfood

- `INVENTORY_SYNC_ENABLED`, `INVENTORY_MERGE_UI_ENABLED`,
  `INVENTORY_SYNC_DOGFOOD_ENABLED`, `INVENTORY_SYNC_DIAGNOSTICS_ENABLED` all
  set to `YES` in `Config/Local.xcconfig` (gitignored, never committed).
- A development-environment backend only (`KM_SYNC_SMOKE_ENVIRONMENT=development`).
  `allowHostedWrites` on `InventorySyncDogfoodConfiguration` requires this.
- A test account, never a real production account.
- Isolated marker data (`__inventory_dogfood_<short-id>`), never real
  personal inventory (section 十三's requirement — no test data has been
  fabricated for a real user's account under any circumstance).

## Staged rollout (documented, not yet executed beyond Stage 0)

| Stage | Audience | Backend | Sync mode | Entry criteria | Exit criteria | Rollback criteria |
|-------|----------|---------|-----------|-----------------|----------------|--------------------|
| 0 | Nobody | — | All flags `NO` | — | — | Current state |
| 1 | Individual developer | Dev | Manual only | Full regression green, dogfood config compiles safe-off | 1+ week no Blocker found | Any Blocker |
| 2 | Internal dogfood (small test accounts) | Prod-like | Manual only | Stage 1 exit criteria + weak-network + performance tests added | 2+ weeks, 0 data-loss/duplicate/scope incidents | Any data-loss, duplicate create, or scope leak |
| 3 | Small production cohort | Prod | Merge UI + manual sync | Stage 2 exit + physical-device validation + production config audit clean | Error/conflict/rollback rates within target for 2+ weeks | Rate regression, any secret leak |
| 4 | Expanded cohort | Prod | Manual sync | Stage 3 exit criteria | Stable rates at higher volume | Same as Stage 3 |
| 5 | General availability | Prod | Manual sync (still no automatic sync unless a future phase explicitly proposes and gets sign-off) | Stage 4 exit + explicit Go decision in `INVENTORY_SYNC_GO_NO_GO.md` | — | Documented in rollback playbook |

Each stage's monitoring fields and data-cleanup plan reuse the existing
diagnostics snapshot fields (pending/conflict/failed counts,
`lastSyncResult`) plus the consistency checker's issue list — no new
telemetry pipeline was introduced this phase.

## Hosted development-environment dogfood smoke

**Status: PASS (Phase 2B-6).** The full sequence (create → sync → update →
sync → offline stage → reconnect+sync → simulated restart → duplicate-safe
recovery → delete → sync → tombstone → diagnostics snapshot →
consistency-checker-clean → zero marker residue) ran for real against the
development Supabase project and the real Render deployment, using marker
prefix `__inventory_dogfood_<id>` via
`GuestMergeSmokeRunner.runInventoryDogfoodMinimalSmoke` /
`HostedGuestMergeSmokeTests.testControlledDevelopmentInventoryDogfoodSmoke`.
Ran with the development backend only; `INVENTORY_SYNC_DOGFOOD_ENABLED`/
`INVENTORY_SYNC_DIAGNOSTICS_ENABLED`/`INVENTORY_SYNC_ENABLED`/
`GUEST_MERGE_SMOKE_ENABLED` were set to `YES` only in the gitignored
`Local.xcconfig` for the duration of the run and restored to `NO`
immediately after. Every marker row was soft-deleted (never physically
deleted); `scripts/cleanup-guest-merge-smoke-markers.mjs`'s
`MARKER_PREFIXES` now includes `__inventory_dogfood_` and a post-run sweep
confirmed zero residual rows. No account id, UUID, token, or password was
printed to any log. See `docs/INVENTORY_SYNC_PHASE2B6_VALIDATION.md`.

## Physical-device validation

**Status: simulator + hosted-development dogfood passed, physical-device
validation pending.** This exact wording must be used in any future
doc/report until a physical device actually completes the 30-step checklist
in `docs/INVENTORY_SYNC_PHYSICAL_DEVICE_CHECKLIST.md`. No physical device
was attached to the environment Phase 2B-6 ran in, so this step could not
be executed or faked — the checklist is ready for whoever has device
access next.
