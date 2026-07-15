# Inventory Sync Go / No-Go (updated Phase 2B-6; superseded by Phase 2B-7)

> **This document is superseded by `docs/INVENTORY_SYNC_FINAL_GO_NO_GO.md`**,
> which reflects Phase 2B-7's real physical-device validation (a real
> iPhone 17 Pro ran the full automated + hosted-dogfood suite for real, plus
> a genuine OS-level app-kill/relaunch). The conclusion below ("Dogfood Go /
> Production No-Go, pending physical-device validation") is now refined by
> that document to: still Dogfood Go / Production No-Go, but the remaining
> gap is narrower — only the human-gesture UI/network-toggle layer, not
> physical-device validation as a whole. Keep this file as the Phase 2B-6
> historical record; use the Phase 2B-7 doc for the current status.

## Status summary

**Implemented:**
- Diagnostics snapshot (`InventorySyncDiagnosticsSnapshot`), redacted export
- Consistency checker (`InventorySyncConsistencyChecker`, 14 read-only checks)
- Pending-mutation queue cap (`InventorySyncEligibility.blockedByQueueFull`)
- Dogfood configuration (`InventorySyncDogfoodConfiguration`, both flags default `NO`)
- Test-only fault-injection transport (`InventorySyncFaultInjectingTransport`, Phase 2B-6)
- Go/No-Go decision framework (this document)

**Simulator validated:**
- `GuestMergeTests` 99/99 (was 82; +17 this phase — fault injection, single-flight/lifecycle, scale, queue-cap-at-scale)
- Full iOS Unit 568/568 (3 safe skips; was 550)
- Full iOS UI 5/5 (1 safe skip; unchanged)
- Debug build (simulator): 0 errors
- Release build (simulator destination): 0 errors
- A real unsigned Archive built and inspected: compiled `Info.plist` confirms all 8 sync/dogfood/smoke flags `NO`; binary `strings` scan found zero test credentials, emails, or smoke markers; no `.xcconfig` content inside the bundle
- Fault injection: offline, 401, 403, 413, 429 (mapped to `.backendUnavailable`), 500/503, malformed/truncated JSON, push-applied+client-timeout, pull-succeeded+local-save-failure, app-killed-before-cleanup — all confirmed pending-retaining, cursor-safe, duplicate-safe
- Single-flight confirmed under real concurrency (`withTaskGroup`, 10 concurrent taps → exactly 1 `sendMutations` call)
- Queue-cap holds firm at 250 attempted creates against a 200 cap; deletes and coalescing still succeed under a full queue
- Scale/performance sanity checks at 1000 metadata rows / 500 pending mutations / 100 conflicts — no O(n²) hotspot found (see `docs/INVENTORY_SYNC_SCALE_RESULTS.md`)
- Node: 854/854, `npm audit --omit=dev --audit-level=high` 0 vulnerabilities, `git diff --check` clean

**Hosted development validated:**
- `npm run smoke:sync`: PASS (local Express + real development Supabase project)
- Hosted development dogfood smoke: **PASS** — real Render deployment + real development Supabase project, marker-isolated (`__inventory_dogfood_<id>`), full create/sync/update/sync/offline-stage/reconnect+sync/simulated-restart/duplicate-safe-retry/delete/sync/tombstone/diagnostics-clean/consistency-clean/cleanup flow, zero marker residue confirmed

**Production audited (read-only, no write):**
- Production config audit complete — see `docs/INVENTORY_SYNC_PRODUCTION_CONFIG_AUDIT.md`. No Blocker found; 2 pre-existing evidence gaps carried forward (sync-migration-parity re-verification, no min-app-version enforcement mechanism)

**Physical device validated:** **No.** Not attempted — no physical device
attached to this environment. Checklist prepared:
`docs/INVENTORY_SYNC_PHYSICAL_DEVICE_CHECKLIST.md`.

**Production enabled:** No. No flag was changed from its committed default.

**Current decision: Dogfood Go / Production No-Go**

## Conclusion

Inventory Sync has now cleared every evidence gap this environment can
close: fault injection, single-flight under real concurrency, scale
sanity, queue-cap pressure, a real hosted development dogfood pass, and a
clean read-only production-config/archive audit. The only remaining gate is
physical-device validation, which is structurally impossible to fabricate
here and is not claimed as done. That makes **"Dogfood Go"** — a small,
manually-executed, development-backend, flags-off-by-default dogfood
following `docs/INVENTORY_SYNC_DOGFOOD_PLAYBOOK.md` Stage 1/2 is
reasonable — while **production enablement (Stage 3+) remains No-Go** until
the physical-device checklist is actually run and passes.

## Go criteria status

| Criterion | Status |
|-----------|--------|
| 0 release blockers | ✅ met |
| Full tests pass | ✅ met — Node 854/854, iOS Unit 568/568 (4 safe skips), UI 5/5 (1 safe skip), `GuestMergeTests` 99/99, 0 regressions against the Phase 2B-5 baseline |
| Hosted development dogfood pass | ✅ met — see above |
| Physical-device dogfood pass | ❌ not performed — no device available in this environment |
| Weak-network recovery pass | ✅ met — 11 fault-injection scenarios, all pending-retaining/cursor-safe/duplicate-safe |
| App-kill recovery pass | ✅ met — simulated relaunch test confirms recovery without duplication |
| Account/household isolation pass | ✅ met |
| Scale tests no blocker | ✅ met — no O(n²) hotspot found; see scale results doc |
| Production config audit pass | ✅ met — no Blocker; 2 non-blocking evidence gaps noted |
| Archive safety pass | ✅ met — real unsigned archive inspected, clean |
| Consistency checker clean | ✅ met — 0 issues at the end of the hosted dogfood run |
| Rollback drill pass | ✅ met — see `docs/INVENTORY_SYNC_PHASE2B6_VALIDATION.md` drill table (drills C, sub-parts of J not freshly re-exercised this phase, relying on existing Phase 2B-3/2B-4 tests) |
| All flags default NO | ✅ met |
| Zero secret leak | ✅ met — test-enforced diagnostics redaction + archive binary scan |
| Rollback playbook executable | ✅ met — exercised for real during hosted dogfood cleanup |

## No-Go blocker for production (Stage 3+)

1. **Physical-device validation** (`docs/INVENTORY_SYNC_PHYSICAL_DEVICE_CHECKLIST.md`, 30 steps) — the only remaining gap. Until it passes, the correct status to report anywhere is exactly: **"simulator + hosted-development dogfood passed, physical-device validation pending"** — never "production ready" or "production enabled."

Two carried-forward, non-blocking evidence gaps (not new this phase, not
data-loss/security defects): sync-foundation migration parity was not
independently re-verified with pgTAP; no minimum-app-version enforcement
mechanism exists yet (matters once a rollout exceeds a small controlled
cohort, not for a dogfood-scale cohort).

## What must never change without a new explicit review

`INVENTORY_SYNC_ENABLED`, `INVENTORY_MERGE_UI_ENABLED`,
`INVENTORY_SYNC_DOGFOOD_ENABLED`, `INVENTORY_SYNC_DIAGNOSTICS_ENABLED`,
`GUEST_MERGE_SMOKE_ENABLED`, `SYNC_ENABLED`, `SYNC_SMOKE_ENABLED` must all
remain `NO` in every committed configuration and every Release build until
a future phase produces a Production Go conclusion here — and even then,
only for the specific rollout stage that decision covers (see
`docs/INVENTORY_SYNC_DOGFOOD_PLAYBOOK.md`'s staged criteria).
