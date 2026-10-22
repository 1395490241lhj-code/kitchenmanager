# Native motion refinement — 2026-10-22

Scope: native iOS, based on `45b108d`. The owner's request authorizes implementation and local verification. No integration, hosted writes or dependency changes are included.

## Audit and design mapping

Reviewed EasyUI's [philosophy](https://easyui.site/docs/introduction), [Story Cards](https://easyui.site/components/story-card), [Morphing Button](https://easyui.site/components/morphing-button), [Skeleton](https://easyui.site/components/skeleton) and [Animated Tabs](https://easyui.site/components/animated-tabs). These pages describe concepts; no source was copied. The static web review does not establish the timing or accessibility quality of its interactive demos.

| Reference | Existing native equivalent | Bounded choice |
|---|---|---|
| Story Cards: continuous discovery, consistent objects | D-048 view-aligned horizontal shelf, next-card peek, five stable identities, narrower regeneration control; Accessibility sizes stack vertically | Preserve geometry, snapping, actions and ordering. Make secondary recommendation press feedback use the existing Home opt-in, including Reduce Motion. Give its utility label the same explicit 44pt content target as HomeActionPair. Strengthen actual swipe/detail/back coverage. |
| Morphing Button: stable geometry through idle/loading/result | Link-import save already owns `isSaving`, `isSaved`, throwing persistence and an error alert | Reusable presentation-only label reserves every state's footprint and crossfades real state. Preserve native button style, disable rules, persistence, haptic and immediate success navigation. |
| Skeleton: sweep and reveal | Home retains existing recommendations while generating; empty loading has an honest activity label | Skip shimmer, blur, artificial progress and replacement placeholders. They would hide useful content or imply new information. |
| Animated Tabs: moving selection indicator | Native TabView, Picker and navigation own these transitions | Leave unchanged. No custom tab bar or parallel selection state. |

D-043 semantic restraint and D-048/D-049 hierarchy remain in force. Do not restore the removed discovery gate, Home planning rows, entrance effects, looping cards, autoplay, parallax, scroll scaling or competing drag gestures. A separate read-only reviewer recommended the minimal Home correction over additional shelf effects; there was no rendered evidence justifying new scroll choreography.

## Acceptance contract and implementation plan

Goal: coherent native feedback, without changing the user's task or its duration.

Impact: `KitchenMotion`, Home recommendation button opt-ins and link-import save presentation. Existing token values and non-adopting consumers remain compatible. Do not touch inventory undo, stores, schema, provider routing, navigation ownership, flags, signing or external environments.

- [x] Add focused geometry/state regression coverage; the missing-label API failed the test build. A later controlled removal of state-size reservation also failed the geometry assertions, proving sensitivity to the actual regression.
- [x] Extend the existing motion vocabulary with Morph and Feedback aliases; keep Gentle=`standard`, Snappy=`quick`. Add a label that owns presentation only, with stable intrinsic size at every supported text size.
- [x] Adopt the label in `ImportRecipeView`, deriving its phase from existing state. No timers, minimum loading dwell, fake success, delayed navigation or new persistence owner.
- [x] Opt secondary Home recommendation controls into existing tactile/Reduce Motion handling; preserve card structure and stable identity.
- [x] Build with Xcode; run focused unit/UI tests serially on Codex's reserved simulator. Capture Light/Dark × normal/AXXXL, failure/retry/success, swipe/detail/back and Reduce Motion evidence. Distinguish component test fixtures from normal navigation and actual system settings.
- [x] Inspect exported screenshots, final diff, untouched boundaries and temporary-path inventory. Report any VoiceOver listening or motion-timing checks not actually obtained.

Stop for an Active Decision conflict, unavailable assigned simulator, unapproved environment/credential/capability change, or repeated same-cause failures without new evidence. Local `keepAlways` attachments satisfy review evidence here; no CI run is dispatched because push/PR is not authorized.

## Validation

Local Xcode MCP validation used `KitchenManager` on the reserved Codex simulator `18FAEFC5-3087-48A4-8131-5B97F48D62C6`, iOS 27.2. A cooperating Codex flow lease covered the complete MCP flow; the shared scheme has no parallelizable testables. No CLI simulator test bypassed the required wrapper. Other agent workspaces/devices were not used.

- Final build-for-testing: success, **0 errors**; the full log contains **3 compiler warning lines**, each also present unchanged in the pre-change build log. The earlier “0 diagnostics” report was incorrect. This is a warning-signature comparison, not a complete-build warning-count comparison. Build completed 2026-10-22 12:33 Toronto. Build log: `/var/folders/q6/xkjcyzf9655_2gcmqk471rrm0000gn/T/ActionArtifacts/default/BuildProject/BuildProject-Log-20261022-123309.txt`.
- **60 current unit tests** passed across `KitchenActionLabelTests` (2), `RecipePersistenceTests`, `HomeRecommendationStoreTests` and `HomePrimaryTaskTests`.
- **10 current UI methods** passed across `NativeMotionUITests` (5), three focused Home hierarchy/accessibility methods and two existing Clipboard import-save/navigation methods. These are distinct tests across focused runs, not a full-suite result or one 70-test invocation.
- The main Reduce Motion run was **67/67**, 0 failed/skipped/notRun; it includes a subsequently replaced component snapshot method. Restored-motion final UI run: **4/4**. Final label plus runtime gallery run: **3/3**. `TEST_RESULTS.json` records exact scopes, counts, failures and result paths.
- Actual simulator Reduce Motion preference was enabled. The fixture required both UIKit and SwiftUI to observe it, then exercised real save failure/retry/success. Home browsing, hierarchy and execution controls also ran while that system setting was enabled. The original preference `0` was restored before final normal-motion validation.
- Real save state comes from the existing operation. One isolated fixture injects a single failing SwiftData persistence write, then forwards retry to the actual in-memory persistence. Its existing `onSaved` callback retains success for inspection. Separate normal-navigation tests prove saving still returns immediately to the recipe library. No artificial delay, success timer or production lifecycle change was added.
- A controlled negative check removed the hidden state-size reservation: the geometry test failed on width and height, then passed after restoration. A separate pixel-difference test catches removal of the visible label overlay.
- **51 canonical PNGs** are linked under `/tmp/km-native-motion-20261022/review/`. The runtime phase gallery is explicitly labelled as component preview, not a save operation. Representative Home and save captures were visually inspected across Light/Dark and normal/AXXXL. Filename audits confirm requested save, Home execution and all-phase gallery coverage. Earlier ImageRenderer/hosting snapshot exports were excluded from the review set because they could not faithfully demonstrate the spinner; runtime gallery screenshots show the native spinner and complete large text.
- Node source-contract guard: `node --test test/ios-native-core-alignment.test.mjs`, **13/13**. Final `git diff --check`: clean.

Taste Pass: Home remains task → attention → optional discovery. Native snapping, peek, vertical Accessibility layout and subdued execution actions remain intact. The useful changes are consistent feedback, an explicit 44pt secondary-detail target (including a tested top-edge tap), and a stable, readable save state. No extra visual surface or navigation step was justified.

Independent source review found no production correctness issue. Its visible-content coverage finding was addressed by pixel checks and runtime gallery evidence; execution-mode controls gained direct coverage. **Remaining limits:** the AXXXL regeneration control was checked for reachability and 44pt geometry, but its press animation was not separately isolated, to avoid an uncontrolled provider request. No frame-by-frame timing comparison, VoiceOver speech/focus-order listening, physical-device test, full native suite, Release build or fresh cloud CI is claimed. Accessibility evidence is the actual button role/current labels, disabled-state semantics, adaptive layout and target/navigation assertions. External recommendation generation completion was not exercised in this pass.

## Delivery and retained evidence

Implementation was prepared on `codex/km-native-motion`, based on fetched `origin/main` at `45b108d`. The owner subsequently authorized final acceptance and one scoped local commit of these 11 files. The original checkout's inherited governance and ScreenshotTour changes remain untouched. No push, merge, PR, deployment, schema, lockfile, secret, flag or inventory-undo change is part of this delivery.

Changed files:

- `ios-native/Kitchen Manager/KitchenManager/KitchenTheme.swift`
- `ios-native/Kitchen Manager/KitchenManager/KitchenActionLabel.swift` (new)
- `ios-native/Kitchen Manager/KitchenManager/HomeView.swift`
- `ios-native/Kitchen Manager/KitchenManager/AddRecipeViews.swift`
- `ios-native/Kitchen Manager/KitchenManager/ContentView.swift` (DEBUG routing only)
- `ios-native/Kitchen Manager/KitchenManager/KitchenMotionImportFixture.swift` (new, DEBUG only)
- `ios-native/Kitchen Manager/KitchenManagerTests/KitchenActionLabelTests.swift` (new)
- `ios-native/Kitchen Manager/KitchenManagerUITests/NativeMotionUITests.swift` (new)
- `docs/design/KITCHEN_DESIGN_LANGUAGE.md`
- `docs/design/IOS_NATIVE_MOTION_REFINEMENT.md` (this file)
- `docs/README.md`

Source evidence manifest: `/tmp/km-native-motion-20261022/SOURCE_MANIFEST.json`, digest `100d6a1d29fde6a4192e4b7ee0da20e1ad750c9dfa8144e8d0774c03ae7122df`. It covers the eight affected Swift source/test files. Final acceptance rechecked every hash; the local commit identity is recorded in the acceptance result and delivery response.

Temporary-output cleanup removed **895.5 MiB** of this task's reproducible build/index/dependency/symbol output after closing only its Xcode workspace and confirming no active build. The owned simulator lease was released; both reserved simulators remain intact. Required screenshots, logs, negative-proof and xcresults remain: exact paths, allocated sizes, Codex/Kitchen Manager ownership, purpose and deletion conditions are in `/tmp/km-native-motion-20261022/INVENTORY.md` and `RETAINED_PATHS.json`. The review worktree is a 20 MiB deliverable and remains attached. Canonical main/vault anchors remain unchanged; the local branch acceptance is recorded below.


## Final acceptance review — 2026-10-22

**Verdict: PASS for this bounded native motion change; ready for integration through the normal review/CI gate.** No confirmed blocking regression was found. All 11 approved changed files were inspected. No Swift source or test change was needed during final acceptance; the only acceptance correction is the build-diagnostic wording above and this review record.

- **Home:** the diff changes only the existing secondary/utility/Accessibility regeneration style opt-ins and the utility label's explicit 44pt frame/content shape. Shelf geometry, view alignment, stable recommendation identities, vertical Accessibility composition, add/detail callbacks, disable rules, hierarchy and navigation destinations remain unchanged. Existing actual swipe/detail/back, target-edge and normal/AXXXL evidence remains applicable.
- **Save states and edges:** Processing takes precedence while the operation is active, Success only follows the existing successful persistence call, and Failure comes from the existing error. Dismissing the native alert clears that error and restores Idle for retry. The entire `saveRecipe()` implementation and the `.onDisappear` import-cancellation handler are byte-for-byte unchanged from the baseline. The label owns no task, timer, callback or stored result. It adds no delay to rapid saves, no new cancellation behavior and no post-navigation work. The pre-existing unstructured local-save task/cancellation semantics were not redesigned or newly runtime-tested in this presentation change.
- **Accessibility and announcements:** both reviewers independently checked the source. Hidden size reservations and the animated overlay are excluded from accessibility; one labelled element remains inside the existing native Button. Structural Home order remains add → detail, stacking vertically at Accessibility sizes; no sort priorities or focus overrides were added. Current label/value and disabled state are available to accessibility. A label update or success haptic does **not** prove an automatic speech announcement. The existing native error alert remains the error surface. **VoiceOver speech delivery, actual focus traversal/order, focus after alert dismissal or success navigation, and rapid-save success announcements remain UNVERIFIED.** This acceptance does not claim a duplicate-free traversal based only on screenshots or source.
- **Motion and compatibility:** existing quick/standard/emphasis presets are unchanged, Morph and Feedback are aliases, and the changed consumers choose token versus nil from the real Reduce Motion environment. No new framework, dependency, global style behavior, navigation replacement or deployment-target requirement was introduced.
- **Scope/security:** the six tracked modifications plus five new files match the approved 11-file inventory. Package/project/signing/configuration, persistent models/stores, sync, provider routing, inventory undo and transactional operations are outside the diff. New fixture routing and injected persistence are DEBUG-only; normal/Release composition is unchanged.
- **Evidence reuse:** the eight Swift hashes still match `SOURCE_MANIFEST.json`. Final acceptance parsed the original xcresults independently with `xcresulttool`: Reduce Motion **67/67**, restored-motion UI **4/4**, final label/gallery **3/3**, each with zero failures/skips. This confirms recorded runs rather than rerunning those suites. The current distinct-test accounting remains 60 unit tests plus 10 UI methods across focused runs. Representative retained Light/Dark and normal/AXXXL screenshots were re-inspected. No additional simulator build/test, device session, provider request or new screenshot bundle was necessary for a specific unresolved defect.
- **Non-blocking limits:** the AXXXL regeneration press animation is not separately isolated; its target/reachability and shared style implementation are checked. External generation completion, timing capture, Release/full-suite/cloud CI and physical-device validation remain outside this local acceptance. These limits do not authorize a broader pass.

Evidence rechecks and protected-original-checkout manifests are retained under `/tmp/km-native-motion-20261022/acceptance/`. Durable original xcresults also remain under `/Users/lianghongjing/Library/Developer/Xcode/DerivedData/Kitchen_Manager-goeroulqnvyqgyedjwxfbhywdsjv/Logs/Test/`; the original implementation logs and review exports are preserved. Nothing was deleted during final acceptance, and no screenshot/result bundle is included in the commit.

Safe to remove after review acceptance and confirmation that durable originals retain the required attachments: redundant exported intermediates `matrix-first/` and `normal/`, earlier renderer-only phase exports, and duplicate temporary MCP result copies. Keep `review/`, the source/test manifests, acceptance records and durable original xcresults while integration still needs this evidence. Final acceptance creates only small JSON/Markdown records; it creates no new DerivedData, package checkout, dependency tree or simulator state.
