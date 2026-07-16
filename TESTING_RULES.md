# TESTING_RULES.md

A task is complete only when the changed behavior has appropriate evidence. Kitchen Manager is a multi-surface repository; `npm test` alone is not a full-project regression.

## 1. Evidence categories

Always distinguish:

- static/syntax/compiler check
- focused unit/regression test
- full Node suite
- iOS Unit suite
- iOS UI suite
- manual browser/simulator check
- hosted-development smoke
- physical-device check
- production deployment/rollout evidence

Passing one category does not imply another.

## 2. Baseline commands

From repository root:

```bash
npm install
npm test
git diff --check
npm audit --omit=dev --audit-level=high
```

Useful focused Node command:

```bash
node --test test/<relevant-file>.test.mjs
```

Start the local server when runtime behavior is affected:

```bash
npm start
```

Default local URL: `http://localhost:3000`.

## 3. Test selection matrix

### Documentation-only

Required:

- verify claims against current code/config/tests;
- validate JSON or config files that were edited;
- run `git diff --check`.

Run `npm test` when documentation is parsed/guarded by tests or when broad rule changes may affect semantic guard tests. Do not claim application behavior was manually verified if only Markdown changed.

### PWA domain logic

Run:

```bash
node --test test/<focused-test>.mjs
npm test
```

When persistence changes, also test:

- old data loading
- refresh persistence
- migration failure safety
- backup export/import
- API key/token exclusion
- shopping fixed-field normalization when applicable

### PWA UI/CSS

Run:

```bash
npm test
npm start
```

Manual checks:

- affected path at about 390px width
- light and dark theme
- no horizontal overflow
- usable touch targets
- empty/error/loading/offline state
- browser console
- hard refresh and persistence where relevant
- bottom dock/safe content spacing

If browser-imported JS/CSS changed, review and normally run:

```bash
node scripts/stamp-version.js
```

Review Service Worker cache-name changes separately; do not bump it automatically for every edit.

### Recipe data/packs

Run:

```bash
npm test
npm run validate:recipe-packs
npm run validate:recipe-pack-data
```

### Server / API / AI / extraction / media

Run:

```bash
node --test test/<focused-test>.mjs
npm test
npm start
```

Cover as applicable:

- success
- malformed/oversized input
- upstream timeout/failure
- invalid AI JSON
- redacted errors/logs
- SSRF and redirect protection
- rate-limit behavior
- static-mode/local fallback

### Auth / `/api/me`

Local/offline tests first, then only against the approved linked development environment:

```bash
npm run verify:auth-phase0
npm run verify:auth-db
npm run smoke:auth
```

Record the exact environment and whether any hosted data was created. Never run against an assumed production environment.

### Sync server/database contract

Run focused Node tests and the full Node suite. When the task changes migration/RLS/RPC/route contract and hosted verification is authorized:

```bash
npm run verify:sync-db
npm run smoke:sync
```

Also verify:

- direct DML remains denied
- user/household isolation
- idempotent retry
- version conflict
- tombstone/change feed
- cursor pagination and scope separation
- payload and operation allowlist
- version gate and rate limiter order
- no mutation ledger row for pre-handler rejection

A remote verification command is evidence for the linked project only. State whether pgTAP/local Docker was available rather than implying it ran.

## 4. Native iOS commands

Project:

```text
ios-native/Kitchen Manager/Kitchen Manager.xcodeproj
```

Scheme:

```text
KitchenManager
```

List available simulator destinations first:

```bash
xcrun simctl list devices available
```

Example clean Debug build:

```bash
xcodebuild \
  -project "ios-native/Kitchen Manager/Kitchen Manager.xcodeproj" \
  -scheme KitchenManager \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=<available simulator>' \
  clean build
```

Example serial full test run:

```bash
xcodebuild \
  -project "ios-native/Kitchen Manager/Kitchen Manager.xcodeproj" \
  -scheme KitchenManager \
  -destination 'platform=iOS Simulator,name=<available simulator>' \
  -parallel-testing-enabled NO \
  test
```

Use `-only-testing:` for focused development runs, for example:

```bash
xcodebuild \
  -project "ios-native/Kitchen Manager/Kitchen Manager.xcodeproj" \
  -scheme KitchenManager \
  -destination 'platform=iOS Simulator,name=<available simulator>' \
  -parallel-testing-enabled NO \
  -only-testing:KitchenManagerTests/<TestClass> \
  test
```

Do not hardcode a simulator/runtime that is not installed. Report the actual destination and whether tests were serial or parallel.

## 5. iOS test selection

### Swift pure logic/model change

- focused XCTest class
- full `KitchenManagerTests` when shared behavior changed
- Node semantic guards if they inspect the Swift source/contract

### SwiftData record/persistence/migration change

Test:

- fresh empty store
- legacy migration
- repeated/idempotent migration
- restart/reload
- same-name/different-id duplicate behavior where relevant
- field-complete round trip
- clear-all and retained-legacy interaction
- backup restore
- in-memory and production schema parity
- failure/rollback or self-heal semantics

Then run the full iOS Unit suite.

### SwiftUI change

- focused XCUITest/regression if the behavior is automation-relevant
- full UI suite for navigation/shared component changes
- manual simulator check for layout, dark mode, Dynamic Type, VoiceOver labels, hit targets, destructive confirmation, and error states

### Auth/Keychain/network change

Test:

- missing configuration
- sign-up/sign-in/sign-out
- session restore
- expired/missing credential
- logout during an in-flight or multi-step flow
- no token in View/SwiftData/UserDefaults/logs
- Guest local functionality after auth failure

### Sync/Guest Merge change

At minimum cover the affected invariants among:

- bootstrap/pull/push ordering
- pending retention on failure
- cursor safety
- idempotency and duplicate retry
- conflict/rejected state
- mutation coalescing
- queue limits
- remote preview read-only behavior
- plan drift/hash invalidation
- keepLocal/keepRemote/keepBoth/skip
- stable same-id fork
- per-entity rollback verification
- feature flags off by default
- no View token access
- no Guest data scan/upload without explicit confirmation
- no automatic sync call site added

Run the full iOS Unit suite and the relevant UI suite after focused tests.

## 6. Hosted iOS smoke rules

Hosted smoke tests are not ordinary unit tests. Run them only when:

- the task actually changes the hosted contract or a previously verified core semantic;
- explicit development credentials/configuration are available;
- the exact Supabase/Render environment is confirmed;
- flags are enabled only in ignored local configuration;
- the harness uses isolated in-memory/local data and uniquely marked remote records;
- cleanup is scoped and verified.

After the run:

- restore every flag to `NO` or its previous value;
- verify committed/example/Release defaults;
- verify zero marker residue or document exact residual entity ids;
- do not print credentials or tokens;
- distinguish a runtime `XCTSkip` caused by missing credentials from an excluded/compiled-out test.

Do not repeat an expensive hosted lifecycle merely because documentation changed. Re-run when the changed code invalidates the earlier evidence.

## 7. Physical-device rules

Use a physical device only when real hardware behavior matters, such as:

- Keychain/app lifecycle
- network transitions
- lock/background/kill/relaunch
- real touch flow
- camera/photo/file integration
- crash reproduction
- performance/memory instrumentation

Before using a personal device:

- identify whether the installed app contains real user data;
- prefer an isolated XCTest sandbox for destructive/data-writing checks;
- require explicit human confirmation before uploading local data;
- verify flags in the compiled app;
- restore/reinstall a safe-off build after dogfood tests;
- use exact-entity cleanup rather than broad name/prefix deletion when provenance is uncertain.

If tooling cannot perform a human gesture or system toggle, report it as blocked; do not claim it passed.

## 8. Secrets, config, and artifacts

Before delivery, inspect for:

- `.env*` and `Local.xcconfig`
- test emails/passwords
- API keys, service-role keys, PATs, JWTs, access/refresh tokens
- Authorization headers
- full household/user/mutation ids in diagnostics or logs
- DerivedData, `.xcresult`, screenshots, crash logs, temporary exports
- feature flags accidentally set to `YES`

Do not paste secret values into reports. It is acceptable to report that a value was present in an ignored local file and not committed.

## 9. Completion criteria

A task is complete when:

1. requested behavior is implemented;
2. relevant focused tests pass;
3. broader regression appropriate to the risk passes or is explicitly deferred;
4. manual flow is checked when UI/runtime behavior changed;
5. data, secrets, flags, and environment boundaries are safe;
6. remote writes and cleanup are fully reported;
7. docs are updated in the correct owner file;
8. unrun or blocked checks are named honestly.

Use exact commands and results in the final report. Never write “full regression passed” without listing which Node/iOS/UI/hosted/device suites actually ran.
