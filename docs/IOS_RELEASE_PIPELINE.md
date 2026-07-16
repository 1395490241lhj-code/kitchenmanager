# iOS Release Pipeline (Phase 2D-1)

Status: **environment matrix and build-configuration policy designed;
version/build-number tooling implemented and tested; CI workflow added
(archive-validation only, no upload, no real Apple secrets). Not yet used
for a real release.**

## 1. Release environment matrix

There are only **two** Xcode build configurations (`Debug`/`Release`) —
this phase deliberately does not add `Internal`/`AppStore` configurations
(see §2 for why). "Environment" below is a *distribution channel*
(who receives the build and how), not a new Xcode configuration; every
channel maps onto the existing Debug/Release pair plus feature-flag state.

| | Debug | Internal TestFlight | External TestFlight | App Store |
| --- | --- | --- | --- | --- |
| Xcode configuration | Debug | Release | Release | Release |
| API base URL | Shared dev/prod Render URL (see below) | Same | Same, until a separate backend exists | **Must be the separate production backend once one exists** |
| Supabase environment | The one existing development project | Same | Same, until a separate project exists | **Must be the separate production project once one exists** |
| Feature flags | All `NO` by committed default (a developer's gitignored `Local.xcconfig` may turn sync on locally) | All `NO` in the archived build's committed config | All `NO` | All `NO` |
| Crash reporting | Disabled (no-op) | Disabled (no-op) — no real DSN exists yet | Disabled (no-op) | Disabled (no-op) — must be revisited once a real provider is integrated |
| Logging level | Verbose (Xcode console) | Same as Release everywhere — no separate "verbose Release" build exists | Same | Same |
| Version enforcement | Disabled by default (backend-side `SYNC_VERSION_ENFORCEMENT_ENABLED`) | Same — backend-side, not client-configuration-dependent | Same | Same |
| Rate limiting | Backend-side, applies identically regardless of client build | Same | Same | Same |
| Diagnostics UI / dogfood screens | Reachable only if the archiving machine's `Local.xcconfig` enabled them — **the committed config never does** | Must be `NO` in the archived build (enforced by `scripts/ios-archive-guard.mjs`) | Must be `NO` | Must be `NO` |
| Debug menus | None exist in this codebself today | N/A | N/A | N/A |
| Test accounts | Developer's own dev Supabase test accounts, if signed in | Same test accounts acceptable — internal, trusted testers only | **Must not rely on unstable dev-only test accounts** | N/A — real users, real accounts only |
| Privacy behavior | Same code path everywhere — Guest-first, no tracking, no ATT | Same | Same | Same |

### Explicit topology decision for this phase

Only **one** Supabase project and **one** backend deployment exist today
(see `docs/SUPABASE_ENVIRONMENT_TOPOLOGY.md`). Given that:

- **Internal TestFlight may continue connecting to the current
  development backend** — this mirrors the already-accepted "shared
  project for Stage 1 only" exception from Phase 2C-3, extended to a
  small, known, trusted internal tester cohort (the same population as
  today's sideloaded dogfood testers).
- **External TestFlight is blocked by default** until a genuinely separate
  production (or at minimum staging) backend exists. Widening distribution
  beyond internal testers means losing the "small, known cohort" property
  that makes sharing the dev project acceptable — real, less-trusted
  testers should not be able to pollute or depend on dev-project data.
- **App Store submission must wait for the separate production Supabase
  project.** An App Store build reaching the general public must never
  share a database with test/dev accounts and smoke-test markers.
- **Fail-closed build configurations**: since there is currently no
  distinct production backend URL to switch to, there is nothing to "fail
  closed" against yet at the client level beyond what already exists (the
  loopback guard from Phase 2C-3, `APIEnvironment.isSafeForCurrentBuildConfiguration`).
  Once a genuinely separate production host exists, that guard must be
  extended to also reject a Release build whose resolved host isn't the
  known production host — tracked as a follow-up, not implemented
  speculatively against a host that doesn't exist yet.
- **Preventing an App Store build from ever reaching localhost/dev**:
  today this is moot (there is only one backend), but the policy going
  forward is: the production backend URL will live in a value substituted
  at Release-archive time (not committed in placeholder form pointing at
  anything reachable), and `scripts/ios-archive-guard.mjs` will gain a
  check asserting the resolved Release host matches the known production
  host once that host exists.

## 2. Build configuration decision

**Kept the existing Debug/Release pair** rather than adding
`Internal`/`AppStore` configurations, because:

- Every meaningful difference between "Internal TestFlight" and "External
  TestFlight" and "App Store" in the matrix above is **data** (which
  backend, which flags) already externalized into `Shared.xcconfig`/
  `Local.xcconfig`, not something that needs a distinct Xcode
  configuration to express.
- Two configurations keep `xcodebuild -showBuildSettings`,
  `-configuration Release`, and every existing script/test/CI invocation
  from earlier phases working unchanged — adding configurations now would
  require touching a large number of already-working, already-tested
  invocations for no functional gain at this project's current scale.
- If a genuinely separate production backend is provisioned later and the
  team decides a build-time (not just run-time) distinction is worth it,
  revisit this decision then — the safeguards below don't depend on which
  approach is chosen.

### Fail-closed guarantees already in place

1. `Config/Shared.xcconfig` (committed) has every feature flag/DSN/URL
   blank or `NO` — a fresh checkout with no `Local.xcconfig` builds with
   everything safely off.
2. `Config/Local.xcconfig` stays gitignored — a real developer's local
   overrides (including any real dev Supabase URL) never enter a Release
   archive built from a clean checkout unless that specific machine's
   `Local.xcconfig` is present, which `scripts/ios-archive-guard.mjs`
   cannot see (by design — it only ever reads the tracked file).
3. `APIEnvironment.isSafeForCurrentBuildConfiguration`
   (`ios-native/Kitchen Manager/KitchenManager/Networking/APIEnvironment.swift`,
   Phase 2C-3) already rejects a Release build resolving to a loopback
   host.
4. `scripts/ios-archive-guard.mjs` (new this phase) asserts, from the
   *committed* config only, that every dogfood/diagnostics/smoke flag and
   crash-reporting DSN is off/blank before any real archive — see
   `docs/IOS_SIGNING_AND_ARCHIVE.md`.
5. Xcode Previews, Unit Tests, and UI Tests all still work — verified this
   phase (see `docs/PHASE2D1_VALIDATION.md`); none of the above changes
   touch test-target build settings.

## 3. Version & build number strategy

- **Marketing Version (`MARKETING_VERSION`)**: SemVer (`X.Y.Z`), bumped
  deliberately for each real release — never automated, never inferred
  from a git tag by a script without a human decision.
- **Build Number (`CURRENT_PROJECT_VERSION`)**: a monotonically increasing
  plain integer, tracked outside the project file too — a build number is
  never reused, even across marketing-version bumps, and TestFlight
  requires this anyway (a re-uploaded identical build number is rejected).
- **Git SHA**: not used as `CFBundleVersion` — TestFlight/App Store Connect
  require a plain integer, and a hash can't be compared for "did this
  regress." A git SHA remains useful only as a diagnostic tag (already
  covered by the existing `SYNC_RELEASE_VERSION`-style labels used
  elsewhere in this codebase's observability, unrelated to the App Store
  build number).
- **New tooling** (this phase, no network access, fully tested — see
  `docs/PHASE2D1_VALIDATION.md`):
  - `scripts/ios-release-support.mjs` — shared parsing/ledger helpers.
  - `scripts/validate-ios-release.mjs` (`npm run ios:release:check`) —
    fails if `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` are malformed,
    inconsistent across targets, or the build number has regressed below
    the last recorded value.
  - `scripts/bump-ios-build.mjs` (`npm run ios:release:bump-build`,
    `--dry-run` supported) — increments `CURRENT_PROJECT_VERSION` across
    every target/configuration in lockstep and records the new value in
    `ios-native/Kitchen Manager/Config/release-build-ledger.json` (tracked
    in git) so a later validation run — even from a different clone/branch
    — can still detect a regression or reuse attempt. **Never commits**;
    a human decides when to commit the result.
  - Neither script modifies any file it wasn't explicitly told to
    (`validate-ios-release.mjs` never writes anything at all).

## 4. CI/CD design

No iOS CI existed before this phase (`.github/workflows/deploy.yml` only
ever handled the Node/PWA static-site deploy). Added
`.github/workflows/ios-release-check.yml`, scoped deliberately narrow:

- **On every push/PR touching iOS files**: run
  `npm run ios:release:check` and `npm run ios:archive:guard` (both pure
  Node, no macOS runner needed for these two). **The `ios:archive:guard`
  step runs with `continue-on-error: true`**: today it fails on the known,
  real, unresolved app-icon blocker (§5 of
  `docs/IOS_SIGNING_AND_ARCHIVE.md`) — that is an accurate result, not a CI
  defect, and this workflow deliberately does not let an unrelated PR
  appear red because of it. The guard's PASS/FAIL output is still printed
  in the job log. A real Release archive must still be gated on this guard
  passing for real, independent of this CI job's pass/fail status.
- **`workflow_dispatch` (manual only) on a `macos-latest` runner**: run the
  full iOS Unit + UI test suite and a Debug + Release build, plus an
  **unsigned** (`CODE_SIGNING_ALLOWED=NO`) Release archive-structure check.
  Never attempts a signed archive, never uploads anywhere, needs no Apple
  secret of any kind.
- **No automatic TestFlight/App Store upload job exists.** A real upload
  would require: a real Apple Developer account signed into a macOS
  runner (or an App Store Connect API key stored as a GitHub Actions
  secret, never committed), a signed archive, and — per this phase's
  explicit instruction — manual approval. None of that is implemented
  this phase; the workflow only validates.
- **Secrets**: none are configured. If a future phase adds a real upload
  job, the App Store Connect API key (`.p8` + Key ID + Issuer ID) must be
  stored only as GitHub Actions encrypted secrets, never committed, and
  the upload job must require a manual approval gate (GitHub Environments
  with required reviewers, or `workflow_dispatch` restricted to specific
  people).
- **dSYM/artifact retention**: not configured yet — deferred until a real
  signed-archive job exists, since retaining artifacts from an unsigned
  structural check has no debugging value.
- **fastlane**: not introduced. `xcodebuild`/`xcrun altool`/`xcrun
  notarytool` are sufficient for this project's current scale (one app,
  one team, no complex multi-app/multi-scheme fastlane use case) — adding
  fastlane now would be an unnecessary dependency for a problem
  `xcodebuild` already solves adequately.

## 5. What this phase does NOT do

- Does not configure any real Apple Developer/App Store Connect secret.
- Does not run the manual `workflow_dispatch` job in this session (it
  requires a macOS runner and is meant to be triggered deliberately, not
  automatically, by this phase's own work).
- Does not add a TestFlight/App Store upload job.
- Does not bump the real marketing version or build number for an actual
  release — the ledger/tooling exist and are tested, but no real release
  bump was performed.
