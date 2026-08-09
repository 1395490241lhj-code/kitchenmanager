# Monitoring & Alerting — Stage 1 Minimum (Phase 2C-2)

Status: **rules defined and documented; no alert provider is wired up; no
alert has ever fired in production, because no production cohort exists**.
This document defines what *should* alert once a real monitoring/alerting
provider is chosen (still an open blocker — see `PROJECT_STATUS.md` §5) — it
is a design document, not a live dashboard.

Every rule below is computable from data this phase actually emits: the
structured `http_request` log lines and the named metrics in
`src/server/observability/metrics.js` (see `docs/BACKEND_OBSERVABILITY.md`).
None of them require a metrics backend that doesn't exist yet — they can be
implemented as log-search alerts (e.g. Render's own log search, or whatever
provider is chosen) directly against these JSON lines.

## P1 — page immediately

| Rule | Source | Threshold | Window | Owner | Response | Rollback trigger |
| --- | --- | --- | --- | --- | --- | --- |
| Backend 5xx rate | `backend_5xx` metric / `http_request` `status>=500` count | >10% of all requests | 5 min | On-call backend engineer | Check Render logs for the failing route; if isolated to sync, consider disabling the affected feature flag client-side (see `docs/PRODUCTION_ROLLBACK_RUNBOOK.md`) | Yes — halt the active rollout stage |
| Unexpected mutation rejected/conflict spike | `sync_mutation_rejected` / `sync_mutation_conflict` | Rate materially above the stage's known baseline (no fixed number yet — Stage 1 has no production baseline) | 15 min | On-call backend engineer | Inspect whether a client-side bug is sending malformed/stale mutations | Yes, if isolated to one client version |
| Rollback failure (internal cohort) | Client-side `rollback_failed` breadcrumb, or `sync_mutation_*` on a rollback-shaped request | >0 for the internal test cohort | Any | Feature owner | Investigate immediately — rollback failing is exactly the "can't undo" scenario the whole feature exists to avoid | Yes |
| Consistency checker failure | Client-side `consistency_check_failed` breadcrumb | >0 | Any | Feature owner | Pull the affected device's diagnostics export; do not auto-fix | No (informational escalation, not a rollout halt by itself) |
| Auth/JWT validation widespread failure | `http_request` `authState=invalid` rate on `/api/sync/*` and `/api/me` | Sudden spike across many distinct requests | 5 min | On-call backend engineer | Check Supabase JWKS reachability / issuer config (`/ready`'s `auth_config`/`supabase_connectivity` checks) | Yes, if `/ready` also fails |
| `/ready` continuous failure | `/ready` endpoint | 3 consecutive failed checks | 5 min | On-call backend engineer | Treat as the process itself being unready to serve sync traffic | Yes |

## P2 — investigate same business day

| Rule | Source | Threshold | Window | Owner | Response | Rollback trigger |
| --- | --- | --- | --- | --- | --- | --- |
| Sync success rate | `sync_request_success` / `sync_request_total` | <95% | 15 min | Feature owner | Check which route/error code dominates the failures | Possibly, depending on cause |
| 429 rate (internal cohort) | `sync_rate_limited` metric | >5% of requests for the internal cohort | 15 min | Feature owner | Check whether the client is retry-looping instead of respecting `Retry-After` | No — confirm client backoff first |
| Unexpected 426 spike | `sync_upgrade_required` metric | Any spike outside a deliberate minimum-version bump | 15 min | Feature owner | Check `MIN_IOS_*` config wasn't accidentally changed | Yes, if the config change was accidental |
| p95 sync write latency | `sync_write_latency` observations | >3s | 15 min | Backend engineer | Check Supabase/RPC latency, not just Express | No |
| Pending mutation age | Client-side diagnostics export (no server-side signal exists for this) | >30 min unresolved | N/A (device-reported) | Feature owner | Investigate why a device's pending queue isn't draining on manual sync | No |
| Crash-free session rate | Not measurable this phase (no crash-reporting provider wired in — see `docs/CRASH_REPORTING.md`) | Below threshold, once measurable | N/A | Feature owner | N/A until a provider is integrated | N/A |

## P3 — track, no immediate action

| Rule | Source | Threshold | Window | Owner | Response | Rollback trigger |
| --- | --- | --- | --- | --- | --- | --- |
| Orphaned session detected | Client-side `InventorySyncConsistencyChecker` (existing, pre-Phase-2C-2) | >0 | Any | Feature owner | Review during next diagnostics pass | No |
| Stale preview spike | Client-side preview-invalidation rate (no dedicated metric this phase) | Noticeably elevated vs. baseline | N/A | Feature owner | Check whether household inventory is changing unusually fast | No |
| Marker residue | Manual/scripted check (existing smoke-cleanup tooling) | >0 after any smoke run | Per-run | Whoever ran the smoke | Clean up via exact-ID soft-delete, never a bulk/prefix delete | No |
| Retry rate elevated | `sync_request_total` re-attempts of the same route/user in a short window (no dedicated metric; derivable from `http_request` log lines) | Noticeably elevated vs. baseline | 15 min | Feature owner | Check for a client retry-storm bug | No |

## What this phase does NOT provide

- No alert provider (PagerDuty, Opsgenie, Slack webhook, etc.) is
  configured. These rules are ready to wire into one once chosen.
- No dashboard exists. All of the above are derivable from Render's raw log
  search today; a real dashboard is a GA condition, not a Stage-1
  requirement.
- No on-call rotation exists yet — "owner" above names a role
  (feature owner / backend engineer), not a specific person or paging
  target.
- Thresholds without a numeric baseline (marked "no fixed number yet" above)
  are placeholders to be tightened once real Stage 1 traffic exists — do not
  treat them as tuned production values.
