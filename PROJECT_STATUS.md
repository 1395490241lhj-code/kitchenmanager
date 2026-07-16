# Kitchen Manager — Current Project Status

Last updated: 2026-07-16

This is the single current-state snapshot for humans and AI agents. It is
not a changelog and must remain concise. Implementation detail, test-count
history, device-validation narratives, and bug investigations belong in
`CHANGELOG.md` and the focused documents under `docs/`.

## Current release state

- **Production Go Candidate With Conditions.** Feature-correctness blockers
  for Inventory Sync / Guest Merge are closed and physical-device-validated;
  the surrounding operational readiness is not.
- All sync/merge/dogfood/diagnostic/smoke feature flags remain `NO` in
  every committed configuration and every Release build.
- **Not Production Enabled** — no production cohort, no production Supabase
  project, no production monitoring, and no distribution pipeline exist yet.

## Completed

- Native iOS SwiftUI app with SwiftData persistence for the core kitchen
  modules (inventory, shopping, today plan, consumption, weekly plan, user
  recipes), alongside the original Web/PWA surface (no build pipeline,
  `localStorage`-backed).
- Guest-first email/password auth, Keychain session restore, and
  authenticated `/api/me` household loading (Supabase + Express); sign-in
  never clears/uploads/reassigns local Guest data.
- Inventory sync foundation: authenticated bootstrap/pull/mutation APIs,
  household/user scope separation, idempotency ledger, optimistic version
  conflicts, soft-delete tombstones and change feed.
- Guest inventory merge: remote preview, explicit per-conflict choices,
  identity forking for keep-both, manual sync, rollback, diagnostics, and a
  bounded mutation queue.
- Conflict UI and Rollback both re-validated against a physical device.
- Minimum-app-version enforcement gate for `/api/sync/*` (server + iOS
  client), fail-closed on misconfiguration.
- `/api/sync/*` rate limiting (read + mutation limiters, per-user), backed
  by an in-memory store explicitly scoped to Stage-1 single-instance use.
- Crash-reporting abstraction (iOS `CrashReporting` protocol, event/metadata
  allowlists, no-op default provider) and basic backend observability
  (structured JSON logging, request-correlation id, in-process sync
  metrics, `/health` and `/ready`), all offline-tested and validated against
  a locally-run instance of the code pointed at the real development
  Supabase project.
- Production Supabase topology decision: separate dev+prod project
  recommended; shared project accepted for Stage 1 only (no production
  project created). Migration history and schema/RLS/RPC shape re-verified
  read-only against the development project; environment-misconnection
  safety guards added on both iOS and backend.

## Remaining rollout conditions

1. A real crash-reporting SDK is not integrated — only the abstraction and
   a selected future provider (Sentry) exist; no DSN, no real event has ever
   been sent anywhere.
2. Production monitoring/alerting is not live — alert rules are documented,
   no provider/dashboard is connected, nothing pages anyone.
3. No production Supabase project exists yet — the topology decision is
   made (separate dev+prod recommended), but provisioning it requires
   explicit future approval and must happen before Stage 2.
4. Local Docker-based pgTAP execution remains undone (environment
   limitation — no Docker available). Remote schema/RLS parity and real
   A/B behavioral isolation are otherwise re-confirmed against dev.
5. No TestFlight/App Store Connect distribution pipeline exists.
6. The sync rate limiter needs a shared/multi-instance store (Redis/Upstash
   or equivalent) before GA — today's in-memory store is Stage-1-only.
7. A consent/opt-out UI and privacy-label decision for crash reporting is
   not yet designed — deferred until a real provider is chosen, since the
   no-op provider sends nothing.

## Next recommended phase

Provision the separate production Supabase project (topology already
decided) and close the local Docker-based pgTAP execution gap — both are
prerequisites, independent of further engineering work, before any real
crash-reporting SDK or shared rate-limit store is worth configuring. Only
after those, build the TestFlight pipeline and wire a real
crash-reporting/alerting provider. Feature expansion to additional
synchronized entities should not jump ahead of this operational readiness
work.
