# Frozen iOS behavior / IA prototype — engineering seal

Disposition: **PASS WITH DOCUMENTED BASELINE REDS**. Owner-approved behavior contract and visual review; design is frozen. This entry records the final implementation tree and its gate evidence, not an all-green claim, App Store approval or production enablement.

## Integrated scope

Normal fast-forward push to main: `54a2972` → `d905312` → `1d13074` → `f02a303` → `f35edec` → `bf601f1` → `0ac9edd` → `d9da474`.

`54a2972` is the earlier tooling-only design-skill reduction. The six prototype commits carry the approved behavior/IA slices in dependency order: Special Plan generation cancellation, the extracted shared cooking flow, the single Inventory filter surface, the reduced Home hierarchy with a primary action that cooks, quiet empty Planner days, then the cross-surface render/accessibility gate realignment. `d9da474` is the isolated replacement-ownership correctness fix.

Twenty-six source and test files changed. No persistence, schema, sync, provider fallback, AI routing, credential, feature-flag, project-configuration or hosted-configuration change; verified by content inspection rather than filenames. A SHA-256 manifest of the validated tree is recorded locally at `/tmp/km-final-integration/validated-source-sha256.json` and is not committed.

## The correctness fix

`SpecialPlanMenuDraftStore.replaceDish` keyed result application, error publication and task cleanup on the row's `dishID`, which survives cancellation and retry. Cancelling a replacement and immediately replacing the same dish therefore let the abandoned request write its result into the retry's row, publish its error as the retry's error, and clear the retry's `replacingDishID` and `replaceTask`.

The fix gives each replacement its own `UUID`, symmetrical with `compose`'s existing `activeComposeID`, and stores it separately from `dishID`. Only the owning request may apply its result, publish failure, or clear progress and the task handle. Cancellation, discard and adopted-draft handoff all invalidate ownership and cancel the outstanding Task. No draft snapshot was introduced, so a deliberately discarded draft is never resurrected.

## Evidence

One iPhone 17 Pro (`98D088FB-6A87-4278-B43A-A691241E6F2D`), iOS 27.0, `-parallel-testing-enabled NO`.

| Gate | Result |
|---|---|
| Race reproduction before the fix | 9 passed / 2 failed, 8 failing assertions |
| Focused cancellation + menu + composer after the fix | 99 passed / 0 failed / 0 skipped |
| Final full native iOS suite | **1828 passed / 2 failed / 6 skipped** (1836 total) |
| Release simulator build | `BUILD SUCCEEDED` |
| `npm run ios:release:check` | passed |
| Release binary audit | Main app and Share Extension: zero `UITEST_SEED_` / AI-stub / review / capture markers |
| `git diff --check` | Clean tree and micro-fix range pass; the preapproved baseline-to-tip range retains one EOF blank-line warning at `RecipeCookingFlow.swift:92` |

Two reds remain, and **no new regression**:

| Failure | Disposition |
|---|---|
| `SettingsExperienceUITests.testCoreSettingsEntriesRemainReachable` | **Pre-existing baseline failure.** Reproduced on clean `origin/main@54a2972` in a disposable worktree at the same file, line 161 and assertion. Settings source is unchanged in this range. Out of scope. |
| `GuestMergeSummaryUI5B2BB2AUITests.testMixedSummaryShowsEveryCategoryWithAccurateCounts` | **Infrastructure flake.** Failed at line 31 with `Failed to get matching snapshots: Timed out while evaluating UI query` — a UI-query snapshot timeout rather than a content assertion. The Guest merge area has zero changed files in this range, and the focused rerun passed 21/21. |

The earlier run's `AccountLifecycleExperienceUITests.testSyncRecoverableStatesHaveClearCopyAndSafeActions` termination did not recur; it passed in this suite.

Five tests were added and no existing assertion was weakened or removed. They force stale success and stale failure delivery after cancellation, latest-request completion order, retry cancellability, discard, and adopted-draft handoff. `RuntimeAccessibilityP1UITests` keeps its full six-size matrix.

## Accessibility exception boundary

44pt remains the Kitchen Manager iOS target. The only exception is the exact unmodified four-choice Inventory segmented `Picker`, recorded as canonical Decision D-039. The accepted iPhone 17 Pro runtime probe measured roughly 32pt visual/accessibility segment height and found that coordinate taps 3pt above and below the segment inside a 44pt container did not select it, so the larger container does not prove a larger hit region. The deviation is accepted for a familiar native single-choice control with accessible selection state and sufficient spacing, with the existing Menu fork at Accessibility Dynamic Type. Custom buttons and row actions still require >=44pt. Automated frame and selection checks do not substitute for manual VoiceOver listening.

## Follow-up boundary

Deferred and not shipped: AI weekly-menu materialization into Planner, ordinary-meal Planner CRUD, Special Plan today in `HomePrimaryTask` precedence, quantity-aware ingredient sufficiency, and AI provenance on saved Planner entries. Nonblocking cleanup found by review — the aggregate duration computed then discarded, `baseServings` publication, large-file decomposition, unused tokens and components, and the blank EOF line above — was deliberately excluded from the correctness fix.

Settings reachability remains an independent pre-existing baseline failure. Historical Shopping and Node CI issues keep their own attribution; this seal neither fixes nor suppresses them. No Node/PWA suite, hosted smoke, distribution archive, physical-device test or new screenshot capture was run for the final fix.
