# iOS Auth Phase 1 Setup

Phase 1 adds identity to the native SwiftUI app while preserving its local-first Guest mode. It does not upload, replace, merge, or synchronize inventory, plans, shopping items, consumption history, weekly menus, or recipes.

## Implemented

- Guest-first account entry under **我的 → 账号**.
- Supabase email/password registration and sign-in through the official `supabase-swift` package.
- Keychain-backed session persistence, automatic token refresh, auth-state observation, and launch restoration.
- Authenticated `GET /api/me` through the existing Express/APIClient path.
- Recoverable account-profile errors that do not sign the user out or block local features.
- Explicit sign-out that leaves the existing SwiftData container and its data unchanged.

## Safe local configuration

The committed `Config/Shared.xcconfig` contains empty defaults and optionally includes the ignored `Config/Local.xcconfig`. `Local.example.xcconfig` documents the two public client values without containing a working credential.

The iOS app needs only:

```text
SUPABASE_URL
SUPABASE_PUBLISHABLE_KEY
```

The legacy public `SUPABASE_ANON_KEY` environment name is accepted by the generator as a compatibility input. The generated iOS setting is always named `SUPABASE_PUBLISHABLE_KEY`.

Generate the ignored local file without printing either value:

```bash
set -a
source .env.development.local
set +a
npm run configure:ios-auth
```

The generator writes `ios-native/Kitchen Manager/Config/Local.xcconfig` with mode `0600`. Confirm it is ignored:

```bash
git check-ignore "ios-native/Kitchen Manager/Config/Local.xcconfig"
git ls-files "ios-native/Kitchen Manager/Config/Local.xcconfig"
```

The second command must print nothing.

`KitchenManager/Info.plist` is committed with build-setting placeholders only. Xcode expands those placeholders from the xcconfig while building; no working project value is stored in the source plist. Keep using the generator instead of editing the plist.

Never put any of these server-only values into Xcode, Info.plist, Swift source, an app bundle, or a test fixture:

- `SUPABASE_SERVICE_ROLE_KEY`
- database password or connection string
- JWT signing secret
- Supabase personal access token
- a real user password

## Runtime structure

- `AuthConfiguration` validates the generated Info values and safely falls back to Guest mode if they are absent or invalid.
- `SupabaseAuthService` owns the official client and explicitly uses `KeychainLocalStorage` under the app-specific Keychain service.
- `AuthStore` is the single MainActor UI state store for Guest/restoring/submitting/authenticated states.
- `APIAccountService` calls `/api/me` with the in-memory access token. Existing API logging records only method, path, status, and elapsed time—not headers or bodies.
- Neither `AuthStore` nor the auth services depend on `KitchenStore`, `KitchenPersistenceFactory`, or a SwiftData `ModelContainer`.

## Development validation

1. Generate `Local.xcconfig` from the linked development project.
2. Build and launch the `KitchenManager` scheme on an iPhone simulator.
3. Confirm the main app opens in Guest mode without a session.
4. Sign in with a development-only test user and confirm `/api/me` shows that user and only their households.
5. Terminate and relaunch the app; the Keychain session should restore.
6. Sign out and confirm the account section returns to Guest mode.
7. Confirm inventory and another local record still exist before and after sign-in/sign-out.

The deployed API host must contain the Phase 0 `GET /api/me` route. A `404` means that the client authentication succeeded but the selected Express deployment is older than the repository route; the App intentionally preserves the session and shows a retryable account-profile message. Deploy Phase 0 to that host, or run the repository Express server in the approved development environment, before claiming an end-to-end `/api/me` success.

Registration behavior depends on the Supabase email-confirmation setting. Automated tests cover both immediate-session and confirmation-required responses. Creating an additional real test user is not required for Phase 1.

## Automated validation

```bash
npm test -- --test-reporter=tap
npm audit --omit=dev --audit-level=high
```

For iOS, select the installed Xcode developer directory and run the full `KitchenManager` scheme tests plus a Debug build against iPhone 17 Pro. All auth unit tests use mocks or `MockURLProtocol`; they never contact Supabase.

## Not implemented

- Cloud kitchen business tables or business-data synchronization.
- Guest-to-account data merge or per-account SwiftData containers.
- Household invitations or collaborative editing.
- OAuth providers.
- Full password-reset flow.
- Account deletion.

The next planned step is **Phase 2A: cloud business schema and synchronization protocol design**. It must define merge, conflict, deletion/tombstone, household scope, and rollback behavior before any local kitchen data is uploaded.
