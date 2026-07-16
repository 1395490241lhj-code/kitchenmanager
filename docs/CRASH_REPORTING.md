# Crash Reporting (Phase 2C-2)

Status: **abstraction implemented and offline-validated; provider selected
(Sentry, for a future phase); no third-party SDK integrated; disabled by
default everywhere**.

This document covers the iOS crash-reporting / nonfatal-error abstraction
only. Backend structured logging and metrics are covered separately by
`docs/BACKEND_OBSERVABILITY.md`.

## 1. Why an abstraction, not a wired SDK, this phase

Phase 2C-2's instructions require: (1) a `CrashReporting` abstraction, (2) a
no-op default provider, (3) a documented provider *comparison*, and — only if
a third-party SDK is actually selected and wired — a set of strict
configuration/PII constraints. Given this project's current stage (no
production Supabase project decision yet, no TestFlight pipeline, Stage-1
dogfood only on a handful of internal accounts), adding a real SPM dependency
this round would mean managing DSN provisioning, dSYM upload, and a new
vendored dependency before there is any real crash volume to observe. The
abstraction is built so a real provider can be dropped in later by writing
one new file (`XCrashReporter: CrashReporting`) and changing exactly one
factory branch — no other code changes.

## 2. Provider comparison

| Dimension | Firebase Crashlytics | Sentry | Bugsnag | Xcode Organizer only | Self-built |
| --- | --- | --- | --- | --- | --- |
| iOS support | Mature | Mature | Mature | Native, zero setup | N/A |
| SwiftUI support | Yes | Yes | Yes | Yes | N/A |
| dSYM upload | Automatic (build phase script) | Automatic (SPM plugin or CLI) | Automatic | Automatic (App Store Connect) | Manual |
| Privacy / data residency | Google Cloud, no EU-only option | EU or US region selectable; can self-host | US-hosted only | Apple only, no separate vendor | Full control |
| Free tier | Generous, unlimited crash reports | Limited monthly event quota | Limited monthly event quota | Free (bundled with Apple Developer) | N/A |
| Release/version tracking | Yes | Yes | Yes | Yes (App Store builds only) | Manual |
| Nonfatal/handled-error reporting | Yes | Yes (first-class) | Yes | No | Manual |
| Breadcrumbs | Yes | Yes (first-class, structured) | Yes | No | Manual |
| Issue grouping | Automatic | Automatic, configurable fingerprinting | Automatic | Manual (Organizer UI only) | Manual |
| Node/backend support (same vendor) | No (Crashlytics is mobile-only; would need separate Firebase product) | Yes (`@sentry/node`) | Yes | No | N/A |
| Vendor lock-in | High (Firebase SDK footprint) | Moderate (OTLP-compatible, self-hostable) | Moderate | None | None |
| Setup complexity | Requires `GoogleService-Info.plist` + Firebase SDK (large) | Single SPM package + DSN | Single SPM package + DSN | None | Custom |
| App Store privacy-label implications | "Crash Data"/"Diagnostics" tracking-adjacent category, third-party SDK disclosure required | Same category, third-party SDK disclosure required | Same | No third-party SDK disclosure needed | No third-party SDK disclosure needed |

## 3. Recommendation

**Sentry**, selected for a future integration phase, on these grounds: it is
the only option in this comparison offering first-class nonfatal-error and
structured-breadcrumb support *and* a same-vendor Node SDK (useful if backend
error reporting is ever centralized alongside iOS), plus a genuine
self-hosting/EU-region option this project may want given it has no current
production-region decision. It is not integrated this phase — see §1.

`NoOpCrashReporter` remains the only shipped provider in Phase 2C-2.

## 4. The `CrashReporting` abstraction

File: `KitchenManager/Observability/CrashReporting.swift`.

```swift
protocol CrashReporting: Sendable {
    func configure(environment: String, release: String, build: String)
    func captureFatalContext(_ metadata: CrashReportingMetadata)
    func captureNonFatal(_ error: Error, context: CrashReportingMetadata)
    func addBreadcrumb(_ event: CrashReportingEvent, metadata: CrashReportingMetadata)
    func setOperationalTag(key: String, value: String)
    func flushIfNeeded()
}
```

- App/feature code (e.g. `GuestMergeController`) depends only on this
  protocol, injected via a new `crashReporter:` init parameter (default
  `CrashReportingFactory.makeProvider()`), the same dependency-injection
  pattern already used for `persistence`/`transportFactory`.
- `NoOpCrashReporter.shared` is the only concrete provider; every method is a
  true no-op (no allocation, no I/O, cannot throw).
- `CrashReportingFactory.makeProvider(configuration:)` returns the no-op
  provider whenever the configuration is disabled, or enabled-but-missing-DSN
  — enabling the flag without a real provider wired in can never crash or
  silently pretend to report (there is, today, no other branch to take).

### Event allowlist (never free-text)

`addBreadcrumb` only accepts a case from the fixed `CrashReportingEvent` enum
— there is no way to pass an arbitrary string message:

```
app_started, sync_started, sync_completed, sync_failed, sync_rate_limited,
sync_upgrade_required, merge_preview_started, merge_preview_failed,
merge_confirm_started, merge_confirm_completed, merge_confirm_failed,
rollback_started, rollback_completed, rollback_failed, consistency_check_failed
```

### Metadata allowlist (never arbitrary business content)

Every metadata dictionary is funneled through `CrashReportingMetadata`, whose
initializer drops any key not on a fixed allowlist:

```
environment, release, build, routeCategory, errorCode, httpStatus,
durationBucket, mutationCountBucket, conflictCountBucket, retryCount,
featureFlagState
```

A caller cannot smuggle `email`/`token`/`householdId`/`userId`/an inventory
name/a receipt string through this type by construction — the forbidden key
is simply absent from the resulting `fields` dictionary, regardless of what
was passed in. `CrashReportingMetadata.countBucket(_:)` and
`.durationBucket(_:)` turn a raw count/duration into a small, stable label
(e.g. `"6-20"`, `"lt3s"`) — never the exact number.

### Error codes, never localized text

`SyncError` conforms to a small `CrashReportableError` protocol exposing
`crashReportingCode: String` (e.g. `"client_upgrade_required"`,
`"rate_limited"`, `"transport"`) — distinct from, and never equal to, its
Chinese `errorDescription` user-facing text. `captureNonFatal` and breadcrumb
metadata always use this stable code, never `String(describing: error)` or
`error.localizedDescription`.

## 5. Where breadcrumbs/nonfatals are emitted

All inside `GuestMergeController` (the only place `SyncCoordinator.runOnce`
is ever called):

- `preparePreview`: `merge_preview_started` at entry; `merge_preview_failed`
  on either a remote-fetch failure or a local persistence failure.
- `confirmMerge`: `merge_confirm_started` at entry; `merge_confirm_completed`
  on a clean upload with no conflicts/failures; `merge_confirm_failed` on any
  non-`.completed` outcome or thrown transport error (also reports a
  `captureNonFatal` with the error's stable code).
- `rollback`: `rollback_started`/`rollback_completed`/`rollback_failed`,
  mirroring `confirmMerge`.
- `syncNow`: `sync_started`/`sync_completed`/`sync_failed`.
- Centrally, inside `noteSyncOutcomeForVersionAndRateLimitDisplay` (already
  the single hook every flow calls for the Phase 2C-1 426/429 display
  flags): `sync_upgrade_required` / `sync_rate_limited`, so every call site
  gets this consistently for free.

## 6. Privacy / consent policy (Stage 1)

- Crash reporting is **disabled by default** in every committed
  configuration and every Release build (`CRASH_REPORTING_ENABLED = NO`).
- No consent UI exists this phase, and none is required yet: with the
  no-op provider as the only shipped provider, there is nothing to consent
  to — no data ever leaves the device via this subsystem.
- When a real provider is eventually wired in, this phase's design already
  ensures: no email/token/household id/full UUID/inventory name/receipt text
  is ever eligible to be sent (allowlist, not a best-effort filter); no
  automatic PII attachment (no `setUser(email:)`-style call exists in the
  protocol); no session replay or screen recording capability exists in this
  abstraction at all.
- Recommended (not yet implemented) Stage-2 gating before any real DSN is
  configured: enable only for internal/TestFlight builds, never a public
  Release; add an in-app "Share Diagnostics" opt-out that maps to
  `CRASH_REPORTING_ENABLED`; respect the system's own Share Analytics setting
  if a real SDK is later added (most SDKs read this automatically). These are
  GA conditions, not Stage-1 requirements — see `PROJECT_STATUS.md`.

## 7. Configuration (never real values in the repo)

`Config/Shared.xcconfig` / `Config/Local.example.xcconfig`:

```
CRASH_REPORTING_ENABLED = NO
CRASH_REPORTING_DSN =
CRASH_REPORTING_ENVIRONMENT =
CRASH_REPORTING_SAMPLE_RATE = 0
```

Wired into `Info.plist` as `KM_CRASH_REPORTING_*`, read by
`CrashReportingConfiguration.load(from:)` — same pattern as
`SyncConfiguration.load(from:)`. `sampleRate` is always clamped to `[0, 1]`
regardless of the raw value (a malformed or out-of-range value like `150`
never becomes 100% tracing). No real DSN has ever been placed in this repo,
committed or otherwise.

## 8. What this phase explicitly does NOT claim

- Crash reporting is **not** live in production.
- No real crash/nonfatal event has ever been sent to any third-party
  service.
- No dSYM upload pipeline exists.
- No consent UI exists.
- These remain open GA conditions — see `PROJECT_STATUS.md` §5.
