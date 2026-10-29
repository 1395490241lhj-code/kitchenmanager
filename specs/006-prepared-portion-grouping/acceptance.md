# PR2 Slice 4 acceptance record

Date: 2026-10-28. Native iOS only. Uncommitted worktree `codex/km-pr2-slice1`, baseline `cdcae1424fafba7ffbe82ccdb6c339a6d695f599`.

Slice 4 implementation is ready for owner review subject to the final gate/review record below. **A13/A14 are now PASS after the bounded closeout; spoken VoiceOver remains HOLD and the editor warning is unresolved.** See [final closeout](closeout.md) for current process-boundary, Release and validation evidence. This document records implementation and evidence; it does not authorize integration or release. Owner authorization in the task supersedes the historical proposal-only status in the unchanged design documents.

## Delivered behavior

- Optional grams in the existing add sheet. Empty means legacy count-only creation. Checked integer parsing at 0.1g accepts decimal dot/comma, rejects excess precision, nonnumbers, units, impossible allocations and overflow; no Double conversion or clamping. The production allocator previews 800g/4 as 200g×4 and 100g/3 as 33.4g×1 + 33.3g×2.
- Draft-owned legacy/source/two reserved group UUIDs remain stable through edits, invalid input and retry; the submitted one/two-ID prefix follows the allocation. One confirmed store operation owns saving; failed saves retain the draft.
- Source sections distinguish original/remaining mass and physical count. Each live group shows count, per-portion mass, state, storage and expiry, with source/group ordinals distinguishing same-name siblings. Ordinals describe current display order; UUIDs remain action identities.
- Whole-portion split retains the original UUID and its expected snapshot, with one stable new sibling ID. Grouped name/prepared-date/expiry corrections use expected snapshots; count, mass, source and post-create state/storage stay protected. Explicit reload/recheck retains entered corrections.
- Consume/delete use actual group UUIDs. Consuming the last portion or deleting a group preserves siblings. All success/dismissal follows confirmed persistence; failures remain visible, retryable and without undo. Shared usage labels disclose exact group mass/state/storage; grouped feedback says “这组已用完” or “这组还剩 N 份”, preserving legacy wording.
- The existing restore preview shows source totals and exact grouped allocations. No Slice 4 schema, persistence, backup-format, selection-policy, Inventory, auth, sync or hosted change.

## Exact Slice 4 changed paths

These 14 implementation/test paths are the increment over the accepted Slice 3 tree. The additional repository deliverable is this acceptance record. The two reviewed design documents and frozen migration fixture are byte-identical to preflight.

| Path | Purpose |
| --- | --- |
| [ios-native/Kitchen Manager/KitchenManager/ComponentMealViews.swift](</Users/lianghongjing/.codex/worktrees/km-pr2-slice1/kitchenmanager/ios-native/Kitchen Manager/KitchenManager/ComponentMealViews.swift>) | Shared grouped success wording only; dispatch and policy unchanged. |
| [ios-native/Kitchen Manager/KitchenManager/ContentView.swift](</Users/lianghongjing/.codex/worktrees/km-pr2-slice1/kitchenmanager/ios-native/Kitchen Manager/KitchenManager/ContentView.swift>) | DEBUG isolated grouping fixture/recovery wiring. |
| [ios-native/Kitchen Manager/KitchenManager/HomeView.swift](</Users/lianghongjing/.codex/worktrees/km-pr2-slice1/kitchenmanager/ios-native/Kitchen Manager/KitchenManager/HomeView.swift>) | Shared grouped success wording only; Home policy/expiry unchanged. |
| [ios-native/Kitchen Manager/KitchenManager/MainFeatureViews.swift](</Users/lianghongjing/.codex/worktrees/km-pr2-slice1/kitchenmanager/ios-native/Kitchen Manager/KitchenManager/MainFeatureViews.swift>) | Prepared-only allocation detail in existing restore preview. |
| [ios-native/Kitchen Manager/KitchenManager/PreparedComponentViews.swift](</Users/lianghongjing/.codex/worktrees/km-pr2-slice1/kitchenmanager/ios-native/Kitchen Manager/KitchenManager/PreparedComponentViews.swift>) | Existing add/edit/list route, source sections and UUID actions. |
| [ios-native/Kitchen Manager/KitchenManager/PreparedPortionGroupingPresentation.swift](</Users/lianghongjing/.codex/worktrees/km-pr2-slice1/kitchenmanager/ios-native/Kitchen Manager/KitchenManager/PreparedPortionGroupingPresentation.swift>) | Exact decimal parser, stable-ID draft, section projection and scoped feedback. |
| [ios-native/Kitchen Manager/KitchenManager/PreparedPortionGroupingUIFixture.swift](</Users/lianghongjing/.codex/worktrees/km-pr2-slice1/kitchenmanager/ios-native/Kitchen Manager/KitchenManager/PreparedPortionGroupingUIFixture.swift>) | DEBUG per-session synthetic disk/recovery fixtures and real save faults. |
| [ios-native/Kitchen Manager/KitchenManager/PreparedPortionGroupingViews.swift](</Users/lianghongjing/.codex/worktrees/km-pr2-slice1/kitchenmanager/ios-native/Kitchen Manager/KitchenManager/PreparedPortionGroupingViews.swift>) | Source/group rendering, split sheet, 44pt count controls and restore supplement. |
| [ios-native/Kitchen Manager/KitchenManager/PreparedPortionUsage.swift](</Users/lianghongjing/.codex/worktrees/km-pr2-slice1/kitchenmanager/ios-native/Kitchen Manager/KitchenManager/PreparedPortionUsage.swift>) | Live grouped mass/context in shared Quick/Component usage row. |
| [ios-native/Kitchen Manager/KitchenManager/PreparedReliabilityFixture.swift](</Users/lianghongjing/.codex/worktrees/km-pr2-slice1/kitchenmanager/ios-native/Kitchen Manager/KitchenManager/PreparedReliabilityFixture.swift>) | DEBUG delegation to isolated grouping fixture. |
| [ios-native/Kitchen Manager/KitchenManagerTests/PreparedPortionGroupingPresentationTests.swift](</Users/lianghongjing/.codex/worktrees/km-pr2-slice1/kitchenmanager/ios-native/Kitchen Manager/KitchenManagerTests/PreparedPortionGroupingPresentationTests.swift>) | Eight parser/draft/projection/retry/guard regressions. |
| [ios-native/Kitchen Manager/KitchenManagerTests/PreparedPortionGroupingUsageTests.swift](</Users/lianghongjing/.codex/worktrees/km-pr2-slice1/kitchenmanager/ios-native/Kitchen Manager/KitchenManagerTests/PreparedPortionGroupingUsageTests.swift>) | Three grouped/legacy usage and feedback regressions. |
| [ios-native/Kitchen Manager/KitchenManagerUITests/PreparedPersistenceReliabilityUITests.swift](</Users/lianghongjing/.codex/worktrees/km-pr2-slice1/kitchenmanager/ios-native/Kitchen Manager/KitchenManagerUITests/PreparedPersistenceReliabilityUITests.swift>) | UUID-specific consume helper after removal of nested buttons. |
| [ios-native/Kitchen Manager/KitchenManagerUITests/PreparedPortionGroupingUITests.swift](</Users/lianghongjing/.codex/worktrees/km-pr2-slice1/kitchenmanager/ios-native/Kitchen Manager/KitchenManagerUITests/PreparedPortionGroupingUITests.swift>) | Fifteen grouped feature methods, retained screenshots and frame-based helpers. |

[Exact incremental patch](/Users/lianghongjing/.codex/visualizations/2026/10/28/01a18321-89d5-7880-b56a-eac25c5f1c0d/pr2-slice4/slice4-source.patch), [path manifest](/Users/lianghongjing/.codex/visualizations/2026/10/28/01a18321-89d5-7880-b56a-eac25c5f1c0d/pr2-slice4/slice4-changed-paths.json), [final source hashes](/Users/lianghongjing/.codex/visualizations/2026/10/28/01a18321-89d5-7880-b56a-eac25c5f1c0d/pr2-slice4/final-source-sha256.json), [preservation receipt](/Users/lianghongjing/.codex/visualizations/2026/10/28/01a18321-89d5-7880-b56a-eac25c5f1c0d/pr2-slice4/slice4-preservation.json).

Of 426 inherited preflight paths, eight changed within this slice and **418 match exactly; none is missing**. Six Swift files are new. Inherited Slice 1–3 data-layer source, frozen old-store bytes/provenance, design documents and earlier evidence remain preserved. The primary dirty checkout and PR1 worktrees were not used for implementation.

## Xcode validation

This section retains original Slice 4 evidence. The [bounded closeout](closeout.md) owns the latest gate: 2,782 native unit passes, 0 failures, 5 skips, plus one passing warning-reproduction UI test; 428 Swift hashes match.

Xcode 27.2 (27B5019j), shared KitchenManager scheme. XCTest/XCUITest ran through leased `xcodebuild` using the existing DerivedData, pinned packages and reserved Codex iPhone 18 Pro simulator `18FAEFC5-3087-48A4-8131-5B97F48D62C6`, iOS 27.2. Serial test flags and whole-command `dev-sim-slot run codex --` were used. Xcode MCP supplied changed-file diagnostics; zero issues in queried production files. Actual simulator renders supplement the native compile/test results. No CI run or physical-device acceptance is claimed.

| Evidence phase | Actual result |
| --- | --- |
| Presentation RED → GREEN | 6 failed / 2 passed against stubs → 15 passed (8 new presentation + 7 accepted store). |
| Existing add-sheet UI RED | Missing optional grams field reproduced. |
| Count-target RED → GREEN | Native stepper child measured 32pt → explicit controls measured at least 44pt; preview test passed. |
| Initial functional UI | 3/3 passed: create/split/edit/use/restart/legacy, bucket changes + failure retry, split retry + selected sibling deletion. |
| Restore preview RED | Missing exact allocation supplement reproduced. |
| First feature batch | 14 passed / 2 harness failures; original receipt retained. Safe swipe viewport and collapsed-tab navigation corrected. |
| Follow-up targeted UI | 7/7 passed: both repaired paths, grouped Quick/Component use and existing failure regressions. |
| Grouped usage RED → GREEN | 1 failed / 1 passed (nine assertions) → 50 passed. |
| Group-scoped feedback RED → GREEN | 1 failed / 2 passed (four assertions) → 40 passed. |
| Reviewed feedback/appearance | 5 passed / 2 new screenshot-helper failures; measured slow drags corrected overshooting full-screen swipes. |
| Corrected Light/Dark AXXXL evidence | 2/2 passed; settled editor, full source summary and protected details captured. |
| Final concise feedback render | 2/2 passed, zero runtime warnings; short scoped toast visible with surviving sibling/action. |
| Final frozen native unit gate | **2,781 passed / 0 failed / 5 hosted-credential skips**, 2,786 total, exit 0; 426 Swift hashes match, zero runtime warnings in this unit run. |
| Independent final source/UI review | **GO; F1–F4 closed**, no unresolved material finding. [Final independent review](/Users/lianghongjing/.codex/visualizations/2026/10/28/01a18321-89d5-7880-b56a-eac25c5f1c0d/pr2-slice4/independent-review-final.md). |

The [latest-per-method UI index](/Users/lianghongjing/.codex/visualizations/2026/10/28/01a18321-89d5-7880-b56a-eac25c5f1c0d/pr2-slice4/ui-latest-per-method.json) records **19 passing latest results**: 15 grouped methods and four legacy surface regressions. This is an aggregate of bounded runs, not a fictional single 19-test final batch. Original failures, xcresults, logs, command arrays, source hashes and post-run simulator statuses are retained. Later copy-only changes are covered by the final unit gate and targeted grouped usage renders.

Two earlier full native gates passed (2,780/0/5 and 2,781/0/5) before final review/concise-copy changes. They are retained as superseded evidence. The final gate below is required because independent review and actual toast rendering prompted subsequent source changes; no old receipt is reused as final-tree proof.

[Validation index](/Users/lianghongjing/.codex/visualizations/2026/10/28/01a18321-89d5-7880-b56a-eac25c5f1c0d/pr2-slice4/validation-index.json). [Final unit summary](/Users/lianghongjing/.codex/visualizations/2026/10/28/01a18321-89d5-7880-b56a-eac25c5f1c0d/pr2-slice4/full-native-unit-final-frozen-green-summary.json). [Final unit command/hash receipt](/Users/lianghongjing/.codex/visualizations/2026/10/28/01a18321-89d5-7880-b56a-eac25c5f1c0d/pr2-slice4/full-native-unit-final-frozen-green.json).

## A1–A16

Accepted Slice 1–3 contracts are carried forward and exercised by the final native gate; they were not re-audited as new work.

| Acceptance | Status and evidence boundary |
| --- | --- |
| A1 | PASS: allocator IDs/totals and independent same-name sources; visible 800g/4 creation. |
| A2 | PASS: exact rounding/bucket conservation and rejection; visible 100g/3 preview/restore. |
| A3 | PASS: checked arithmetic and exact parser boundary tests; whole-count controls and invalid input without writes/clamping. |
| A4 | PASS: accepted stale/duplicate/conservation store regressions; visible split/retry retains original row. |
| A5 | PASS: grouped/legacy update/use/delete and durable reopen regressions; visible protected editor, live UUID actions and restart. |
| A6 | PASS for injected save errors and recovery: no false success, rollback, retry and duplicate prevention. Does not establish process interruption. |
| A7 | PASS: genuine pre-PR2 18-model disk fixture upgrade/repeat-open/unrelated-data checks in accepted tests and final gate. Frozen fixture unchanged. |
| A8 | PASS: v1 unknown mass, mixed v2 and explicit-array/version validation regressions. |
| A9 | PASS for supported synthetic round trips: v2 export→preview→restore→restart; old v1 and v1-only reader rejection. Visible recovery case populates Prepared; other domains are empty there, with populated seven-domain unit coverage separate. |
| A10 | PASS: malformed/version/duplicate/inconsistent allocation rejection and zero-write/unavailable guards; visible unavailable/reload state. |
| A11 | PASS for exception-injected restore compensation and retained recovery/fenced failures. Not crash-interruption evidence. |
| A12 | PASS for existing clear/compensation contract and grouped metadata preservation. No stronger global-clear guarantee added. |
| A13 | **PASS:** six controlled SIGSTOP→verified-PID SIGKILL cases for create/split/consume before save and after commit/before publication; complete old/new collections and no replay across two fresh store-startup probes each. [Exact evidence](closeout.md#process-boundary-proof). |
| A14 | **PASS for the existing recovery-copy contract:** interrupted after domain six for v2 import and v1 recovery; mixed state and byte-identical copies retained, new import refused, explicit recovery restores all seven domains. Outcome is process-local/nil after restart; pending copy is not a global write fence. No cross-domain atomicity. [Limits](closeout.md#interrupted-restore-and-unsafe-state-limits). |
| A15 | PASS: source deduplication/multi-role/ranking regressions and live group UUID use across three surfaces; mass/context and scoped feedback in actual renders. |
| A16 | Automated selected flows and Light/Dark normal/AXXXL renders PASS; 44pt/non-overlap/meaningful labels checked. **Actual spoken VoiceOver listening and focus traversal remain unverified.** Runtime warning below remains open. |

A13/A14 were HOLD at Slice 4. The owner-authorized closeout added two optional DEBUG-only save callbacks and a synthetic host runner, with actual SIGSTOP/SIGKILL boundaries. No production refactoring, store reset or replacement migration strategy was introduced. Process-kill evidence does not establish power-loss/fsync durability.

## Actual rendered evidence

Both the implementer and the independent reviewer inspect PNG pixels. Attachment names/assertions alone do not establish visual acceptance. Original transient/failed images remain history; use the settled captures below.

- [Normal source/group list](/Users/lianghongjing/.codex/visualizations/2026/10/28/01a18321-89d5-7880-b56a-eac25c5f1c0d/pr2-slice4/screenshots/ui-feature-acceptance/grouped-list-light-normal.png) and [Dark normal list](/Users/lianghongjing/.codex/visualizations/2026/10/28/01a18321-89d5-7880-b56a-eac25c5f1c0d/pr2-slice4/screenshots/ui-feature-acceptance/grouped-list-dark-normal.png).
- [Exact rounding preview](/Users/lianghongjing/.codex/visualizations/2026/10/28/01a18321-89d5-7880-b56a-eac25c5f1c0d/pr2-slice4/screenshots/ui-feature-acceptance/prepared-rounding-preview-light.png).
- [Settled normal grouped editor](/Users/lianghongjing/.codex/visualizations/2026/10/28/01a18321-89d5-7880-b56a-eac25c5f1c0d/pr2-slice4/screenshots/ui-reviewed-feedback-green/grouped-edit-light-normal.png).
- [Dark AXXXL complete source summary](/Users/lianghongjing/.codex/visualizations/2026/10/28/01a18321-89d5-7880-b56a-eac25c5f1c0d/pr2-slice4/screenshots/ui-axxxl-evidence-green/grouped-list-dark-axxxl.png), [Light protected editor](/Users/lianghongjing/.codex/visualizations/2026/10/28/01a18321-89d5-7880-b56a-eac25c5f1c0d/pr2-slice4/screenshots/ui-axxxl-evidence-green/grouped-protected-light-axxxl.png), [Dark protected editor](/Users/lianghongjing/.codex/visualizations/2026/10/28/01a18321-89d5-7880-b56a-eac25c5f1c0d/pr2-slice4/screenshots/ui-axxxl-evidence-green/grouped-protected-dark-axxxl.png).
- [Split at AXXXL](/Users/lianghongjing/.codex/visualizations/2026/10/28/01a18321-89d5-7880-b56a-eac25c5f1c0d/pr2-slice4/screenshots/ui-axxxl-evidence-green/grouped-split-light-axxxl.png), [AXXXL dates](/Users/lianghongjing/.codex/visualizations/2026/10/28/01a18321-89d5-7880-b56a-eac25c5f1c0d/pr2-slice4/screenshots/ui-axxxl-evidence-green/grouped-dates-light-axxxl.png), [Dark precision error](/Users/lianghongjing/.codex/visualizations/2026/10/28/01a18321-89d5-7880-b56a-eac25c5f1c0d/pr2-slice4/screenshots/ui-axxxl-evidence-green/grouped-invalid-dark-axxxl.png).
- [Restored exact allocations](/Users/lianghongjing/.codex/visualizations/2026/10/28/01a18321-89d5-7880-b56a-eac25c5f1c0d/pr2-slice4/screenshots/ui-followup-targeted/grouped-restored-visible.png).
- [Quick Meal final scoped toast](/Users/lianghongjing/.codex/visualizations/2026/10/28/01a18321-89d5-7880-b56a-eac25c5f1c0d/pr2-slice4/screenshots/ui-feedback-concise-green/grouped-quick-success-group-scope.png), [Component Meal AXXXL final scoped toast](/Users/lianghongjing/.codex/visualizations/2026/10/28/01a18321-89d5-7880-b56a-eac25c5f1c0d/pr2-slice4/screenshots/ui-feedback-concise-green/grouped-component-success-group-scope.png).

Taste pass: source totals receive attention before the individual groups; typography, spacing and native sections carry hierarchy. Row mass/state/expiry distinguish physical packages, separate actions replace nested buttons, and large-text controls stack. No extra navigation, design tokens or decorative cards were introduced. Invalid input and retained-draft errors stay explicit. Source headers and editor details require ordinary scrolling at AXXXL; single-frame visibility is not promised for every field.

## Review, limitations and readiness

The independent review found missing grouped usage context, a stale protected-count test, misleading group-exhaustion feedback and incomplete/transient screenshot evidence. Each received a bounded source/test/evidence correction. Earlier review reports are preserved; final disposition is linked above.

An unresolved nonfatal “Invalid frame dimension (negative or non-finite)” occurs while focusing the new editor. The exact preserved-old-editor comparison passed without that warning; the same current add/retry test passes with it. No source location or visible geometry defect was established. It must not be described as a proven baseline warning. Final concise usage renders have zero warnings; this does not erase editor warnings in other runs.

Remaining limits: actual VoiceOver listening/focus; unresolved current editor warning; older-binary live-store downgrade (unsupported/unverified); power loss; real-user/full production restore and physical-device acceptance. Unsigned local Release DEBUG exclusion now passes for 12 fixture/checkpoint markers and fixture-only IDs, with Debug positive controls; ordinary product accessibility IDs remain. Hosted credential tests skip; no hosted acceptance is implied. The interrupted-restore copy blocks new imports but does not globally fence ordinary edits.

Recommendation: accept the bounded Slice 4 implementation for owner source/UI review, retaining the above explicit holds. **Do not claim unrestricted PR2 final/release acceptance.** No commit, push, PR, merge, deployment, publication, transitions, Inventory linkage/deduction, sync/auth/Render or hosted operation occurred.

## Output lifecycle

Removed task-owned runner/exporter scripts and the stale fixture staging copy. One unmatched 212,783-byte preview export and its index remain preserved; no duplicate status was assumed. No source, original xcresult, frozen fixture, app data or shared cache was deleted. [Exact cleanup and retention inventory](/Users/lianghongjing/.codex/visualizations/2026/10/28/01a18321-89d5-7880-b56a-eac25c5f1c0d/pr2-slice4/output-lifecycle.json).

Retain evidence root 338.1 MiB (owner Codex/Kitchen Manager) through owner review and durable archive; its 6.8 MiB preflight source snapshot supports review of the uncommitted baseline. Reused cache at /Users/lianghongjing/Library/Developer/Xcode/DerivedData/Kitchen_Manager-dydphwcormvndmbugkqsrjydigqo: 980.3 MiB, retained for subsequent native validation. Synthetic UI stores: 36 directories, 14.0 MiB; [exact paths and disposal condition](/Users/lianghongjing/.codex/visualizations/2026/10/28/01a18321-89d5-7880-b56a-eac25c5f1c0d/pr2-slice4/synthetic-store-inventory.json). Simulator app data stays intact under resource policy. Post-final-run status shows only the reserved Codex simulator booted, Claude slot shut down, no conflict; no reset/shutdown/delete was performed.

Canonical Current Status, Next Actions and Testing & Release are reconciled after final evidence. Their `head_commit` stays at cdcae14 because implementation is uncommitted.


## Bounded final closeout — 2026-10-28

[closeout.md](closeout.md) records current A13/A14 PASS, spoken VoiceOver HOLD/manual steps, the single unresolved-warning investigation, unsigned Release DEBUG-exclusion PASS, minimal DEBUG-only source paths and final 2,782-pass native unit gate. Source-merge candidate: GO for owner decision; unrestricted iOS release: HOLD. All earlier Slice 4 receipts/review remain preserved. No integration or next feature phase occurred.
