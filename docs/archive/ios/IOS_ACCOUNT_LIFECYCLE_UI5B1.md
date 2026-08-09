# iOS Account Lifecycle UI-5B1

## Scope

This phase refines the signed-in `AccountView` presentation only. The screen
now leads with the account identity, groups household names with owner/member
roles, presents sync state as status, keeps existing merge/diagnostics/delete
destinations, and separates the destructive sign-out action. Sign-out
confirmation, local-data retention, navigation, and all existing mutation
implementations are unchanged.

## Fixture isolation

`AccountLifecycleFixture` is compiled under `#if DEBUG` only. It is selected
only by explicit `UITEST_ACCOUNT_*` launch arguments, uses fixed in-memory
values, and supplies no-op/error-only auth, account, and transport services.
It never contacts Supabase, reads a credential, performs sign-out, sync,
merge, deletion, or ownership transfer. `AuthenticationAssembly` and the app
composition root inject it only for those DEBUG UI-test launches; Release has
no fixture entry point.

## Accessibility and visual decisions

The identity summary is one combined VoiceOver element; household rows preserve
semantic labels; errors use text and symbols; interactive rows retain at least
44pt targets. A bottom safe-area inset keeps the final controls above the
floating tab bar. The layout keeps native Form sections, Dynamic Type, Dark
Mode, and Reduce Motion behavior without custom materials or fixed text sizes.

## Validation

Focused unit validation passed 190/190 (fixture presentation, AuthStore,
AuthFormModel, API account service, Guest Merge, SyncCoordinator, and
SyncTransport). The final Account lifecycle UI class passed 10/10; the full
non-hosted focused UI group passed 20/20 before the final fixture-only link
addition. The full non-hosted UI target then executed 65 tests with 64 passes
and one existing/flaky failure in Xcode beta; hosted smoke classes were
explicitly excluded. Full iOS unit tests passed, `npm test` passed 1057/1057,
and Debug/Release simulator builds passed. The archive guard's only failure
was its intentional `workspaceClean` check because this branch is deliberately
uncommitted; all other guard checks passed. Result bundles and screenshot
attachments are kept outside the repository under the Codex visualizations
directory. No hosted smoke test or real credential was used.

Required screenshot exports belong in:
`/Users/lianghongjing/Desktop/KitchenManager-Account-UI5B1-Review/`.
