# iOS Share Import — Phase 1

Native iOS Share Extension entry point for importing a recipe **link**
into Kitchen Manager from Safari, Xiaohongshu, YouTube, or any other app
that supports the system share sheet.

This document covers **Phase 1 only**, and Phase 1 is **URL-only**: the
extension only ever queues content that resolves to an http/https URL
(a URL attachment, or a URL found inside shared text). Plain text with no
URL is rejected in the extension and never reaches the main app — it is
explicitly **not** supported yet; see "Known limitations" and "Next
phases" below. This restriction was tightened during review: an earlier
draft of this phase let bare text through to the main app's
`ImportRecipeView`, which would then fail with a generic "no valid link"
error after the extension had already told the user the share succeeded.
That inconsistent flow was removed before this phase shipped.

## Architecture

```
System Share Sheet
        │
        ▼
KitchenManagerShareExtension (separate process, separate app-extension target)
  ├─ ShareViewController          (NSExtensionPrincipalClass, no storyboard)
  ├─ ShareItemExtractor           (NSItemProvider → URL?/String?)
  ├─ ShareImportViewModel         (state machine, calls SharedImportQueue)
  └─ ShareImportRootView          (SwiftUI preview / submit / cancel)
        │
        │  writes one SharedImportRequest as JSON
        ▼
App Group container (shared file, NSFileCoordinator-guarded)
  SharedImportQueue → shared_import_queue.json
        │
        │  read on next launch / scenePhase .active
        ▼
KitchenManager (main app process)
  ├─ SharedImportCoordinator      (when to surface, dedup presentation)
  ├─ HomeView                     (presents the existing ImportRecipeView)
  └─ ImportRecipeView             (unchanged Smart Import pipeline: prefilled)
```

The extension never touches SwiftData, `KitchenStore`, `RecipeStore`,
`APIClient`, or the Keychain-backed auth session. It only classifies raw
share input and hands a small `Codable` value to the App Group queue.

## App Group

- Identifier: `group.com.lianghongjing.kitchenmanager`
- Single source of truth: `SharedImportConfig.appGroupIdentifier`
  (`KitchenManagerShared/SharedImportConfig.swift`)
- Entitlement added to **both** targets (Debug and Release, both identical):
  - `KitchenManager/KitchenManager.entitlements`
  - `KitchenManagerShareExtension/KitchenManagerShareExtension.entitlements`
- No other capability existed before this phase (no Keychain groups,
  Associated Domains, etc. — this was the project's first entitlements
  file), so nothing was removed or changed for the main app besides adding
  this one capability.

**Signing caveat (simulator only, verified):** in this environment,
`codesign -d --entitlements :-` on the *built* `.app`/`.appex` shows an
**empty** entitlements dict for both — `CODE_SIGN_STYLE = Automatic` fell
back to plain ad-hoc signing with `TeamIdentifier=not set` (no Apple
Developer account is signed into Xcode here). Despite that, the App Group
entitlement **does** take effect on the Simulator: Xcode separately writes
a `*-Simulated.xcent` side file containing
`com.apple.security.application-groups`, which is what the Simulator's
sandbox actually honors, and installing the app was confirmed to create a
real, writable `group.com.lianghongjing.kitchenmanager` container on disk
(verified directly, not assumed). **This has not been verified on a real
device or with a real provisioning profile** — that requires an Apple
Developer account signed into Xcode, an App ID with the App Groups
capability enabled in the portal, and a matching provisioning profile,
none of which exist in this environment. Treat real-device App Group
provisioning as an open risk until checked there.

## Targets

| Target | Bundle identifier | Product type |
|---|---|---|
| `KitchenManager` (existing) | `com.lianghongjing.kitchenmanager` | app |
| `KitchenManagerShareExtension` (new) | `com.lianghongjing.kitchenmanager.ShareExtension` | app-extension (`com.apple.share-services`) |

- Display name shown in the system share sheet: **导入到 Kitchen Manager**
- Same Development Team (`5M5KT5ZG74`) and `CODE_SIGN_STYLE = Automatic` as
  the main app.
- Deployment target: inherited from the project level (`IPHONEOS_DEPLOYMENT_TARGET
  = 27.0`), same as the main app — no override needed.
- The extension is embedded into the main app via a "Embed Foundation
  Extensions" copy-files build phase (`PlugIns`, `RemoveHeadersOnCopy`) plus
  a `PBXTargetDependency`, both added to the existing `KitchenManager`
  native target.
- `KitchenManagerShared/` is a second file-system-synchronized group added
  to **both** targets' `fileSystemSynchronizedGroups`, so
  `SharedImportRequest`/`SharedImportQueue`/`SharedImportConfig` compile
  once and are shared — not duplicated — between the app and the extension.
- The extension does not link Supabase, the networking layer, or any main
  app source files; its Frameworks build phase is empty besides system
  frameworks (SwiftUI, UIKit, UniformTypeIdentifiers).

## Supported content (Phase 1) — URL only

1. A single HTTP/HTTPS URL attachment.
2. A URL embedded inside shared text (e.g. a caption pasted alongside a
   link) — the text is kept alongside it and prefilled too.
3. A URL attachment together with separate text — same as above.

**Rejected, and never queued:** empty content; plain text with **no**
extractable http/https URL anywhere in it; `file://` URLs; non-http(s)
custom schemes; images, video, and files. The extension shows a Chinese
error ("暂时只支持包含网页链接的分享内容。") and does not enqueue anything
in any of these cases.

### Activation rule vs. in-extension enforcement

The system-level `NSExtensionActivationRule`
(`KitchenManagerShareExtension/Info.plist`) cannot distinguish "text that
happens to contain a URL" from "plain text with no URL" — both look like
a `public.plain-text` item to the share-sheet's activation matcher. The
rule therefore still declares:

```xml
<key>NSExtensionActivationSupportsText</key>
<true/>
<key>NSExtensionActivationSupportsWebURLWithMaxCount</key>
<integer>1</integer>
```

No `TRUEPREDICATE`, no image/movie/file support. This means Kitchen
Manager **can** still appear in a share sheet for a bare-text share (e.g.
selected text in Notes with no link) — the activation rule alone can't
prevent that. The actual "URL required" enforcement happens *inside* the
extension, after real parsing: `SharedImportRequestBuilder.build` rejects
any input with no resolvable URL and `ShareImportViewModel` shows an
"内容不受支持" error state instead of a preview — nothing is written to
the queue for that case. So the extension may be *visible* for text-only
shares, but it will never *succeed* for one.

Priority when a URL attachment and free text are both present:
1. A valid http/https URL attachment.
2. A URL embedded inside plain text (`NSDataDetector`).
3. (Phase 1 stops here — non-empty plain text with no URL anywhere is
   rejected, not queued as text-only.)

All of this normalization/priority logic lives in
`KitchenManagerShared/SharedImportRequest.swift`
(`SharedImportRequestBuilder`), independent of UIKit/SwiftUI, so it is unit
testable without a live extension context.

## Data flow

1. `ShareViewController` (principal class, no storyboard) hosts
   `ShareImportRootView` via `UIHostingController` and asynchronously feeds
   `extensionContext.inputItems` to `ShareImportViewModel.load`.
2. `ShareItemExtractor` walks every `NSExtensionItem`/`NSItemProvider`,
   using the non-deprecated `NSItemProvider.loadObject(ofClass:)` API
   (`NSURL`/`NSString`) — not the iOS 27–deprecated
   `loadItem(forTypeIdentifier:)` — and stops at the first usable URL,
   falling back to the first usable text.
3. `SharedImportRequestBuilder.build` turns the extracted URL/text into a
   `SharedImportRequest` (or a typed rejection reason).
4. The view shows a preview (`ShareImportRootView`) with type description,
   truncated headline, and — for URL+text combined shares — an editable
   text field. Content with no resolvable URL never reaches this preview
   state; it goes straight to the "内容不受支持" state instead.
5. On submit, `ShareImportViewModel` calls `SharedImportQueue.enqueue`
   against the App Group container and reports success/failure back to the
   UI; `extensionContext.completeRequest` is called shortly after a
   successful save. Cancel calls `extensionContext.cancelRequest` and never
   touches the queue.
6. On the main app side, `SharedImportCoordinator.refresh` is called from
   `ContentView`'s initial `.task` and on `scenePhase` becoming `.active`.
   It reads the oldest queued request (`SharedImportQueue.peekAll()`) and
   publishes it as `pendingRequest` — but only when nothing else is already
   pending and no other modal import flow (`HomeView`'s existing
   `activeSheet`) is presented.
7. `HomeView` presents the existing `ImportRecipeView` (unchanged Smart
   Import screen) as a sheet, pre-filled via
   `SharedImportCoordinator.prefillText(for:)` — the same free-form
   "URL or full share text" field a user would otherwise paste into by
   hand — and passes `autoStart: true` (added in the follow-up "Shared
   Import Auto-Start" pass) so the existing `importLink()` AI-import call
   fires immediately instead of waiting for a manual "开始导入" tap. Manual
   Smart Import entry points never pass `autoStart: true` and are
   unaffected. There is no second import UI, network call, or draft model
   — `autoStart` only changes *when* the one existing call fires, not what
   it does.
8. Only a **successful** save (`ImportRecipeView`'s existing `onSaved`
   closure) calls `SharedImportCoordinator.markHandedOff`, which removes
   the request from the on-disk queue. Cancelling or closing the sheet
   calls `snooze`, which hides it for the rest of this app session but
   leaves it on disk — it reappears on next launch or app relaunch.

## Queue behavior

`KitchenManagerShared/SharedImportQueue.swift`:

- Storage: one JSON array file (`shared_import_queue.json`) inside the App
  Group container, written with `NSFileCoordinator` + `Data.write(options:
  .atomic)` to minimize cross-process (extension vs. app) races and torn
  writes.
- `enqueue(_:) throws -> Bool`, `peekAll() -> [SharedImportRequest]`,
  `remove(id:)`, `removeAll()`.
- Max queue size: **20**. Enqueueing past that throws `QueueError.queueFull`
  instead of silently evicting an older, not-yet-imported request.
- Deduplication: re-sharing the same normalized URL within **5 minutes**
  (`SharedImportQueue.duplicateWindow`) is a no-op (returns `false`), not an
  error and not a second entry.
- Text length cap: **20,000 characters**
  (`SharedImportRequestBuilder.maxTextLength`) — generous enough for a full
  share-sheet caption, small enough to keep the on-disk queue bounded.
- Corrupted file recovery: an undecodable file is treated as an empty
  queue and reset on disk rather than crashing either process.
- Schema versioning: `SharedImportRequest.schemaVersion` is checked on
  read; mismatched entries are filtered out rather than crashing decode.
- A request is removed **only** by explicit `remove(id:)` (called from
  `markHandedOff`/`discard`) — a plain read (`peekAll`) never consumes it.
- Tests use `SharedImportQueue(directoryURL:)` pointed at a temp directory
  — no real App Group entitlement is required to run them.

No API tokens, session credentials, or other auth material are ever written
to the shared file — `SharedImportRequest` only carries `url`, `text`,
`originalHostBundleIdentifier` (kept `nil` in this phase — no public API
reliably exposes the host bundle id without private API), timestamps, and
an id.

## Main app coordinator

`KitchenManager/SharedImportCoordinator.swift` is the single place that
decides *when* to surface a pending share:

- `refresh(isAnotherImportFlowPresented:)` — safe to call repeatedly (app
  launch, every `scenePhase == .active`); only sets `pendingRequest` when
  nothing is already pending and the caller reports no competing modal.
  It also prunes (discards from the queue) any request with no URL
  (`!hasRequiredURL`) before picking a candidate. Since
  `SharedImportRequestBuilder` never builds a URL-less request, such a
  value can only be legacy/invalid data (e.g. written by a different
  build) — Phase 1's import pipeline can never complete it, so it is
  discarded outright rather than being presented (which would show the
  "no valid link" failure the extension is supposed to prevent) or left to
  block a later, valid request. Requests that do have a URL are untouched
  here — only `markHandedOff`/`discard` remove those.
- `markHandedOff` — only successful save path; removes from disk.
- `snooze` — user closed the sheet without saving; request stays queued.
- `discard` — explicit "clear" action; removes from disk (available for a
  future affordance — not yet wired to a dedicated Phase 1 button).
- `prefillText(for:)` reproduces exactly the input shape
  `ImportRecipeView` already expects (a URL, or text that may contain one)
  — no second parsing path was introduced.
- Has zero dependency on `AuthStore`/guest state, so auth restoring can
  never erase or gate a pending request, and Guest users get the same
  local-only import path signed-in users get (confirmed: neither
  `ImportRecipeView` nor `RecipeStore` gates on auth — see "Guest/auth
  behavior" below).

`HomeView` gates presentation with a computed `Binding` that only surfaces
`sharedImportCoordinator.pendingRequest` when its own `activeSheet == nil`,
so a pending share never stacks on top of the existing Smart Import sheet
(or any other `HomeView` sheet).

## Existing Smart Import reuse

- `ImportRecipeView` (`KitchenManager/AddRecipeViews.swift`) gained one
  additive initializer parameter, `initialURLText: String = ""` — the
  existing call site (`ImportRecipeView(onSaved:)` from `SmartImportSheet`)
  is unchanged.
- No new save path, no new draft model, no new AI-parsing call: a shared
  URL/text is prefilled into the exact same field a user pastes into
  manually today, and follows the exact same `LinkExtractService` →
  `AIRecipeParseService`/`/api/recipe-import-from-url` → `EditableRecipeDraft`
  → `RecipeStore.saveUserRecipe` pipeline already shipped.

## Guest/auth behavior

Per the Phase 1 architecture audit: neither Smart Import nor `RecipeStore`
gates on authentication today (no `AuthStore`/guest checks anywhere in
`ImportRecipeView`, `LinkExtractService`, or `APIClient`). A shared import
therefore works identically for a Guest and a signed-in user — this phase
does not add or remove that gate.

## Privacy and security boundaries

- The extension never reads Keychain, session tokens, or the main app's
  SwiftData store, and never initializes `KitchenStore`/`RecipeStore`.
- Only `url`, `text` (trimmed, length-capped), a generated `id`/timestamp,
  and `schemaVersion` are written to the shared file — never credentials or
  file paths.
- `originalHostBundleIdentifier` is always `nil` in this phase (no private
  API used to obtain it).
- All in-app error copy is Chinese and free of file paths/tokens; internal
  errors (`SharedImportQueue.QueueError`, `ShareImportBuildError`) are
  typed and unit-testable independent of their user-facing strings.

## Testing

- **Unit — model/parser**: `KitchenManagerTests/SharedImportRequestTests.swift`
  (URL attachment, URL-as-String, text-with-embedded-URL, URL+separate
  text combined, **plain text with no URL rejected** (`.unsupportedContent`,
  never queued — including a very-long bare-text case, to confirm length
  alone doesn't make it importable), unsupported scheme/file URL rejected
  both with and without fallback text, an unsupported URL attachment that
  still succeeds when the fallback text itself contains a real URL, blank
  content, normalization, truncation, Codable round-trip, and
  `hasRequiredURL` for both a builder-produced and a simulated legacy
  URL-less value).
- **Unit — queue**: `KitchenManagerTests/SharedImportQueueTests.swift`
  (enqueue/read/remove/removeAll, FIFO order, duplicate-URL handling inside
  and outside the window, max-size enforcement without evicting existing
  entries, corrupted-file recovery and reuse afterward, schema-version
  filtering, App-Group-unavailable path, "read doesn't consume"). The queue
  itself is content-agnostic (it doesn't enforce "must have a URL" —
  that's `SharedImportRequestBuilder`'s and the coordinator's job), so
  these tests still use text-only fixtures where that's just exercising
  queue plumbing.
- **Unit — coordinator**: `KitchenManagerTests/SharedImportCoordinatorTests.swift`
  (no pending / one URL / one URL+text / multiple in FIFO order, existing
  modal blocks presentation, successful handoff removes the request,
  snoozing after a failed/cancelled handoff preserves it on disk but hides
  it for the session, a fresh coordinator instance — simulating relaunch —
  resurfaces a snoozed-but-still-queued request, repeated refresh calls
  don't change which request is pending, prefill-text derivation, explicit
  documentation-by-test that there is no auth/guest dependency, and a
  dedicated "legacy/invalid (no-URL) request handling" section: such a
  request is never surfaced, is discarded from the queue on refresh,
  never blocks a subsequent valid URL request, doesn't loop or crash
  across repeated refreshes when it's the only thing queued, and a valid
  URL request is never touched by this pruning).
- **Extension/UI integration**: not automated in this phase. Driving the
  live iOS share sheet from `KitchenManagerUITests` was not attempted
  because host-app UI tests cannot reliably invoke a separate share
  extension process in this simulator setup; fabricating a passing result
  here would misrepresent what was verified. Coverage for that surface is
  the target-build verification plus the manual matrix below.
- Regression: the full existing `KitchenManagerTests` and
  `KitchenManagerUITests` suites pass unchanged (see final report for the
  run).

## Manual validation

Full step-by-step results are in the final report of the implementing
session. Summary: this environment cannot drive the iOS Simulator's GUI
(no `Simulator.app` window process runs here, and the automation tool's
own capability manifest reports iOS Simulator support as disabled), so the
literal "open Safari → share → tap the extension" gesture was **not**
performed and is **not** claimed as verified. What was verified instead,
against the real installed app/extension/App Group (not mocks):

- `KitchenManagerShareExtension` is installed and discoverable by the
  system as a `com.apple.share-services` plugin (`pluginkit -m -p
  com.apple.share-services` lists it).
- The App Group container is actually created and read/write on install —
  not just declared in an entitlements file.
- With a hand-placed queue file containing one legacy no-URL request and
  one valid URL request in the **real** App Group container, launching the
  main app: pruned the invalid entry, kept the valid one, and correctly
  presented the existing Smart Import screen prefilled with that request's
  URL — confirmed with a direct simulator-framebuffer screenshot
  (`simctl io screenshot`, which does not require a GUI window).

Physical-device Safari/Xiaohongshu/YouTube shares and an interactive Notes
plain-text-rejection check remain **unverified** and are a real remaining
gap — see "Remaining risks" in the final report.

## Known limitations (Phase 1)

- **Plain text with no URL is not supported at all.** The extension
  rejects it outright ("暂时只支持包含网页链接的分享内容。") and never
  queues it — it never reaches the main app, so there is no "queued but
  then fails" inconsistency. True text-only AI import
  (`AIRecipeParseService.parse(text:)`, which exists but is not wired into
  any UI path — pre-existing, not changed by this phase) is deferred to
  Share Import Phase 2.
- Because the system `NSExtensionActivationRule` can't distinguish
  "text containing a URL" from "plain text", Kitchen Manager can still
  *appear* in the share sheet for a bare-text share (e.g. Notes) — it just
  refuses and shows an error rather than queuing anything for that case.
- `originalHostBundleIdentifier` is always `nil` — no public API reliably
  identifies the sharing host app.
- No automatic main-app launch/foregrounding from the extension: the user
  sees a save confirmation and closes the share sheet; the pending import
  surfaces the next time they open or return to Kitchen Manager. No deep
  link or custom URL scheme exists in this project to do otherwise, and
  none was added.
- No image, video, or file sharing; no in-extension AI parsing, OCR, ASR,
  or video download; no share history/management UI; no batch editing of
  multiple pending requests; no platform-specific (Xiaohongshu/Douyin)
  cleanup inside the extension — all deferred, some possibly to Phase 2.
- Rapid successive shares beyond 20 pending, unhandled, queued requests
  will be rejected (not evicted) until the user opens the app and clears
  the backlog.

## Next phases (not implemented here)

- **Share Import Phase 2**: true text-only import — wiring
  `AIRecipeParseService.parse(text:)` (or an equivalent path) into a real
  UI so a plain-text share with no URL can actually be parsed and saved,
  then relaxing the extension/coordinator's "must have a URL" gate to
  match. Until that pipeline exists end-to-end and is tested, plain text
  stays rejected at the extension boundary as described above.
- Platform-specific normalization for Xiaohongshu/Douyin/YouTube inside the
  *existing* main-app import layer (not the extension).
- An explicit "clear pending share" affordance surfaced in the main app UI
  (the coordinator's `discard` API already exists for this).
- Image/video share support, if ever prioritized, as a distinct phase with
  its own review of the "extension does not..." boundaries in this doc.
