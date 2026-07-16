# iOS Signing & Archive (Phase 2D-1)

Status: **pipeline designed and scripted; a real Release archive was
built and signed locally with development-class signing (see §3, §6, and
`docs/PHASE2D1_VALIDATION.md` §4); a distribution-class (App
Store/TestFlight) signed archive was not attempted, since that requires
an App Store Connect app record that does not exist yet; no upload
attempted.**

No Team ID, Bundle Seed ID, provisioning-profile UUID, certificate
fingerprint, Apple ID, or App Store Connect account credential is
reproduced anywhere in this document.

## 1. Current project audit (redacted)

| Item | Value / state |
| --- | --- |
| Bundle Identifier | `com.lianghongjing.kitchenmanager` (app); `.Tests`/`.UITests` suffixed for the two test targets — unique, consistent |
| Product Name | Kitchen Manager |
| Marketing Version | `1.0` (placeholder — never bumped for a real release) |
| Build Number | `1` (placeholder) — see `docs/IOS_RELEASE_PIPELINE.md` for the versioning strategy going forward |
| Deployment target | iOS 27.0 (this environment's SDK) |
| Supported devices | iPhone + iPad (fixed this phase — see §2) |
| Orientation | iPhone: portrait + landscape; iPad: all four, including upside-down |
| App icon | **Missing** — no `AppIcon.appiconset` with real image content exists. This is a real, un-fixed blocker for any actual App Store/TestFlight upload; this phase does not fabricate icon artwork. |
| Launch screen | Configured (`UILaunchScreen` empty dict — a valid, minimal SwiftUI-era launch screen) |
| Display name | "Kitchen Manager" |
| Signing style | Automatic |
| Development Team | Configured (not reproduced here) |
| Debug/Release configurations | Both exist, both use the same committed `Shared.xcconfig` base |
| Scheme shared | **Fixed this phase** — previously no `.xcscheme` file existed anywhere (not even a user-level one); Xcode was relying entirely on an implicit, never-persisted scheme. A real shared scheme now exists at `Kitchen Manager.xcodeproj/xcshareddata/xcschemes/KitchenManager.xcscheme`, needed for any CI/fastlane/fresh-checkout build to work reliably. |
| Archive availability | Compile/archive structure validated this phase (see §6); a fully signed archive was not produced |
| Release backend | Still the shared development Supabase project/Render backend (unchanged — see `docs/SUPABASE_ENVIRONMENT_TOPOLOGY.md`) |
| Release feature flags | All `NO` in the committed `Shared.xcconfig` |
| Release crash reporting | Abstraction only, `CRASH_REPORTING_ENABLED = NO`, no DSN (see `docs/CRASH_REPORTING.md`) |
| Release environment label | `APIEnvironment.production.label == "production"`, but resolves to the same backend URL as development today |
| Privacy usage descriptions | `NSCameraUsageDescription` only (receipt/recipe photo capture) — matches actual camera usage, no unused description found |
| Entitlements | No `.entitlements` file exists — nothing is over-privileged by default |
| Associated Domains | Not configured |
| Push Notifications | Not configured |
| Keychain Sharing | Not configured (default per-app Keychain only) |
| App Groups | **Was declared, unused — removed this phase** (see §2) |
| Background Modes | Not configured |
| iCloud | Not configured |
| Sign in with Apple | Not configured |
| Hardcoded localhost/dev URL | None found in shipped code — the only `127.0.0.1`/`localhost` references are inside `APIEnvironment.isLoopbackHost`'s own denylist (a safety check, not a live endpoint) |
| Obvious App Store review risk | The missing app icon (hard blocker); the platform-family over-declaration fixed in §2; no other risk found |

## 2. A real finding: unintentional multi-platform footprint (fixed)

The main app target's build settings declared:

```
SUPPORTED_PLATFORMS = "iphoneos iphonesimulator macosx xros xrsimulator";
TARGETED_DEVICE_FAMILY = "1,2,7";  // iPhone + iPad + Apple Vision
ENABLE_APP_SANDBOX = YES;           // macOS App Sandbox — meaningless on iOS
ENABLE_USER_SELECTED_FILES = readonly;  // macOS-only
REGISTER_APP_GROUPS = YES;          // no App Group is used anywhere in the codebase
```

This is Xcode's newer multiplatform-app-template default, never pruned —
there is no Mac Catalyst or visionOS-specific code, UI adaptation, or
testing anywhere in this codebase, and the product itself
(`PROJECT_GUIDE.md`/`.zh.md`) has only ever described an iPhone/iPad app.
Shipping an App Store build that silently also claims macOS/visionOS
support, with zero adaptation or testing on either, is a real review-risk
and user-experience risk (the app would install and likely misbehave on
those platforms). **Fixed this phase**: narrowed to
`SUPPORTED_PLATFORMS = "iphoneos iphonesimulator"`,
`TARGETED_DEVICE_FAMILY = "1,2"` (iPhone + iPad only), removed the three
macOS-only/unused-capability settings. Debug and Release builds were
re-verified green after this change (see `docs/PHASE2D1_VALIDATION.md`).

The test targets (`KitchenManagerUITests`/`KitchenManagerTests`) were
already `iphoneos iphonesimulator`-only — this over-declaration existed
only on the main app target.

## 3. Signing / provisioning

- **Automatic Signing**: enabled (`CODE_SIGN_STYLE = Automatic`).
- **Development Team**: configured in the project file (not reproduced in
  any document or log by this phase's tooling).
- **Bundle ID uniqueness**: `com.lianghongjing.kitchenmanager` is a
  concrete, non-placeholder identifier — confirmed unique from the two test
  target IDs by construction (suffixed `.Tests`/`.UITests`).
- **Archive on this machine**: compile/link/archive-structure succeeds
  (see §6), **and a real signed Release archive was actually produced**
  this phase (in a scratch location outside the repository, then
  deleted — never committed). Automatic Signing resolved a signing
  identity and provisioning profile already present on this
  machine/account without any manual intervention.
  - **This was development-class signing, not distribution-class**: the
    archive's embedded entitlements contain `get-task-allow = true`,
    which only development signing sets (App Store/TestFlight
    distribution signing never does). This phase did not verify that
    Automatic Signing can additionally resolve an **Apple Distribution**
    certificate + an **App Store** provisioning profile — that is a
    separate resolution step Xcode Organizer performs during "Distribute
    App", typically gated on an existing App Store Connect app record
    (which does not exist yet). See `docs/PHASE2D1_VALIDATION.md` §4 for
    the exact commands, findings, and this caveat spelled out in full.
  - Whether a fully **distribution**-signed archive can be produced still
    depends on:
    - An active, paid Apple Developer Program membership on the
      configured team (not verified by this phase — requires the account
      holder to confirm).
    - An App Store Connect app record existing for
      `com.lianghongjing.kitchenmanager` (does not exist yet).
    - Automatic Signing successfully resolving a *distribution*
      certificate + provisioning profile once the above exist — not
      attempted this phase.
- **App Store Connect app record**: required before any TestFlight build
  can be processed — does not exist yet (a manual, account-level action;
  see `docs/TESTFLIGHT_ROLLOUT_PLAN.md` §"Manual prerequisites").

## 4. Capabilities / entitlements — minimized

No `.entitlements` file exists, and after §2's fix, no capability is
registered via build settings either. Every capability this phase's
checklist asked about (Push, Background Modes, Associated Domains, Sign in
with Apple, Keychain Sharing beyond default, App Groups, iCloud, HealthKit,
Location, Photos, Microphone, Bluetooth, Local Network) is **off**, and
none is used anywhere in the codebase. `NSCameraUsageDescription` is the
one privacy-usage description present, and it matches real, existing camera
usage (receipt/recipe photo import) — no unused description found to
remove.

**Recommendation going forward**: do not add any capability preemptively.
If a future feature needs one (e.g., a Share Extension needing an App
Group), add it at that time, scoped to exactly what's needed, and revisit
this document.

## 5. What still blocks a real signed archive / upload

1. **App icon** — no real 1024×1024 (and derived sizes) artwork exists.
   This phase does not create placeholder or AI-generated icon artwork;
   real icon design is a product/design decision for the user.
2. **Apple Developer Program membership status** — not verified by this
   phase (requires the account holder).
3. **App Store Connect app record** — does not exist yet (manual,
   account-level action).
4. **Real version bump** — `1.0`/build `1` are still placeholders; a real
   release should bump these deliberately (see
   `docs/IOS_RELEASE_PIPELINE.md`).

None of these are code defects — they are pending human/account-level
actions or asset creation, listed explicitly rather than silently assumed.

## 6. Archive validation actually performed this phase

See `docs/PHASE2D1_VALIDATION.md` for the exact commands and their results.
Summary:

- `xcodebuild -list` — succeeds, using the newly-shared scheme.
- Debug and Release **build** (not archive) for `generic/platform=iOS
  Simulator` — succeed.
- A **Generic iOS Device, Release-configuration archive** was attempted
  and **succeeded, signed** — but with a development-class identity/
  profile, not a distribution-class one (see §3's caveat). The archive
  was built in a scratch location outside the repository and deleted
  after inspection; it was never committed.
- No upload of any kind (TestFlight, App Store, notarization) was
  attempted — none is possible without a distribution-signed archive and
  the account-level setup (App Store Connect app record) this phase does
  not perform.
