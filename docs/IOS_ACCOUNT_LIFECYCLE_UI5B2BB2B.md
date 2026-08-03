# UI-5B2B-B2B — Safe Editing of Recorded Conflict Choices

Status: implemented, validated, committed, and submitted in Draft PR #19
pending review and merge, on `claude/ios-merge-choice-editing-ui5b2bb2b`.

## The reachability problem this phase found

Before this change there was **no production path to record a conflict choice
before the first confirm**, so the read-only review UI-5B2B-B2A added could
never appear on a first pass:

- the only production caller of `resolveConflict` was the choice row inside
  `InventoryMergeConflictView`;
- that view was instantiated at exactly one place — the flow root's
  `case .conflict`;
- `.conflict` is only ever set by `confirmMerge`'s post-upload branch;
- 查看处理结果 is gated on `resolvedCount > 0`.

So every `userChoice` was `nil` until after an upload had already happened.

**Now** the preview offers 确认前处理冲突 (`N 条待处理`) whenever conflicts are
outstanding and the session has never confirmed. It is a `NavigationLink` only:
it does not confirm, does not change `session.status`, and touches no network.

Partial confirm is **unchanged and still optional** — a user may ignore the new
entry entirely and press 先合并其余 N 条 exactly as before. Unresolved conflicts
left by that path are still decided for the first time in the `.conflict` root.

## Presentation mode, not a faked status

`InventoryMergeConflictPresentationMode` distinguishes `.postPartialRoot` (the
pre-existing B1 behaviour, untouched) from `.preConfirmNavigation` (pushed from
the preview). Nothing fabricates a `.conflict` status. The pushed mode stays put
after each choice and shows 待处理冲突已全部选择 when the list empties, because a
pushed destination is not swapped out by the flow root.

## Reserved versus active fork

`forkedLocalItemId` is now a **reserved** id:

- allocated once, the first time `keepBoth` is chosen on a same-id conflict;
- **retained** when the choice moves to keepLocal/keepRemote/skip;
- reused verbatim if the user returns to `keepBoth`, across edits and restarts.

Clearing it on the way out — the previous behaviour — minted a *second* fork on
the return trip, which combined with `confirmMerge`'s "create it if no metadata
exists yet" guard is a duplicate-record path.

`activeForkedLocalItemId` is the only id allowed to drive an upload. It requires
all four of: `userChoice == .keepBoth`, `action == .create`,
`remoteItemId == localItemId`, and a non-nil reservation. A retained but
inactive reservation therefore creates nothing: no staged item, no metadata, no
`createdEntityIds` entry. Both `confirmMerge` call sites — the staging branch
and the outcome verification — read the active value; nothing in the upload
identity path reads the raw field.

Different-id `keepBoth` is unchanged: it creates under the candidate's own
already-distinct `localItemId` and never has an active fork.

## When a recorded choice may be changed

`resolveConflict` splits on whether a choice already exists:

- **First-time resolution** of an unresolved conflict is allowed in
  `.previewReady`, `.awaitingConfirmation`, and `.conflict` — the last because
  that is exactly where `confirmMerge` parks leftovers. `.detected` is
  deliberately excluded: `preparePreview` never produces it.
- **Re-editing** a recorded choice additionally requires `confirmedAt == nil`,
  `uploadedItemCount == 0`, and empty `createdEntityIds`. A session that already
  confirmed stays read-only **even after it returns to `.previewReady`**.

Nothing in this app can undo a completed remote create or update, and
`InventoryMergeCandidate` records no per-item upload state, so there is no way
to tell which candidates a past confirm affected. The controller is the final
safety boundary: the UI checks the same rule, but a stale screen or queued tap
fails closed in the controller, not in the view.

Rejections mutate nothing — candidate, plan, status and persistence are all
untouched and no mutation is staged.

## Live review and editor

`InventoryMergeResolvedReviewView` takes the controller, not a captured plan, so
summary, groups and editability recompute on every render: a choice changed in
the pushed editor regroups the candidate immediately on return, and the edit
entries disappear the moment the session starts syncing. The editor stores only
a `candidateId` and looks the candidate up live, so the selected state always
reflects what was persisted, and it fails closed with an unavailable state if
the candidate disappears.

## Edit errors are separate from sync errors

`conflictChoiceErrorMessage` plus `conflictChoiceErrorCandidateId` are distinct
from `lastErrorMessage`. A successful edit clears only the edit-scoped error, so
an unrelated preview/confirm/sync/rollback failure the user still needs to see
survives. Errors are bound to the candidate that produced them, so opening a
different candidate never shows another one's rejection; foreign errors are
cleared when an editor opens, never on every render, so a stale-action rejection
stays visible on the screen that produced it.

## Cold relaunch

A choice made through the UI, and the fork reservation behind it, survive a full
process restart: the second launch resumes the persisted session
(`preparePreview` origin `resumed-existing`, no `regeneratedPreview`), the
reserved and active fork UUIDs are identical character-for-character, and the
restored session is genuinely writable — skip then back to keepBoth reuses the
same reservation. Mutation count stays zero throughout.

Getting there required a DEBUG-only two-phase fixture, because
`KitchenManagerApp.init` resets local data and re-adds 测试库存 under a fresh
UUID on every account-fixture launch, which invalidated the seeded plan hash.
`RestartLaunchMode.seed` owns a deterministic inventory instead; `.resume` does
nothing at all. `.none` leaves every pre-existing fixture behaviour untouched,
including per-process re-seeding.

## Not in this phase

- No change to `InventoryMergeConflictChoice`.
- No new persisted field, no schema change, no migration.
- No per-candidate upload state — the copy therefore never claims which
  individual entries have or have not been uploaded.
- No remote undo.
- No change to `readyToUpload`, ordinary choice outcomes, `confirmMerge` writes
  beyond fork *identity selection*, session-status transitions, transport, API,
  `SyncCoordinator`, feature flags, or progress/result/rollback.

The `previewRequiresRemoteFingerprint` cleanup remains a separate maintenance
item.

## Validation evidence

All figures below are from the frozen base `9642b1a6`.

Focused unit covers the full same-ID 4×4 transition matrix, different-ID
coverage, active/inactive fork upload safety through the real `confirmMerge`
staging path, terminal direct-call rejection with before/after deltas,
candidate-scoped errors, probe value mapping, and restart plan validity. The
choice-editing UI suite drives the production pre-confirm entry, live regrouping,
the live read-only transition, stale actions, and cold-relaunch persistence with
choices made by UI taps rather than pre-written by a fixture.

| run | result |
| --- | --- |
| targeted npm | 122/122 passed |
| full npm | 1100/1100 passed |
| full iOS unit | 941 executed, 935 passed, 5 hosted skipped, **1 pre-existing baseline failure** |
| focused UI (7 suites) | all green |
| targeted XXXL test, 5 consecutive runs | 5/5 passed |
| Preview suite | 14/14 passed |
| full non-hosted UI | 130 executed, 129 passed, 1 hosted skipped, 0 failed — `TEST EXECUTE SUCCEEDED` |
| Debug build / isolated Release build | both succeeded |

The one unit failure is
`SyncTransportTests.test429MapsToRateLimitedAndCarriesRetryAfterSeconds`. It was
reproduced on clean frozen `main` with this phase's changes stashed, so it is a
frozen-base defect and out of scope here. **The full unit suite is therefore not
all green**; every other run above is.

### The Preview UI helper defect fixed on the way

`scrollUntilHittable` in `GuestMergePreviewUI5B2BAUITests.swift` accepted
`isHittable` as proof a control could be tapped. Instrumentation showed the XXXL
long-list button appearing at swipe 4 with frame `(16, 811, 358, 93.33)` —
maxY 904.3 against a window maxY of 844, so it was hittable while partially
off-screen and the subsequent full-visibility assertion correctly failed. The
helper now requires both hittable *and* fully inside the window frame, drags in
window coordinates (0.82 → 0.22), tracks midY progress, and only counts a
no-progress swipe once the element exists. The fix is test-only; no production
code changed for it.

### Release isolation

Both configurations were rebuilt into a dedicated derived-data path and the
executables resolved from `TARGET_BUILD_DIR`/`EXECUTABLE_PATH` build settings.
Note that Debug's `EXECUTABLE_PATH` is an 89 KB stub — the code lives in
`KitchenManager.app/KitchenManager.debug.dylib` (63 MB); Release is a single
36 MB binary. An earlier scan that read the Debug stub reported 0 for every
positive control and was invalid.

Two scanners were run. String literals via `strings -a`: all twelve DEBUG-only
literals (`UITEST_MERGE_CHOICE_EDITING_RESTART_SEED`/`_RESUME`,
`UITEST_ALLOW_SYNC_START_SEAM`, `uitest.markSyncStarted`, the
`uitest.restart.*` probe identifiers, `resumed-existing`,
`regenerated-invalid-plan`, `resume-no-seed`, `not-a-restart-launch`,
`state=missing-candidate`) are present in Debug and absent from Release, while
the production controls `guestMergeConfirmButton`, `guestMergeCancelButton` and
`guestMergePreConfirmConflictLink` appear in both. The removed dynamic marker
`uitest.forkIdentity-` is absent from both. Swift symbols via `nm -a` piped
through `swift-demangle`: `RestartUITestProbeView`,
`RestartUITestProbePresentation`, `markSyncStartedForUITesting`,
`UITestPreviewOrigin`, `uiTestPreviewOrigin`, `restartLaunchMode`,
`restartLocalItems` and `restartSameIDCandidateID` all have non-zero Debug
counts and zero in Release, against controls `GuestMergeController` and
`InventoryMergeChoiceEditorView`, which are present in both.

At the source level, all 47 occurrences of those constructs across
`KitchenManager/` sit inside an `#if DEBUG` region.

### Screenshots

Thirteen screenshots were exported from the full-UI result bundle and reviewed
individually. They confirm the fixture states and counts, the pre-confirm entry
copy, correct single selection on every editor state, the review grouping and
counts after a change and after skip, 修改选择 present while editable and absent
once syncing with 此会话已经开始同步，已记录的处理方式仅供查看。, the last long-list
item reachable, Dark Mode contrast, XXXL without truncation or overlap, no Tab
Bar overlay, no raw UUID and no segmented picker.

The first pass of `review-post-confirm-readonly.png` showed the DEBUG
`uitest.markSyncStarted` seam button. Unlike the restart probes it renders as an
ordinary visible `Form` row, and the launch argument alone kept it on screen
after it had fired. It is now gated on `canEdit` as well, so it shares its
lifetime with the 修改选择 entries and removes itself the instant it flips the
session to syncing — a read-only review can no longer render it. The screenshot
was regenerated and re-reviewed; the seam is gone and the read-only banner,
three groups and absent edit entries are unchanged.

`testMarkSyncStartedForUITestingOnlyMarksTheSessionAndStagesNothing` pins what
that seam is allowed to write: `confirmedAt` set, and `uploadedItemCount`,
`createdEntityIds`, `status`, `plan` and the pending-mutation count all
unchanged — so the read-only state the screenshot shows is one the product
itself can reach, not an artefact of the seam.

Screenshots are kept outside Git under
`/Users/lianghongjing/Desktop/KitchenManager-Merge-Choice-Editing-UI5B2BB2B-Review/`.
