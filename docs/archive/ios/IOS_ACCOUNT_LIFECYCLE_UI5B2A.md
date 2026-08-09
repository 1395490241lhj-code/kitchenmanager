# UI-5B2A — Sync Status & Recoverable Errors

## Scope

UI-5B2A is a presentation-only refinement of the signed-in inventory sync
section. It gives each existing sync condition a stable title, explanation,
symbol, and (where safe) an explicit action. It does not change sync, merge,
transport, persistence, authentication, feature flags, or server behavior.

## State projection

`InventorySyncPresentationState` maps existing controller observations to:

- not enrolled / no household / feature disabled;
- idle, pending mutations, syncing, completed;
- offline and recoverable generic error;
- active or expired rate limit;
- client upgrade required.

An active rate limit disables the retry action and presents a short countdown.
`TimelineView` refreshes the projection without starting a sync. Enrollment is
re-read when the account, household, or merge-session status changes, so a
completed merge can update the displayed enrollment state promptly.

## Fixture safety

The existing `AccountLifecycleFixture` remains the only fixture seam. New sync
states are DEBUG-only launch arguments and use the pure presentation projection.
Fixture actions are local no-ops; they never create credentials, call a real
sync/merge/rollback path, read a server, or mutate persistence. Release builds
cannot activate the fixture.

## Behavior freeze and exclusions

Preview reads, merge confirmation/conflicts/progress/results/rollback,
`GuestMergeController` transport and mutations, `SyncCoordinator`, transport,
persistence, AuthStore, Keychain/session restoration, feature flags, API/server,
SwiftData, and automatic/background sync are unchanged.

## Validation evidence

Focused presentation and account-fixture UI validation is run on the dedicated
UI-5B2A branch. Full iOS unit/UI, Debug/Release builds, Release fixture-symbol
scan, npm, and the screenshot matrix are recorded in the task handoff after
execution. Screenshots are kept outside Git at:

`/Users/lianghongjing/Desktop/KitchenManager-Sync-UI5B2A-Review/`

Focused presentation and deterministic sync-state UI tests pass. Dark Mode and
Accessibility XXXL top/bottom checks each passed three consecutive single-worker
runs after clearing only the previous test-runner processes and rebooting the
target simulator once; the full non-hosted UI suite then passed (67 passed,
0 failed, 0 skipped). Full unit validation passes (791 passed, 5 skipped,
796 executed); Debug and Release builds pass and the Release binary contains no
fixture symbols. The archive guard correctly refuses the intentionally dirty,
uncommitted worktree.
