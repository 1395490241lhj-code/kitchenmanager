# Inventory Sync Production Config Audit (Phase 2B-6)

Read-only audit. No production write was made or attempted. No secret,
token, password, or full production credential is reproduced below.

## 1. Production Supabase URL injection (iOS)

`Config/Shared.xcconfig` (committed) declares `SUPABASE_URL =` and
`SUPABASE_PUBLISHABLE_KEY =` empty, then `#include? "Local.xcconfig"`
(optional, gitignored, per-developer/per-CI-runner). `Info.plist` maps these
into `KM_SUPABASE_URL`/`KM_SUPABASE_PUBLISHABLE_KEY`; `AuthConfiguration.swift`
reads them via `Bundle.main.object(forInfoDictionaryKey:)`, validates the URL
is HTTPS with a real host, rejects placeholder values, and explicitly
rejects any key containing the substring `service_role`. The publishable
(anon) key is meant to be public by Supabase's own design — its presence in
the compiled bundle is expected, not a leak.

## 2. Production Render URL injection

Hardcoded as a literal in `KitchenManager/Networking/APIEnvironment.swift`:
`https://kitchenmanager-b8px.onrender.com`, used for both `.production` and
`.development` (there is no separate staging backend today; the comment in
that file explains this explicitly). Not configurable via xcconfig/Info.plist
— changing backends requires a code change, reviewed like any other change.

## 3. Issuer / JWKS (server side)

`src/server/config.js` derives `SUPABASE_JWKS_URL`/`SUPABASE_JWT_ISSUER`
from env vars, defaulting to `${SUPABASE_URL}/auth/v1/.well-known/jwks.json`
and `${SUPABASE_URL}/auth/v1` when not explicitly overridden, with
`SUPABASE_JWT_AUDIENCE` defaulting to `authenticated`. It cross-checks issuer
and `SUPABASE_URL` share the same origin, erroring on mismatch.
`src/server/auth/jwt.js` verifies via `jose`'s `createRemoteJWKSet` against
these values — asymmetric verification, no shared secret on the client.

## 4. RLS migration consistency

`supabase/migrations/` contains 2 files: `20260713000100_auth_household_foundation.sql`
and `20260713000200_sync_business_foundation.sql`. `docs/AUTH_SYNC_PHASE0_5_VALIDATION.md`
verified remote/local parity only for the first (auth foundation); it does
not claim the same verification for the second (sync foundation) migration,
and Docker-based pgTAP was not executed in either case. **This is a
pre-existing, not-newly-introduced evidence gap** — re-verifying migration
parity end to end (ideally with pgTAP) remains open for a future phase.

## 5. Release-default feature flags

`Config/Shared.xcconfig` (the file every Release build actually uses —
`Local.xcconfig` is dev-machine-only and never present in CI/Archive unless
manually placed): `SYNC_ENABLED = NO`, `SYNC_SMOKE_ENABLED = NO`,
`SYNC_SMOKE_ENVIRONMENT =` (empty), `INVENTORY_SYNC_ENABLED = NO`,
`INVENTORY_MERGE_UI_ENABLED = NO`, `GUEST_MERGE_SMOKE_ENABLED = NO`,
`INVENTORY_SYNC_DOGFOOD_ENABLED = NO`, `INVENTORY_SYNC_DIAGNOSTICS_ENABLED = NO`.
Confirmed directly in a real (unsigned) archive build this phase — see
section "Archive inspection" below.

## 6. App Store archive / test account exclusion

No `@gmail`/`@example`/`PASSWORD`/`SERVICE_ROLE` string found in any
`.pbxproj` or `.xcscheme` file under `ios-native/Kitchen Manager`. A real
unsigned archive built this phase (`xcodebuild archive ... CODE_SIGNING_ALLOWED=NO`)
was inspected directly:
- Compiled `Info.plist` in the `.app` bundle: all 8 sync/dogfood/smoke flags
  read `NO`.
- `strings` over the compiled binary found zero occurrences of
  `service_role`, any `@gmail.com`/`@example.com` test address, the literal
  test password string used in unit tests, or any of the three smoke marker
  prefixes (`__guest_merge_smoke_`, `__inventory_crud_smoke_`,
  `__inventory_dogfood_`).
- No `.xcconfig` file (including `Local.xcconfig`) exists anywhere inside
  the compiled `.app` bundle — xcconfig is a build-setting-only file, never
  a bundled resource, by Xcode's own design.

## 7. Service-role key absence

No key material found anywhere in the iOS or server source. `service_role`/
`SERVICE_ROLE` only ever appear as: an env-var name in `src/server/config.js`
(explicitly commented as "deliberately not consumed" by the authenticated
`/api/me` path), setup-instruction prose in two docs, and negative-assertion
regexes in test files (asserting client code never contains it).

## 8. Production logging redaction

`server.js` logs only non-secret startup diagnostics (trust-proxy setting,
auth config host/JWKS-host/issuer/audience/algorithm summary, Node
version) via plain `console.log`. No `morgan` or request/response-body
logging middleware is present; no Authorization-header logging found near
auth or sync routes. `scripts/sync-smoke.mjs`'s own `redact()` helper
additionally strips any `Bearer <token>` and JWT-shaped substrings before
ever printing a failure message.

## 9. `Local.xcconfig` archive-safety

`project.pbxproj`'s `baseConfigurationReference` points only at
`Shared.xcconfig`; `Local.xcconfig` is never itself a project member — it's
pulled in solely via `#include? "Local.xcconfig"` inside `Shared.xcconfig`,
which silently no-ops if the (gitignored) file is absent. Confirmed above:
zero `.xcconfig` content ends up inside the compiled `.app`.

## 10. Diagnostics compile-isolation

The diagnostics screen (`InventorySyncDiagnosticsView.swift`) is compiled
into every configuration (Debug and Release both build it — it's not
`#if DEBUG`-gated at the file level), but it is runtime-gated by
`GuestMergeController.showsDiagnosticsScreen`, itself driven by
`INVENTORY_SYNC_DOGFOOD_ENABLED` + `INVENTORY_SYNC_DIAGNOSTICS_ENABLED`
both being `YES` — both `NO` in every committed configuration and confirmed
`NO` in the real archive build this phase. It is reachable in a Release
build only if a future build explicitly flips both to `YES`, which would be
a deliberate, reviewable, visible xcconfig change — not something Debug/
Release compilation alone determines. (The hosted-smoke/fault-injection
test *code* itself, by contrast, is genuinely Debug/test-target-only and
cannot compile into a Release app binary at all — see
`docs/INVENTORY_SYNC_FAULT_INJECTION.md`.)

## 11. Production feature-flag rollback method

Documented in `docs/INVENTORY_SYNC_ROLLBACK_PLAYBOOK.md`: every gate is an
independent xcconfig flag; rollback is "set the flag(s) back to `NO` and
rebuild/redistribute" — no server-side state change is required, since
staged `PendingMutation`/`SyncMetadata` rows are left as-is (never
physically deleted) by a rollback.

## 12. Production cohort enablement method

Documented in `docs/INVENTORY_SYNC_DOGFOOD_PLAYBOOK.md`'s Stage 0–5 table —
each stage is a `Local.xcconfig`/build-configuration change for a specific
cohort, never a remotely-toggleable flag and never a percentage-based
remote rollout mechanism (no such mechanism exists in this codebase).

## 13. Production data cleanup / rollback playbook

`docs/INVENTORY_SYNC_ROLLBACK_PLAYBOOK.md` and
`docs/INVENTORY_SYNC_DOGFOOD_PLAYBOOK.md` both specify marker-based cleanup
(soft-delete only, via the authorized user-level sync API, never a physical
delete or service-role bypass) — exercised for real this phase via the
hosted dogfood smoke's own cleanup step and the `cleanup-guest-merge-smoke-markers.mjs`
sweep script.

## 14. Backend deployment / version compatibility

Both iOS `.production` and `.development` `APIEnvironment` cases resolve to
the same single Render deployment (see item 2) — there is no version-skew
risk between "the iOS app's idea of production" and "the iOS app's idea of
development" today, since they're the same backend. This also means there
is currently no tested path for an iOS client running against an *older*
deployed backend version; that risk is out of scope until a second backend
environment exists.

## 15. Schema migration compatibility

`InventorySyncEnrollment.currentSchemaVersion` and the diagnostics
snapshot's `schemaVersion` field exist specifically to let a future
consistency check detect a client/server schema mismatch, but no explicit
migration-compatibility test was run this phase beyond the existing
migration-parity check in item 4.

## 16. Minimum app version strategy

No minimum-supported-app-version enforcement mechanism exists in the
client or server today (no version gate in `server.js`, no forced-update
check in the iOS app). This is a pre-existing gap, not introduced by
Inventory Sync — any future gradual rollout beyond a small controlled
cohort would need one, since there is currently no way to force an old
client off an incompatible sync contract.

## Conclusion

No Blocker-level production-config issue was found. Two evidence gaps carry
forward as open items for a future phase (not defects): (a) migration-parity
verification for the sync-foundation migration specifically, and (b) no
minimum-app-version enforcement mechanism exists yet, which matters more
once a rollout exceeds a small controlled cohort.
