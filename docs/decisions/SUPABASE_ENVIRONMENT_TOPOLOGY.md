# Supabase Environment Topology (Phase 2C-3)

Status: **topology decision made; no production project created; no
production config changed.** This document records the current topology,
the options considered, and the recommendation — it does not create,
configure, or switch to any new Supabase project.

## 1. Current topology (as audited this phase)

- **One** Supabase project exists in total. It is used for local
  development, every hosted-development validation to date (Phase 2A
  through 2C-2), and is the only project any script, the Express backend,
  or the iOS app has ever pointed at.
- No separate production project exists.
- `APIEnvironment.swift` (iOS) resolves both `.production` and
  `.development` to the *same literal Render backend URL* — a deliberate,
  documented decision from before this phase, not a bug introduced now.
- The backend (`server.js`/`src/server/config.js`) reads `SUPABASE_URL`,
  `SUPABASE_ANON_KEY`, `SUPABASE_JWKS_URL`, `SUPABASE_JWT_ISSUER`,
  `SUPABASE_JWT_AUDIENCE` from environment variables only — none are
  hardcoded in tracked source. `SUPABASE_SERVICE_ROLE_KEY` exists as a
  config value but is never consumed by the ordinary `/api/me` or
  `/api/sync/*` request path (RLS always applies via the user's own JWT).
- `.env.development.local` (gitignored) and the Render dashboard's own
  environment variables are the only two places real values exist; `.env.example`
  contains placeholders only (`YOUR_PROJECT_REF`, etc.).
- `SUPABASE_ENVIRONMENT` is an existing, already-tested convention
  (`scripts/verify-supabase-phase0.mjs`'s `ensureDevelopmentTarget`) that
  every write-capable script (`auth-smoke.mjs`, `sync-smoke.mjs`,
  `cleanup-guest-merge-smoke-markers.mjs`) already calls before doing
  anything against a remote database: it fails closed unless the target
  host is a loopback address or `SUPABASE_ENVIRONMENT` is explicitly one of
  `development`/`dev`/`test`/`local`/`staging`. An unset or `production`
  value is refused. This existed before Phase 2C-3 and was re-verified this
  phase (see `docs/PHASE2C3_VALIDATION.md`).
- There is no `environment` enum/abstraction at the *Supabase project*
  level (as opposed to the Express `NODE_ENV`/logging label added in Phase
  2C-2) — nothing today asserts "this SUPABASE_URL is the expected project
  for this environment," because there is only one project to be right or
  wrong about.
- **Misconnection risk today**: low in practice (only one project exists,
  so there is nothing to misconnect *to*), but the safety net that would
  matter once a second project exists is only partially built — see §5.
- Smoke/test markers (`__inventory_crud_smoke_*`, guest-merge-smoke rows)
  are created only against whatever project `SUPABASE_ENVIRONMENT` allows,
  which today is always the single dev project — there is no scenario yet
  where they could reach a distinct "production" project, since none
  exists.
- The migration commands (`supabase migration list`, `supabase db query
  --linked`) operate against whatever project the Supabase CLI is linked to
  (`supabase/.temp/project-ref`, gitignored, local-machine state) — there is
  no separate confirmation step before a destructive command; today this is
  low-risk only because a single project exists and every command used in
  this repository's scripts is read-only or additive-with-cleanup.
- Verifying link status: `npx supabase migration list` succeeds only
  against a project the CLI is actually linked to and reachable; this was
  used this phase as a safe, read-only confirmation (see
  `docs/DATABASE_MIGRATION_PARITY.md`).
- No production-deploy approval gate exists in this repository — Render
  deployment is managed entirely through Render's own dashboard, outside
  version control (unchanged from `docs/PRODUCTION_ENABLEMENT_READINESS.md`'s
  earlier finding).

## 2. Topology options considered

| Dimension | A. Shared project | B. Separate dev + prod | C. Dev + staging + prod |
| --- | --- | --- | --- |
| Data isolation | None — dev/test writes and real user data coexist | Full | Full, plus a rehearsal tier |
| Migration risk | A migration mistake affects real data immediately | Migrations validated on dev before ever touching prod | Migrations rehearsed twice before prod |
| RLS testing | Tested against the same data real users will eventually share | Tested in isolation, no risk to real data | Same as B, plus a staging rehearsal |
| Smoke marker pollution | Already happens today (accepted for Stage 1 only) | Impossible — smoke never targets prod | Impossible |
| Real user data safety | Weakest — a test script bug could touch real rows | Strong — physically separate database | Strongest |
| Rollback | Any rollback risks affecting real users | Rollback on dev is risk-free | Rollback rehearsed on staging first |
| Incident containment | An incident and a test-script bug are indistinguishable | Clean containment boundary | Cleanest |
| Cost | One project | Two projects (Supabase has a free tier per project) | Three projects |
| Operational complexity | Lowest | Moderate — one more set of secrets/config to manage | Higher — a third environment to keep in sync |
| Render config | One backend config | Two backend deployments (or one backend, env-switched) | Three |
| iOS config | One `APIEnvironment` case, already trivial | `APIEnvironment` gains real divergence | Same, plus a staging case |
| TestFlight | Would test against real user data if ever used broadly | Can safely target dev/staging | Can safely target staging |
| App Store | Would ship pointing at the dev/test project — unacceptable | Ships pointing at the real prod project | Same |
| pgTAP | No behavioral risk difference (pgTAP runs locally, never against a live project) | No difference | No difference |
| Seeded test accounts | Already exist in the one project (TEST_USER_A/B) | Stay on dev only, never touch prod | Stay on dev only |
| Backup/restore | One project's backup covers everything, mixing test and real data | Prod backup is clean of test data | Same, plus staging as a restore rehearsal target |
| Auditability | Hard to distinguish test activity from real activity | Clear | Clearest |
| Future multi-tenant scale | Does not scale past a handful of trusted testers | Scales to a real production cohort | Scales further, useful once release cadence/compliance needs a rehearsal tier |

## 3. Recommendation

**B. SEPARATE DEV + PROD PROJECT RECOMMENDED**, as the target topology —
with **A (shared project) explicitly accepted, but only as a bounded,
temporary exception scoped to Stage 1** (internal test accounts only, per
`docs/PRODUCTION_ROLLOUT_PLAN.md`).

Reasoning specific to this project's actual current scale:

- Stage 1's entire user base is two known internal test accounts controlled
  by the same operator who also runs the smoke scripts — the marginal risk
  of a shared project for *this specific, bounded* cohort is low and
  already the accepted status quo (see
  `docs/PRODUCTION_ENABLEMENT_READINESS.md`'s Stage-1 entry conditions).
- A third (staging) tier is not justified yet: there is no compliance
  driver, no multi-region requirement, and no release cadence complex
  enough to need a rehearsal environment distinct from "dev" itself — dev
  already serves that rehearsal role today (every migration and RPC change
  is validated there first). Introducing a third project now would add
  real operational cost (a third set of secrets, a third Render config, a
  third place migrations must be kept in sync) without a concrete problem
  it solves at this scale.
- A separate production project becomes **mandatory**, not optional, the
  moment Stage 1 graduates to any cohort beyond the two known internal
  test accounts — i.e., before Stage 2 in `docs/PRODUCTION_ROLLOUT_PLAN.md`.
  Real user data must never share a database with smoke-test markers and
  seeded test accounts.

### Direct answers (per the decision framing this phase requires)

- **Can Stage 1 continue on the current dev project?** Yes — this is the
  accepted, bounded exception described above.
- **When must a production project be created?** Before any cohort beyond
  the two known internal test accounts is onboarded (i.e., before Stage 2).
  This phase does **not** create it — that requires the user's explicit
  future approval.
- **Which project should TestFlight connect to?** The current dev project,
  for as long as TestFlight distribution serves Stage 1/2 (internal/limited
  testers) — never the eventual production project until testers are real
  users whose data must be isolated.
- **Which project should an App Store build connect to?** The separate
  production project, once it exists — an App Store build must never point
  at the dev project, since it would then be indistinguishable from a real
  user's account.
- **Which environment should smoke tests run against?** Always dev — this
  is already enforced by `ensureDevelopmentTarget` in every write-capable
  script, and this phase re-verified that guard still holds (see
  `docs/PHASE2C3_VALIDATION.md`).
- **How to prevent environment misconnection?** The existing
  `ensureDevelopmentTarget` fail-closed allowlist (backend scripts) plus the
  new `APIEnvironment.isSafeForCurrentBuildConfiguration` guard (iOS, Phase
  2C-3) — see `docs/DATABASE_MIGRATION_PARITY.md` and the iOS changes in
  this phase's commit for detail. Once a genuinely separate production
  project exists, both guards should be extended to assert the *specific*
  expected project/host, not just "a safe-looking one."

## 4. What this phase explicitly does NOT do

- Does not create a production Supabase project.
- Does not modify the Supabase dashboard.
- Does not modify Render's production environment.
- Does not change the iOS backend URL.
- Does not commit any real key/project ref.
- Does not execute a destructive migration.
- Does not reset any remote database.
- Does not enable any production flag.
