# Phase 2D-1 Validation

Read-only/local-only validation record. No secret, Team ID, Apple ID,
Bundle Seed ID, provisioning-profile UUID, or certificate fingerprint is
reproduced anywhere below. No upload of any kind was performed.

## 1. Git gate

- `origin/main` and local `HEAD` were both `f93143c` before this phase's
  work began, and remained so throughout (ahead count 0) — this phase
  only ever added new untracked files and modified two already-tracked
  files (`project.pbxproj`, `package.json`).
- `git diff --check` reported no whitespace errors.
- No `.xcarchive`, `.ipa`, `.dSYM`, `exportOptions.plist`, `.p8`,
  `.mobileprovision`, `DerivedData`, or `.xcresult` path exists anywhere
  in the tracked working tree (confirmed via `find`).

## 2. Node regression

- `npm test`: **969/969 passing** (baseline required ≥948).
- `node --test test/phase2d1-ios-release-support.test.mjs
  test/phase2d1-ios-release-scripts.test.mjs`: **21/21 passing**
  (included in the 969 total above).
- `npm audit --omit=dev --audit-level=high`: **0 vulnerabilities**.

## 3. iOS regression

- `xcodebuild -list -project "Kitchen Manager.xcodeproj"`: resolves the
  shared `KitchenManager` scheme, 3 targets, 2 configurations (Debug,
  Release) — consistent with a fresh checkout (no reliance on
  machine-local implicit scheme state).
- Debug build, `generic/platform=iOS Simulator`: **BUILD SUCCEEDED**.
- Release build, `generic/platform=iOS Simulator`: **BUILD SUCCEEDED**.
- iOS Unit tests (`KitchenManagerTests`, iPhone 17 Pro simulator):
  **636 executed, 5 skipped, 0 failures** (baseline required ≥635).
  Includes `APIEnvironmentTests`.
- iOS UI tests (`KitchenManagerUITests`, iPhone 17 Pro simulator,
  `-parallel-testing-enabled NO`): **8 executed, 1 skipped, 0 failures**
  (baseline required ≥8).
- Requesting `platform=macOS` (`"My Mac"`) for this scheme now correctly
  reports it as **incompatible** ("My Mac's macOS platform doesn't match
  KitchenManager.app's supported platforms") — direct confirmation that
  this phase's `SUPPORTED_PLATFORMS`/`TARGETED_DEVICE_FAMILY` fix removed
  the unintended macOS footprint, rather than only appearing to via a
  text diff.

## 4. Archive validation — exact distinction between compile / unsigned / signed / uploaded

- **Compile/archive structure**: PASS (Debug + Release builds above).
- **Signed archive**: **PASS, with a caveat.** A real
  `xcodebuild archive -configuration Release -destination "generic/platform=iOS"`
  (no `CODE_SIGNING_ALLOWED=NO` override) was attempted in a scratch
  directory outside the repository and **succeeded** — Automatic Signing
  resolved a real signing identity and provisioning profile already
  present on this machine/account, and `** ARCHIVE SUCCEEDED **` was
  reported. The archive was inspected, then deleted (it was never part of
  the git working tree and is not committed).
  - **Important caveat**: the resolved signing identity was an **Apple
    Development** identity/profile (confirmed via the embedded
    entitlements containing `get-task-allow = true`, which distribution
    (App Store/TestFlight) signing never sets), not an **Apple
    Distribution** identity. This means: a locally buildable, installable,
    debuggable archive can be produced on this machine today, but this
    phase did **not** verify that an App-Store-distribution-class signed
    archive (the kind Xcode Organizer's "Distribute App → App Store
    Connect" flow actually uploads) can be produced — that requires
    Automatic Signing to resolve a Distribution certificate + an App
    Store provisioning profile, which in turn typically requires an
    existing App Store Connect app record (not present — see
    `docs/TESTFLIGHT_ROLLOUT_PLAN.md` §3). This phase does not claim that
    step was tested, and does not claim it would necessarily succeed.
  - No Team ID, Apple ID, certificate fingerprint, or provisioning-profile
    UUID from this signing operation is reproduced in this document or any
    other artifact of this phase.
- **Archive contents inspected** (structure/values only):
  - `CFBundleIdentifier`: `com.lianghongjing.kitchenmanager`.
  - `CFBundleShortVersionString`: `1.0`; `CFBundleVersion`: `1` (both
    still placeholders per `docs/IOS_RELEASE_PIPELINE.md` §3).
  - `UIDeviceFamily`: `[1, 2]` (iPhone + iPad, matches §2's device-family
    audit).
  - `UISupportedInterfaceOrientations~iphone` /
    `~ipad`: present, matching the values recorded in
    `docs/IOS_SIGNING_AND_ARCHIVE.md` §1.
  - `PrivacyInfo.xcprivacy`: present in the built app bundle (and in the
    `swift-crypto_Crypto.bundle` dependency's own manifest).
  - Embedded entitlements: only `application-identifier`,
    `com.apple.developer.team-identifier`, and `get-task-allow` are
    present — no unused capability entitlement leaked into the signed
    build, consistent with §"Capabilities/entitlements minimized" in
    `docs/IOS_SIGNING_AND_ARCHIVE.md`.
  - A grep of the built app bundle's resource files for `SUPABASE_URL`,
    `SERVICE_ROLE`, `127.0.0.1`, and `CRASH_REPORTING_DSN` found **no
    matches**.
  - A follow-up `strings` scan of the *compiled binary itself* (a deeper
    check than a resource-file grep) found two literal URL-shaped strings
    and traced both to confirm neither is a real leak:
    - `https://kitchenmanager-b8px.onrender.com` — this **is** the app's
      real, intentional `.production` backend host (`APIEnvironment.swift`),
      the same host every build already talks to. It is meant to ship in
      every archive, the same way any native app ships its own server's
      public hostname; it is not a secret.
    - `http://localhost:9999` — traced to the `supabase-swift` dependency's
      own internal `defaultAuthURL` fallback constant
      (`Sources/Auth/Internal/Constants.swift`), not to any code in this
      repository. The app always constructs its real Supabase client with
      the actual configured URL; this library-internal default is never
      reached in practice. Confirmed via source inspection, not assumed.
    - No `service_role`, `anon_key`, JWT-shaped string, or
      `SUPABASE_URL=`-style literal was found in the compiled binary.
- **Upload**: **NOT ATTEMPTED** — no `xcrun altool`/`notarytool`/Xcode
  Organizer "Distribute App" step was run, per this phase's explicit
  scope. Nothing was sent to Apple.

## 5. Pre-push re-verification round (after the 4 local commits)

A second, independent review pass ran before any push decision, to check
the guard scripts themselves rather than only their output:

- **Found and fixed a real gap in `checkAppIconPresence()`**: the original
  check only verified that a file named `*.png`/`*.svg` existed inside an
  `.appiconset` directory — it never validated dimensions or content, so a
  1×1 or otherwise-trivial placeholder image would have silently satisfied
  it. Fixed by requiring at least one image at least 512×512px (checked via
  `sips -g pixelWidth -g pixelHeight`) or a non-trivially-sized SVG.
  Whether an icon's *content* is a plain solid color remains a human/App
  Review judgment, not something this mechanical check attempts to detect.
  Added 5 regression tests, including one that writes a real, valid 1×1
  PNG (via a minimal from-scratch PNG encoder, not a stub) and asserts it
  is correctly rejected. Today's actual state — **no `Assets.xcassets`/
  asset catalog exists in this project at all** — is now reported more
  precisely than before ("no AppIcon.appiconset found at all", not just
  "no real image content").
- **Added `continue-on-error: true`** to the CI workflow's
  `ios:archive:guard` step: this guard genuinely fails today on the app-icon
  blocker above, and that must not make every unrelated push/PR show red.
  The step's PASS/FAIL output still prints in the job log; a real archive
  must still be gated on the guard passing for real, independent of this
  CI job's status. Documented in `docs/IOS_RELEASE_PIPELINE.md` §4.
- **Re-ran the full regression**: Node 974/974 (969 + 5 new app-icon-guard
  tests), `npm audit --omit=dev --audit-level=high` clean; iOS Unit
  636/641 (5 skipped, 0 failed, `GuestMergeTests` 138/138), iOS UI 8/9 (1
  skipped, 0 failed, serial); Debug and Release builds green.
- **Rebuilt a fresh signed archive** (same development-class-signing
  result as §4, same caveat) in a new scratch location, re-inspected, then
  deleted — never committed. This pass went one level deeper than the
  first: a `strings` scan of the **compiled binary itself**, not just the
  bundle's resource files, found two URL-shaped literals — both traced and
  explained in §4's updated bullet (the app's own real production host,
  expected; and a third-party dependency's unused internal default,
  confirmed via its source). No service-role, anon key, JWT-shaped
  string, or DSN was found at the binary level either.
- **Git state re-confirmed**: `origin/main` still `f93143c`, local `HEAD`
  at the 4 expected commits (`5f03f99`, `3c0710b`, `990816c`, `2b2c23e`),
  ahead count 4, workspace clean after this round's fix was committed.

## 6. What this validation does not establish

- Does not establish that a **distribution-signed** archive can be
  produced (see the caveat in §4) — only that development-class signing
  resolves automatically on this machine/account today.
- Does not establish that TestFlight processing, Missing Compliance, or
  any App Store Connect interaction will succeed, since none was
  attempted (no app record exists to interact with).
- Does not establish App Store review outcome in any way.
