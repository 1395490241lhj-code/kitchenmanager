# Inventory Sync Release Readiness (Phase 2B-5)

> **Phase 2B-6 update**: every "Known gap" this document lists below except
> physical-device validation has since been closed — fault injection,
> performance/scale sanity checks, the production config audit, and a real
> hosted development dogfood run are all done. See
> `docs/INVENTORY_SYNC_PHASE2B6_VALIDATION.md` and the updated
> `docs/INVENTORY_SYNC_GO_NO_GO.md` (now "Dogfood Go / Production No-Go",
> pending only physical-device validation).

## Scope

Phase 2B-5 is **not** a feature phase. It audits Inventory Sync
(Phases 2B-1 through 2B-4) for release readiness and adds the minimum
diagnostic/recovery/guardrail surface needed to run a safe, opt-in dogfood.
It does **not** enable production, does not default any flag to `YES`, does
not add automatic/background/realtime sync, and does not touch any other
module (Shopping/Today Plan/Weekly Plan/Recipe/Favorites/Frequent).

**Completion criterion**: "Inventory Sync 具备可观测、可诊断、可恢复、可灰度、可回滚的
dogfood 条件，并形成明确的 Go / No-Go 生产启用结论。" — partially met; see
[`INVENTORY_SYNC_GO_NO_GO.md`](INVENTORY_SYNC_GO_NO_GO.md) for the explicit
conclusion and the specific gaps still open.

## Audit findings

Triaged as required before any implementation. Only Blocker/necessary-High
items were fixed this phase.

| # | Area | Finding | Severity | Status |
|---|------|---------|----------|--------|
| 1 | Queue growth | `PendingMutation` staging had no cap — a long-offline device could accumulate an unbounded queue | Blocker | Fixed: `InventorySyncEligibility.blockedByQueueFull` + `InventorySyncDogfoodConfiguration.maxPendingMutations` |
| 2 | Diagnosability | No way to inspect sync state without a debugger | Blocker (for dogfood) | Fixed: `InventorySyncDiagnosticsSnapshot` + diagnostics screen |
| 3 | Consistency | No systematic way to detect metadata/pending/enrollment drift | High | Fixed: `InventorySyncConsistencyChecker` (14 checks, read-only) |
| 4 | Rollout control | No dedicated dogfood gate distinct from `INVENTORY_SYNC_ENABLED`/`INVENTORY_MERGE_UI_ENABLED` | High | Fixed: `InventorySyncDogfoodConfiguration` (`INVENTORY_SYNC_DOGFOOD_ENABLED`, `INVENTORY_SYNC_DIAGNOSTICS_ENABLED`, both default `NO`) |
| 5 | Single-flight | `syncNow`'s `guard !isSyncing else { return }` runs synchronously on `@MainActor` before the first `await` | Non-blocker | Verified sufficient by test (`testManualSyncRepeatedTapsExecuteOnlyOnce`); no new actor/gate added |
| 6 | Weak-network/error-injection coverage | No dedicated fault-injection transport for 401/403/409/413/429/500/503/malformed/truncated/slow/timeout paths | High | **Not fixed this phase** — see Known Gaps |
| 7 | Physical-device validation | Never run on a physical device this whole feature line | High (for production Go) | **Not fixed this phase** — see Known Gaps |
| 8 | Performance/scale | No test with 500–1000 items / 200–500 pending mutations | Medium | **Not fixed this phase** — see Known Gaps |
| 9 | Production config audit | Never formally reviewed | Medium | **Not fixed this phase** — see Known Gaps |
| 10 | Recovery tools | "rebuild local sync index" not built | Low/Non-blocking | Deliberately not built — existing manual retry/re-pull/re-login paths already satisfy section 十's allowed list without it |
| 11–25 | Remaining audit points (dual-context race, account/household isolation, coalescing, rollback window, etc.) | — | Non-blocking | Already covered by Phase 2B-4's own audit and tests; re-verified by rerunning the full `GuestMergeTests` suite (82/82 passing, up from 56) and the full iOS Unit suite (550/550, up from 540) with 0 regressions |

## What changed this phase

- `Config/Shared.xcconfig` / `Config/Local.example.xcconfig`: two new flags,
  both `NO` — `INVENTORY_SYNC_DOGFOOD_ENABLED`, `INVENTORY_SYNC_DIAGNOSTICS_ENABLED`.
- `InventorySyncDogfoodConfiguration.swift` (new): safe-off-by-default
  dogfood config struct. Dogfood enabling never implies automatic sync —
  `isManualSyncEnabled`/`isMergeUIEnabled` are read from the *existing*
  `INVENTORY_MERGE_UI_ENABLED`/`INVENTORY_SYNC_ENABLED` flags, not
  independently settable to true by the dogfood flag alone.
- `InventorySyncDiagnostics.swift` (new): `InventorySyncDiagnosticsSnapshot`
  (redacted, see [`INVENTORY_SYNC_DIAGNOSTICS.md`](INVENTORY_SYNC_DIAGNOSTICS.md))
  and `InventorySyncConsistencyIssue`.
- `InventorySyncConsistencyChecker.swift` (new): pure, read-only, 14-point
  check function.
- `InventorySyncEligibility.swift`: added `.blockedByQueueFull` and the
  queue-cap check (never blocks a delete, never blocks coalescing into an
  already-staged row).
- `SyncPersistence.swift`: added `allMetadata(scope:)`/`allPendingMutations(scope:)`
  read-only queries for diagnostics/consistency-checking, distinct from the
  filtered queries the coordinator uses.
- `GuestMergeController.swift`: `dogfoodConfiguration`, `showsDiagnosticsScreen`,
  `lastSyncStartedAt`/`lastSyncCompletedAt`, `diagnosticsSnapshot(...)`,
  `consistencyCheck(...)`.
- `InventorySyncDiagnosticsView.swift` (new): the dogfood-gated, read-only
  diagnostics screen, entry point at the bottom of the account page ("库存同步诊断").
- Tests: 10 new `GuestMergeTests` cases covering the queue cap, the
  consistency checker, diagnostics redaction, and single-flight.

## Known gaps (must close before Go)

These were explicitly scoped out of this phase's implementation budget and
are the reason the current conclusion is **No-Go** — see
[`INVENTORY_SYNC_GO_NO_GO.md`](INVENTORY_SYNC_GO_NO_GO.md):

- Weak-network/error-injection test suite (section 十四) not built.
- Performance/scale tests at 500–1000 items (section 十七) not run.
- Production config audit (section 十八) not performed.
- Physical-device dogfood validation (section 十三) not performed —
  **simulator-only status; physical-device validation pending.**
- Hosted development-environment dogfood smoke (section 二十四) not run.
- Feature-flag staged-rollout doc content exists in
  [`INVENTORY_SYNC_DOGFOOD_PLAYBOOK.md`](INVENTORY_SYNC_DOGFOOD_PLAYBOOK.md)
  but has not been exercised even at Stage 1.

Nothing above is a data-loss or safety regression — every flag remains `NO`,
no production write occurred, no other module was touched.
