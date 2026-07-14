# Inventory Sync Go / No-Go (Phase 2B-5)

## Status summary (updated during Phase 2B-5 final verification)

**Implemented:**
- Diagnostics snapshot (`InventorySyncDiagnosticsSnapshot`)
- Redacted diagnostics export (`redactedJSON()`)
- Consistency checker (`InventorySyncConsistencyChecker`, 14 read-only checks)
- Pending-mutation queue cap (`InventorySyncEligibility.blockedByQueueFull`)
- Dogfood configuration (`InventorySyncDogfoodConfiguration`, both flags default `NO`)
- Go/No-Go decision framework (this document)

**Validated:**
- Simulator XCTest: `GuestMergeTests` 82/82, full iOS Unit 550/550 (3 safe skips), full iOS UI 5/5 (1 safe skip)
- Debug build (simulator): 0 errors
- Release build (simulator destination): 0 errors; compiled Release `Info.plist` confirmed every `KM_*` sync/dogfood/smoke flag is `NO`
- Local automated tests: Node 845/845, `npm audit --omit=dev --audit-level=high` 0 vulnerabilities, `git diff --check` clean
- `npm run smoke:sync`: **PASS**, run against the local Express server + real development Supabase project (root cause of the earlier failure was simply that the local Express server wasn't running — not a code or data defect; see the dedicated section below)

**Pending:**
- Physical-device dogfood validation
- Hosted (multi-device / longer-duration) dogfood smoke
- Weak-network / error-injection testing
- Performance/scale testing at 500–1000 items
- Production configuration audit

**Current decision: No-Go**

## Conclusion: **No-Go** for production enablement

Inventory Sync now has a dedicated dogfood gate, a read-only diagnostics
screen, a read-only consistency checker, and a bounded pending-mutation
queue — all safe-off by default. It is **not** ready for any production
cohort (not even Stage 3) because several required validations from the
Phase 2B-5 spec were not performed this phase.

## Go criteria status

| Criterion | Status |
|-----------|--------|
| 0 release blockers | ✅ met (all identified Blockers fixed) |
| Full test pass | ✅ met — Node 845/845, 550/550 iOS Unit (3 safe skips), 5/5 iOS UI (1 safe skip), 82/82 `GuestMergeTests`, 0 regressions against the pre-2B-5 baseline (Node 836, iOS Unit 540, UI 5) |
| `npm run smoke:sync` | ✅ met — PASS once the local Express server was started (see root-cause note below); this is a local development-environment contract check, not a physical-device or production validation |
| Physical-device dogfood pass | ❌ not performed — simulator only |
| Weak-network recovery pass | ❌ not performed — no fault-injection transport built this phase |
| App-kill recovery pass | ❌ not independently re-verified this phase (relies on structural guarantee, not a fresh test) |
| Account isolation pass | ✅ met — existing + Phase 2B-5 tests confirm |
| Household isolation pass | ✅ met |
| Zero secret leak | ✅ met for the new diagnostics/export surface (test-enforced); full production-log audit not performed |
| Consistency checker no critical issues | ✅ checker built and tested; not yet run against any real dogfood data set |
| Rollback drill pass | ⚠️ partially — conflict/logout/rollback drills covered by existing tests; local-save-failed and app-kill drills not freshly re-verified |
| Production config audit pass | ❌ not performed this phase |
| Feature flags default off | ✅ met — verified via `git diff`, all new/existing flags remain `NO` |
| Clear rollback playbook exists | ✅ met — see `INVENTORY_SYNC_ROLLBACK_PLAYBOOK.md` |

## `npm run smoke:sync` root cause (resolved)

The script targets two things: the real development Supabase project directly
(via `SUPABASE_URL`/keys from the gitignored `.env.development.local`), and
the local Express sync API at `EXPRESS_API_BASE` (default
`http://127.0.0.1:3000`, i.e. `node server.js` — **not** the hosted Render
deployment). The first `fetch failed` run happened because no local Express
process was running. Starting `node server.js` locally with the development
environment variables sourced, then re-running `npm run smoke:sync`,
produced a clean **PASS** across all four of its checks (auth/RLS isolation,
CRUD/conflict/idempotency/feed/pagination, representative entity families,
and the real Express sync contract). No production endpoint, service-role
key, or bulk write was involved — the script only exercises the existing
authorized development-environment contract it always has.

## No-Go blockers to close before reconsidering

1. Physical-device validation (section 十三, 25 scenarios).
2. Weak-network/error-injection test suite (section 十四).
3. Production config audit (section 十八) — read-only review of Supabase/Render URLs, RLS, Release Info.plist, secret injection, service-role absence.
4. Performance/scale tests at 500–1000 items / 200–500 pending mutations (section 十七).
5. Hosted development-environment dogfood smoke (section 二十四).
6. A dedicated app-kill / duplicate-retry-safe drill test (currently only structurally implied, not freshly exercised).

None of the above being incomplete implies any known defect — it means the
required *evidence* for a Go decision has not yet been collected. Until it
is, the correct status to report anywhere (docs, standups, PR descriptions)
is exactly: **"simulator dogfood passed, physical-device validation
pending"** — never "production ready."

## What must never change without a new explicit review

`INVENTORY_SYNC_ENABLED`, `INVENTORY_MERGE_UI_ENABLED`,
`INVENTORY_SYNC_DOGFOOD_ENABLED`, `INVENTORY_SYNC_DIAGNOSTICS_ENABLED`,
`GUEST_MERGE_SMOKE_ENABLED`, `SYNC_ENABLED`, `SYNC_SMOKE_ENABLED` must all
remain `NO` in every committed configuration and every Release build until
a future phase produces a Go conclusion here.
