# Production Rollout Plan (Inventory Sync / Guest Merge)

This is a design document — no flag has been changed as part of writing it.
It refines and supersedes the Stage 0–5 sketch in
`docs/INVENTORY_SYNC_DOGFOOD_PLAYBOOK.md` (kept for history) with the
outcomes of Phase 2B-9/2B-9B and the gaps found in
`docs/PRODUCTION_ENABLEMENT_READINESS.md`.

**Mechanism reminder**: there is no remote/percentage-based rollout system
in this codebase. Every stage below is a `Local.xcconfig`/build-configuration
change applied to a specific, known set of devices — never a
server-toggleable flag, never automatic.

> **Phase 2C-1 update**: `SYNC_VERSION_ENFORCEMENT_ENABLED` +
> `MIN_IOS_APP_VERSION`/`MIN_IOS_BUILD`/`MIN_IOS_CLIENT_SCHEMA`, and the
> `/api/sync/*` rate limiter, are now implemented and validated (see
> `docs/MINIMUM_APP_VERSION_ENFORCEMENT.md`/`docs/SYNC_API_RATE_LIMITING.md`).
> Both are backend-side env vars, not client build flags — they can be
> turned on for Stage 1 without a new iOS build, though the client itself
> must already be sending the version headers (true as of this phase,
> unconditionally, regardless of any flag) for the version gate to ever see
> anything but a 426.

## Stage 0 — Baseline (current state)

- **Flags**: all `NO` (`INVENTORY_SYNC_ENABLED`, `INVENTORY_MERGE_UI_ENABLED`,
  `INVENTORY_SYNC_DOGFOOD_ENABLED`, `INVENTORY_SYNC_DIAGNOSTICS_ENABLED`,
  `GUEST_MERGE_SMOKE_ENABLED`, `SYNC_ENABLED`, `SYNC_SMOKE_ENABLED`).
- **Users**: nobody.
- **Monitoring**: none needed.
- **Stop condition**: N/A.
- **Rollback**: N/A.
- **Data cleanup**: N/A.

## Stage 1 — Internal test accounts only

- **Flags to enable**: `INVENTORY_SYNC_ENABLED`, `INVENTORY_MERGE_UI_ENABLED`.
  `INVENTORY_SYNC_DOGFOOD_ENABLED`/`INVENTORY_SYNC_DIAGNOSTICS_ENABLED` also
  `YES` on the operator's own device only, for visibility.
- **User scope**: the two existing `TEST_USER_A`/`TEST_USER_B` accounts,
  installed via direct `devicectl` sideload only. No real personal account.
- **Backend**: the current shared dev/prod Supabase project (no separate
  production project exists yet — see readiness review §1).
- **Entry criteria**: this review's Conditions 1–5 addressed or explicitly
  risk-accepted by a human decision-maker (rate limiting on sync routes,
  min-app-version gate, minimal crash reporting, pgTAP/parity
  re-verification, and the shared-vs-separate-project decision).
- **Monitoring**: manual — read the on-device diagnostics screen
  (`InventorySyncDiagnosticsSnapshot`) after each session; no fleet
  aggregation exists yet, so this stage is inherently hands-on.
- **Exit criteria**: 1+ week, zero Blocker-severity finding, all of Phase
  2B-9B's regression suite still green.
- **Stop condition**: any data loss, any false-success report, any crash,
  any secret appearing on-screen/in a log.
- **Rollback action**: flip both flags back to `NO`, rebuild, reinstall.
  No server-side action required — see `docs/PRODUCTION_ROLLBACK_RUNBOOK.md`.
- **Data cleanup**: soft-delete any test marker via the existing
  authenticated exact-entity-ID method; never a prefix sweep, never
  physical delete.

## Stage 2 — Small canary cohort

- **Flags**: same as Stage 1.
- **User scope**: a small number (single digits) of real, consenting
  accounts — first cohort with genuinely personal (not test-marker)
  inventory data.
- **Entry criteria**: Stage 1 exit criteria met, **plus** Condition 6 from
  the readiness review substantially in place (at minimum: sync
  success/failure rate and crash rate visible somewhere a human actually
  looks, even if manually aggregated rather than a full dashboard).
- **Monitoring**: see `## Monitoring & alerting` below — at minimum sync
  success rate, mutation failure rate, and crash rate must be trackable
  per-cohort, not just per-device-on-demand.
- **Exit criteria**: 2+ weeks, 0 data-loss/duplicate-create/scope-leak
  incidents, rates within target (see thresholds below).
- **Stop condition**: any data-loss, duplicate creation, or scope leak;
  any rate regression beyond threshold.
- **Rollback action**: flip flags to `NO` for the affected cohort's
  devices; investigate before re-enabling for anyone.
- **Data cleanup**: same exact-entity-ID discipline; at this stage data is
  real personal inventory, so cleanup is a last resort, never routine.

## Stage 3 — Broader dogfood

- **Flags**: same, expanded device count.
- **User scope**: a larger internal/opt-in dogfood population.
- **Entry criteria**: Stage 2 exit criteria, **plus** Condition 7
  (a real distribution pipeline — TestFlight or equivalent — since
  sideloaded installs do not scale past a handful of known devices).
- **Monitoring**: full metrics list below should be live by this stage.
- **Exit criteria**: stable rates at higher volume, 2+ weeks.
- **Stop condition**: same as Stage 2, plus any TestFlight-specific
  distribution failure.
- **Rollback action**: same mechanism; at this volume, prefer disabling
  `INVENTORY_MERGE_UI_ENABLED` first (stops new merge starts) before
  `INVENTORY_SYNC_ENABLED` (stops all sync), to let in-flight sessions
  finish cleanly where possible.
- **Data cleanup**: as above.

## Stage 4 — Production general availability

- **Flags**: same, all users.
- **Entry criteria**: Stage 3 exit criteria, **plus** an explicit Go
  decision recorded in `docs/INVENTORY_SYNC_FINAL_GO_NO_GO.md` (a human
  sign-off, not an automatic outcome of this document).
- **Monitoring**: full metrics list below, with alerting thresholds active,
  not just dashboards someone might look at.
- **Stop condition**: same as above, evaluated at production scale.
- **Rollback action**: see `docs/PRODUCTION_ROLLBACK_RUNBOOK.md` in full.
- **Data cleanup**: exact-entity-ID discipline remains permanent policy —
  never a prefix sweep or broad delete, at any stage, ever.

## Monitoring & alerting (design — no telemetry pipeline exists yet)

None of the following currently has a live dashboard or alert channel. This
table is the target design; today, the closest equivalent for most rows is
manually reading the per-device diagnostics screen.

| Metric | Suggested threshold | Alert level |
|---|---|---|
| Sync success rate | < 98% over 1h | Warning; < 95% | Critical |
| Mutation failure rate (non-conflict) | > 2% over 1h | Warning; > 5% | Critical |
| Conflict rate | > 10% of merge sessions | Warning (investigate matching logic, not necessarily a bug) |
| Rollback rate | > 5% of completed sessions | Warning (may indicate confusing UX, not necessarily a bug) |
| Stale-preview rejection rate | > 15% | Warning (may indicate preview screen shown too long before confirm) |
| Duplicate detection (business-key collisions post-merge) | any > 0 | Critical — should be structurally impossible per design |
| Orphaned session count (sessions stuck `.completed` past their rollback window, never rolled back or expired cleanly) | any > 0 sustained > 24h | Warning |
| Pending mutation age (oldest `PendingMutation` per user) | > 1h | Warning; > 24h | Critical |
| Backend 4xx rate | > 5% of sync requests | Warning |
| 426 (upgrade-required) rate | any sustained rate > 0 once a real minimum is configured | Warning — indicates real users on an outdated build, not necessarily a bug |
| 429 (rate-limited) rate | any sustained rate > 0 | Warning — the Phase 2C-1 thresholds (120 read / 5min, 40 mutation requests + 500 operations / 5min, per user) are a starting point; a real, legitimate user tripping them repeatedly means the threshold itself needs revisiting, not that the user is malicious |
| Backend 5xx rate | > 1% of sync requests | Critical |
| Latency (p95, sync mutation round trip) | > 2s | Warning; > 5s | Critical |
| Crash rate | any sustained increase over baseline | Critical (no crash reporting exists yet — this row cannot be measured until one is integrated) |
| Marker/test residue (post-test cleanup verification) | any > 0 after a documented test round | Warning — must be investigated before the next round |
| Data consistency failures (`InventorySyncConsistencyChecker` issues) | any > 0 | Critical — this checker already exists and runs on-demand; it should be run automatically, not just when a diagnostics screen is opened |

## What this plan deliberately does not do

- Does not enable any flag.
- Does not implement a remote feature-flag service, percentage rollout, or
  A/B testing framework — none exists, and building one is out of scope
  for this review.
- Does not decide the shared-vs-separate-Supabase-project question — that
  is a product/cost/business decision for a human, not this review.
