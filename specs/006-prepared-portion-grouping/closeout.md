# PR2 final acceptance closeout

2026-10-28. Native iOS only. Uncommitted `codex/km-pr2-slice1`, HEAD `cdcae1424fafba7ffbe82ccdb6c339a6d695f599`. Slices 1–4 and their evidence remain accepted and preserved. This record covers only the five owner-requested remaining gates.

| Gate | Result |
| --- | --- |
| A13 controlled interruption | **PASS**, six real SIGKILL cases with two separate restart probes per case. |
| A14 interrupted restore | **PASS for the existing recovery-copy contract**, v2 import and v1 explicit recovery interrupted after the sixth domain commit. No cross-domain atomicity or global mutation fence claimed. |
| Spoken VoiceOver / focus traversal | **HOLD**: supported interfaces available here do not provide actual VoiceOver speech/listening or VoiceOver focus-traversal evidence. Manual script below. |
| Editor invalid-frame warning | **UNRESOLVED** after one bounded current/reference investigation; reproduced, no confirmed cause or layout edit. |
| Unsigned Release DEBUG exclusion | **PASS for DEBUG-only fixtures, hooks and fixture-only identifiers**. Ordinary production accessibility identifiers remain. Nothing signed or published. |

## Minimal source scope

- [PreparedComponentPersistence.swift](</Users/lianghongjing/.codex/worktrees/km-pr2-slice1/kitchenmanager/ios-native/Kitchen Manager/KitchenManager/Persistence/PreparedComponentPersistence.swift>): two optional callbacks and their invocations inside `#if DEBUG`, immediately before `context.save()` and immediately after it returns. Default nil; absent from Release.
- [ContentView.swift](</Users/lianghongjing/.codex/worktrees/km-pr2-slice1/kitchenmanager/ios-native/Kitchen Manager/KitchenManager/ContentView.swift>): DEBUG synthetic-fixture bootstrap call, after the isolated store is constructed.
- [PreparedPortionGroupingUIFixture.swift](</Users/lianghongjing/.codex/worktrees/km-pr2-slice1/kitchenmanager/ios-native/Kitchen Manager/KitchenManager/PreparedPortionGroupingUIFixture.swift>): DEBUG synthetic directory accessible to the process fixture.
- New [PreparedProcessInterruptionFixture.swift](</Users/lianghongjing/.codex/worktrees/km-pr2-slice1/kitchenmanager/ios-native/Kitchen Manager/KitchenManager/PreparedProcessInterruptionFixture.swift>): fully DEBUG-gated synthetic seed/mutation/restart/recovery probe. Only enabled by the existing grouping fixture flag plus an explicit process action.
- New [PreparedProcessCheckpointTests.swift](</Users/lianghongjing/.codex/worktrees/km-pr2-slice1/kitchenmanager/ios-native/Kitchen Manager/KitchenManagerTests/PreparedProcessCheckpointTests.swift>): proves old disk before save, new disk after commit, and old published values at both checkpoints.
- New [pr2-process-acceptance.py](</Users/lianghongjing/.codex/worktrees/km-pr2-slice1/kitchenmanager/scripts/pr2-process-acceptance.py>): foreground host runner, reserved-slot enforcement, PID/session verification, SIGKILL, complete seven-domain comparisons and retained receipts.

No UI layout, business model/schema, migration, backup contract, recommendation policy, Inventory feature, auth, sync, hosted environment, build configuration or signing source was changed. Existing 18-model configuration and frozen old-store fixture remain unchanged.

## Process-boundary proof

The fixture writes a checkpoint report, then calls `raise(SIGSTOP)`. The host verifies that the reported session and PID match its own launch, that `ps` reports the process stopped, and that its executable is KitchenManager. It sends SIGKILL to that verified PID and waits for termination before reopening. The stopped operation cannot return a successful Result or publish; a mistakenly resumed fixture exits instead of continuing.

The real SwiftData save path is used. Before-save interruption occurs after proposed rows have been inserted/updated/deleted in a non-autosaving context. After-commit interruption occurs after `context.save()` returns, before the persistence call returns to the store and before the store publishes. The separate XCTest was **RED 1 failed → GREEN 1 passed**, verifying those hook positions against old/new durable values and unchanged published values.

The historical PIDs below identify captured runs, not reusable targets:

| Case | Captured PID | Restart result |
| --- | ---: | --- |
| Create, before save | 73521 | Complete old collection; no partially created rounding bucket. |
| Create, after commit/before publish | 73653 | Complete new source and both rounding groups. |
| Split, before save | 73786 | Original four-portion UUID remains intact. |
| Split, after commit/before publish | 73917 | Original UUID has three portions plus one linked sibling. |
| Consume, before save | 74061 | Four portions remain. |
| Consume, after commit/before publish | 74199 | Three portions remain on both restart probes; no second decrement/replay. |
| v2 whole restore, after Prepared commit | 75885 | First six domains are the target; seventh remains old; recovery copy retained. |
| v1 explicit recovery, after Prepared commit | 76158 | First six domains are the v1 target; seventh remains prior state; v1 copy retained. |

[A13/A14 summary](/Users/lianghongjing/.codex/visualizations/2026/10/28/01a18321-89d5-7880-b56a-eac25c5f1c0d/pr2-closeout/process-boundary-summary.json), [original process receipts](/Users/lianghongjing/.codex/visualizations/2026/10/28/01a18321-89d5-7880-b56a-eac25c5f1c0d/pr2-closeout/process-1/process-receipts.json), [restore-only receipts](/Users/lianghongjing/.codex/visualizations/2026/10/28/01a18321-89d5-7880-b56a-eac25c5f1c0d/pr2-closeout/process-restore-2/process-receipts.json).

Each A13 case performs two new app processes that construct a new store/container and load the same synthetic disk store. Complete backup scope, UUID uniqueness and all grouped fields are compared, with no command reissue. These are fresh store-startup probes, not a claim about arbitrary background timing or power-loss/fsync durability.

The first host run passed all six A13 cases, then failed its A14 comparison because the harness combined a normalized map with an unnormalized list. The normalizer was corrected in the host runner; **no app fix** followed that failure. Only the two restore cases were rerun. Original failed-run evidence is retained. The six A13 receipts were independently rechecked offline, without repeating the processes; baseline/candidate JSON and native store files are preserved.

## Interrupted restore and unsafe-state limits

The seven established commits remain sequential: inventory, shopping, plans, consumption, weekly plan, Prepared, special plans. Both A14 cuts occur after Prepared commits and before special plans commit. Two fresh startup probes confirm a mixed state, distinct from both complete endpoints. No compensating `catch` executes after SIGKILL.

The v2 pre-import recovery copy remains byte-identical across interruption/restart/refused import, SHA-256 `8e014f245095f167bb002a1e2c64fc559e837d140a32598f9145f3b9232bb104`. The v1 copy interrupted during recovery remains byte-identical, SHA-256 `b721c51a7b476fd4885e08af761237e9fbeb089f702de0b42506959b4f10c983`. Both validate through the native backup validator. A fresh normal import is refused while the copy is outstanding and reports preparation failure without modifying the mixed state or recovery bytes. Explicit `restoreFromRecoverySnapshot()` then restores all seven original domains, resolves the copy, and survives two more startup probes. V1 never acquires invented grouping or mass.

**Important state boundary:** `lastRestoreOutcome` is process-local and is nil after restart; it is not a persisted `failedUnsafe` marker. The durable outstanding-copy flag represents the unresolved restore and exposes the existing recovery route. It blocks a new import; ordinary mutations are not globally fenced merely because a copy exists. The tests do not upgrade that behavior into crash atomicity or a global unsafe-state lock.

## VoiceOver — HOLD and short manual script

Capability check: exposed Xcode interaction APIs return screenshots/hierarchy/logs and generic input; installed `simctl ui/io` commands offer no actual VoiceOver speech capture/listening or VoiceOver focus traversal. No supported listening channel was available. No OS accessibility setting was changed, no fabricated TTS was used, and labels/trees/screenshots are not counted as speech. [Capability receipt](/Users/lianghongjing/.codex/visualizations/2026/10/28/01a18321-89d5-7880-b56a-eac25c5f1c0d/pr2-closeout/voiceover-capability.json).

On a VoiceOver-capable test device with an isolated Debug build:

1. Launch with `UITEST_PREPARED_GROUPING UITEST_GROUPED_SEED_LINKED UITEST_FORCE_MEAL_PREP_DAY` and a fresh UUID in `PREPARED_GROUPING_SESSION`. Enable VoiceOver manually. Open Prepared and swipe through the legacy row, source summary and both same-name groups. Listen for original versus remaining totals, physical portion count, mass, state/storage/expiry, and distinct group action labels; no raw UUID should be spoken.
2. Open Add, enter 100g and three portions. Listen to both actual allocations (33.4g×1 and 33.3g×2), then traverse minus/plus, fields, Save and Cancel. Cancel and verify focus returns to the initiating control.
3. In a fresh linked session add `UITEST_GROUPED_FAIL_WRITE=1`. Split or edit a group. Listen to the failure alert, dismiss it, verify draft/focus retention, retry and hear success only after persistence. Confirm protected quantity/state/storage are not presented as editable; no undo action appears.
4. In another fresh UUID session use `UITEST_GROUPED_SEED_RECOMMENDATION UITEST_FORCE_QUICK_DAY`. Listen to the 33.4g live-group action in Quick Meal and Component Meal. Activate it, hear “这组已用完”, and confirm the surviving 33.3g group remains accessible. Repeat with Accessibility XXXL and record focus order/restoration and the actual words heard.

Record the case, device/OS, actual spoken output and focus destination as PASS/FAIL. This remains HOLD until a human listening run or a supported genuine audio/focus record is obtained.

## One bounded runtime-warning investigation

One current editor reproduction ran in `PreparedPersistenceReliabilityUITests/testAddFailureKeepsEditorInputAndRetrySavesOnce`: **1 passed**, with the same `Invalid frame dimension (negative or non-finite)` warning. Activity tree places it under tapping `prepared.editor.name` while waiting for idle. Issue metadata's source URL is empty and supplies no call stack.

Compared with the retained exact pre-Slice-4 working editor/run (1 pass, zero warnings): current editor adds focus/keyboard-toolbar integration and explicit count/mass preview layout. Its own explicit frames use existing positive minimum-size tokens; no invalid frame expression was identified. Multiple layout differences remain, so neither the toolbar nor a particular SwiftUI component is a confirmed cause. No UI source changed, no cause-specific failing regression was established, and no speculative fix or repeated diagnostic cycle was attempted.

[Fresh activities](/Users/lianghongjing/.codex/visualizations/2026/10/28/01a18321-89d5-7880-b56a-eac25c5f1c0d/pr2-closeout/runtime-activities.json), [issue metadata](/Users/lianghongjing/.codex/visualizations/2026/10/28/01a18321-89d5-7880-b56a-eac25c5f1c0d/pr2-closeout/runtime-issue-metadata.json), [layout comparison](/Users/lianghongjing/.codex/visualizations/2026/10/28/01a18321-89d5-7880-b56a-eac25c5f1c0d/pr2-closeout/runtime-layout-reference.patch), [retained working reference summary](/Users/lianghongjing/.codex/visualizations/2026/10/28/01a18321-89d5-7880-b56a-eac25c5f1c0d/pr2-closeout/../pr2-slice4/warning-baseline-comparison-summary.json).

## Unsigned local Release inspection

`xcodebuild` built generic iOS/arm64 Release in the existing cache with `CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= AD_HOC_CODE_SIGNING_ALLOWED=NO`; exit 0. Both app and Share Extension return “code object is not signed at all” to `codesign -dv`. No signing identity/configuration was edited.

The two Release Mach-O binaries contain **zero matches for 12 fixture/checkpoint markers**; the same markers all have positive matches in the Debug artifact. These include grouping fixture class/launch/environment identifiers, `prepared.editor.fixture.consume`, the new process fixture/action and both save callbacks. Ordinary product accessibility IDs such as `prepared.editor.mass` still exist; this gate verifies DEBUG-only code/hooks and fixture-only IDs, not removal of production accessibility metadata.

[Build command/hash receipt](/Users/lianghongjing/.codex/visualizations/2026/10/28/01a18321-89d5-7880-b56a-eac25c5f1c0d/pr2-closeout/unsigned-release.json), [binary hashes, marker controls and unsigned-target evidence](/Users/lianghongjing/.codex/visualizations/2026/10/28/01a18321-89d5-7880-b56a-eac25c5f1c0d/pr2-closeout/release-exclusion.json). The unsigned artifact remains local under the reused DerivedData Release products; nothing was run on a physical device or published.

## Final verification and readiness

After source stabilization, one applicable full native unit gate ran: **2,782 passed / 0 failed / 5 hosted-credential skips** (2,787 unit cases), plus the one selected warning-reproduction UI test (passed). Combined invocation: 2,783 passed / 0 failed / 5 skipped. All **428 Swift hashes** match its receipt. Xcode MCP diagnostics in the three queried affected production files are zero. No accepted appearance/signup/hosted suite was repeated.

[Final native command/hash receipt](/Users/lianghongjing/.codex/visualizations/2026/10/28/01a18321-89d5-7880-b56a-eac25c5f1c0d/pr2-closeout/final-unit-and-runtime.json), [result summary](/Users/lianghongjing/.codex/visualizations/2026/10/28/01a18321-89d5-7880-b56a-eac25c5f1c0d/pr2-closeout/final-unit-and-runtime-summary.json), [source verification](/Users/lianghongjing/.codex/visualizations/2026/10/28/01a18321-89d5-7880-b56a-eac25c5f1c0d/pr2-closeout/final-source-verification.json).

Source-merge recommendation: **GO for owner decision on the bounded source change**, with focused independent review **GO**, no material finding; [review](/Users/lianghongjing/.codex/visualizations/2026/10/28/01a18321-89d5-7880-b56a-eac25c5f1c0d/pr2-closeout/closeout-independent-review.md), preserving recorded limitations. Unrestricted iOS release recommendation: **HOLD** for actual spoken VoiceOver/focus acceptance and the unresolved editor warning; power-loss behavior, older-binary live-store downgrade and real-user production restore remain outside this evidence. A13/A14 process tests do not establish those stronger guarantees. Target-branch integration/CI was not revalidated by this local closeout. No next feature phase is authorized.

No commit, push, PR, merge, deploy, publication, hosted operation or real-user data mutation occurred. All process stores are UUID-isolated synthetic directories. [Exact output lifecycle](/Users/lianghongjing/.codex/visualizations/2026/10/28/01a18321-89d5-7880-b56a-eac25c5f1c0d/pr2-closeout/output-lifecycle.json) records cleanup, retained evidence/cache/artifact/store sizes and disposal conditions.


## Output retention

Removed the disposable native runner after all runs ended. Durable source harness/tests remain in the worktree. Keep 34.8 MiB of closeout evidence, the existing 1461.2 MiB reusable cache (including the 29.6 MiB unsigned artifact), and nine synthetic process stores totaling 7.5 MiB. Exact paths, ownership and disposal conditions are in [output-lifecycle.json](/Users/lianghongjing/.codex/visualizations/2026/10/28/01a18321-89d5-7880-b56a-eac25c5f1c0d/pr2-closeout/output-lifecycle.json). No prior evidence, worktree, real app data, simulator data or cache was erased. Post-run slot status: Codex reserved device booted, Claude reserved device shut down, no conflict.
