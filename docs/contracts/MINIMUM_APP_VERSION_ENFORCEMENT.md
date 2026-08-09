# Minimum App Version Enforcement (Phase 2C-1)

Status: **implemented, offline-validated, hosted-development-validated**
(against a locally-run instance of the new backend code, pointed at the
real development Supabase project — nothing has been pushed or deployed
this phase, so the live Render deployment still runs the pre-2C-1 code).
**Not production-configured. Not production-enabled.**

## Goal

Safely block an incompatible client from entering the cloud-sync call path
(`/api/sync/*`) without ever blocking local-only (Guest) usage, sign-in
itself, or any other part of the app.

## Design summary

- The **server is the sole authority**. The client never self-diagnoses
  "I am too old" from its own bundle version — it only ever learns this
  from a real 426 response.
- Enforcement is **off by default**, exactly like every other feature flag
  in this codebase (`SYNC_VERSION_ENFORCEMENT_ENABLED`, default `false`).
- Enforcement only ever gates the three `/api/sync/*` routes
  (`bootstrap`, `changes`, `mutations`). Sign-in, `/api/me`, AI/recipe
  endpoints, and every local-only feature are completely unaffected.

## Transport protocol

Four request headers, added once by `ExpressSyncTransport.requestHeaders()`
(`KitchenManager/Synchronization/SyncTransport.swift`) — never touched by
any View, never stored by `AuthStore`, never written to SwiftData, never
logged, and containing no device identifier or user information:

| Header | Value |
|---|---|
| `X-Kitchen-App-Platform` | `ios` |
| `X-Kitchen-App-Version` | `CFBundleShortVersionString` (e.g. `1.2.0`) |
| `X-Kitchen-App-Build` | `CFBundleVersion` (e.g. `42`) |
| `X-Kitchen-Client-Schema` | `InventorySyncEnrollment.currentSchemaVersion` (currently `1`) |

Source: `KitchenManager/Synchronization/SyncClientVersionHeaders.swift`
(`.current` reads `Bundle.main`; a test can construct its own fixed
instance). All three sync calls (`bootstrap`, `fetchChanges`,
`sendMutations`) send an identical set of values per request — verified by
`SyncTransportTests.testVersionHeadersAreIdenticalAcrossBootstrapChangesAndMutations`.

## Server-side configuration

`src/server/sync/version-gate.js`, four env vars:

| Variable | Meaning | Default when unset/malformed |
|---|---|---|
| `SYNC_VERSION_ENFORCEMENT_ENABLED` | master switch | `false` (disabled) |
| `MIN_IOS_APP_VERSION` | SemVer floor (`major.minor[.patch]`) | only consulted if enabled |
| `MIN_IOS_BUILD` | non-negative integer floor | only consulted if enabled |
| `MIN_IOS_CLIENT_SCHEMA` | non-negative integer floor | only consulted if enabled |

**Fail-safe rules**:
- Flag missing/malformed → enforcement stays **disabled** (matches every
  other flag's "explicit opt-in" convention in this codebase).
- Flag explicitly `true` but any of the three thresholds is missing or
  unparseable → the server does **not** silently allow every client
  through. Every sync request is refused with a distinct `503`
  (`SYNC_VERSION_ENFORCEMENT_MISCONFIGURED`), so a config typo is loudly
  visible to an operator rather than quietly defeating the entire point of
  turning enforcement on.
- Comparison is **numeric**, never lexicographic: `1.10.0 > 1.9.0`,
  `2.0 > 1.99.99`. Build/schema are plain non-negative integers (leading
  zeros accepted, negative/overflow/malformed rejected). See
  `parseSemVer`/`compareSemVer`/`parseNonNegativeInteger` in
  `version-gate.js`.
- A client rejected for **any** reason — old version, old build, old
  schema, missing headers, or malformed headers — gets the identical `426`
  response; the server never distinguishes "which specific field was too
  old" in the response body beyond the minimum values themselves.

## Response contract

`426 Upgrade Required`:

```json
{
  "error": "client_upgrade_required",
  "code": "CLIENT_UPGRADE_REQUIRED",
  "message": "A newer app version is required to use cloud sync.",
  "minimumVersion": "1.2.0",
  "minimumBuild": 42
}
```

Never includes internal config, a stack trace, a token, a user id, or a
household id — verified by
`sync-phase2c1-version-and-rate-limit.test.mjs`'s test 14 and by the hosted
check in `docs/PHASE2C1_VALIDATION.md`.

## Middleware order

`auth → role → versionGate → rateLimiter → handler`, for all three sync
routes (`src/server/sync/routes.js`). A rejected request (426 from
`versionGate`, or a later 429) never reaches the handler, so it can never
write a `PendingMutation` server-side or a `sync_mutations` ledger row —
enforced by placement in the chain, verified directly (test 11/12/25 in the
Node test file, and the hosted "no ledger write" check in
`PHASE2C1_VALIDATION.md`).

## iOS client behavior

`SyncError.clientUpgradeRequired(minimumVersion:minimumBuild:)` (mapped from
HTTP 426) and a reserved `SyncError.clientSchemaUnsupported` (no call site
throws it yet — reserved for a future local schema-mismatch check via
`SyncBootstrapResponse.schemaVersion`).

`GuestMergeController` gained two new `@Published` display-only properties:

- `clientUpgradeRequired: Bool` — set by every call site that can receive a
  426 (`preparePreview`'s remote-fetch catch, `confirmMerge`'s and
  `rollback`'s `runOnce` outcome handling, `syncNow`'s outcome handling).
  Reset to `false` at the start of every fresh attempt, so updating the app
  and retrying clears it — never a permanent, un-resettable state.
- `rateLimitedRetryAfter: Date?` — the companion state for 429 (see
  `docs/SYNC_API_RATE_LIMITING.md`).

Neither property ever touches `session`, `createdEntityIds`, or any
SwiftData record — they are purely what the View reads to disable/hide the
confirm and rollback buttons and show "当前版本过旧，更新后才能继续使用家庭同步。"
(`GuestMergeViews.swift`). Local Guest inventory usage is completely
unaffected — none of these flags gate anything outside the merge/sync UI.

A related fix was required for retryability: `confirmMerge`'s guard only
ever accepts `.previewReady`/`.awaitingConfirmation`/`.conflict` as a
startable status. The pre-existing generic failure path moved *any* failed
attempt to `.failed`, which that guard does not accept — meaning a
version/rate-limit failure would have permanently blocked every future
retry, even after the user updated the app. `confirmMerge` now captures its
status immediately before the attempt and restores exactly that status
(not `.failed`) specifically for `clientUpgradeRequired`/`rateLimited`
outcomes, so the very next attempt's own guard still accepts it. Ordinary
transport failures are unaffected and still move to `.failed` as before.

## What this phase did NOT do

- Did not enable `SYNC_VERSION_ENFORCEMENT_ENABLED` in any committed
  configuration or on the deployed Render service.
- Did not decide what `MIN_IOS_APP_VERSION`/`MIN_IOS_BUILD`/
  `MIN_IOS_CLIENT_SCHEMA` should actually be for a real rollout — those are
  product decisions for whoever ships the first version that needs a floor.
- Did not implement a forced-update UI flow beyond the merge/sync screens
  (no App Store deep link — none is hardcoded, per the explicit instruction
  not to guess a URL that doesn't exist yet).
