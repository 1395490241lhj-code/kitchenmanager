# App Store Review Checklist (Phase 2D-1)

Status: **checklist and screenshot/device plan only — no screenshot has
been captured, no App Store Connect record exists, nothing has been
submitted for review.**

## 1. Device support & screenshot plan

Current build settings (`TARGETED_DEVICE_FAMILY = "1,2"`,
`SUPPORTED_PLATFORMS = "iphoneos iphonesimulator"` — see
`docs/IOS_SIGNING_AND_ARCHIVE.md` §2) support **both iPhone and iPad**.
This phase does not recommend disabling iPad: the codebase already had
iPad-covering orientations declared (portrait/landscape/upside-down) prior
to this phase's cleanup, and no code inspected this phase suggested
iPad-specific breakage — but this document does not claim iPad UI has been
visually validated either. If a future phase finds iPad layout is
actually broken or untested, disabling iPad support then (by narrowing
`TARGETED_DEVICE_FAMILY` to `"1"`) is a valid, low-cost way to reduce
launch scope — that decision is deferred to whoever actually validates the
iPad UI, not made speculatively here.

**Required screenshot sizes** (per Apple's current requirements):

- **iPhone 6.9-inch display** (e.g. iPhone 16 Pro Max class) — required.
- **iPhone 6.5-inch or 6.7-inch display** — required if no 6.9-inch
  screenshot is supplied for that size class; Apple auto-scales in some
  cases but a dedicated capture is safer.
- **iPad 13-inch display** — required only if iPad support stays enabled
  at submission time.

**Suggested pages to capture** (based on real, shipped screens only):

1. Inventory list (populated with fictional sample data).
2. Add/edit inventory item.
3. Weekly meal plan view.
4. Shopping list.
5. A user recipe detail view.

**Sample data rules** (must be enforced when screenshots are actually
taken, in a future step):

- No real email address, household name, or personal inventory content —
  fictional placeholders only (e.g. "Sample Kitchen", "milk", "eggs").
- No debug UI, diagnostics screen, or dogfood-only entry point visible.
- No TestFlight badge or watermark in the capture.
- No visible crash-reporting/debug console overlay.

**Dark/light strategy**: capture both, if the design supports both
appearances — not verified this phase which appearance modes the app
actually supports; a future step should confirm before committing to
"both" in the real App Store Connect upload.

**Localization strategy**: screenshots should be captured per submitted
localization. Today only one locale's copy has been reviewed in this
phase's work (see `docs/APP_STORE_METADATA_TEMPLATE.md`); if additional
localizations are added later, each needs its own screenshot set.

**This phase does not capture any real screenshot** — no existing
automation for this was found in the repository, and fabricating sample
data/screens without running the real app would risk showing
inaccurate UI.

## 2. Pre-submission review checklist

- [ ] App icon present (1024×1024 + derived sizes) — **currently
      missing**, a real, documented blocker (see
      `docs/IOS_SIGNING_AND_ARCHIVE.md` §5).
- [ ] Marketing Version and Build Number bumped deliberately for the real
      release (currently `1.0`/`1`, placeholders — see
      `docs/IOS_RELEASE_PIPELINE.md` §3).
- [ ] `npm run ios:release:check` passes.
- [ ] `npm run ios:archive:guard` passes (currently blocked only by the
      app icon and, transiently, by workspace-clean state during active
      development).
- [ ] Support URL live and reachable.
- [ ] Privacy Policy URL live and reachable, and accurately reflects
      `docs/APP_STORE_METADATA_TEMPLATE.md` §"App Privacy answers".
- [ ] App Privacy questionnaire answered in App Store Connect, matching
      the drafted answers.
- [ ] Age Rating questionnaire answered.
- [ ] Export compliance answered.
- [ ] Demo account provided **only if** App Review specifically requests
      sign-in/sync testing.
- [ ] Account/data-deletion path confirmed to exist for signed-in users
      (flagged open in `docs/APP_STORE_METADATA_TEMPLATE.md` — App Store
      Review Guideline 5.1.1(v)); if it does not exist, this must be built
      before submission, not glossed over.
- [ ] No debug menu, diagnostics screen, or dogfood/smoke flag reachable
      in the Release build (`scripts/ios-archive-guard.mjs` enforces the
      config-level part of this).
- [ ] No placeholder/Lorem-ipsum copy left in real App Store Connect
      fields at submission time (the drafts in
      `docs/APP_STORE_METADATA_TEMPLATE.md` are starting points, not
      final copy).
- [ ] Screenshots captured per §1, reviewed for accidental real data
      before upload.

## 3. Known, current App Review risk areas

1. **Missing app icon** — an automatic rejection if submitted as-is; must
   be resolved with real, user-approved artwork before any real archive.
2. **Account-deletion path unconfirmed** — if signed-in accounts exist
   but there's no user-facing way to delete an account/data, this is a
   real, specific rejection risk under Guideline 5.1.1(v) and should be
   verified against the actual Settings/Account UI before submission.
   **Until this is confirmed one way or the other, neither External
   TestFlight nor App Store submission should begin** — a
   sign-out/local-data-clear action must never be described or documented
   as "account deletion"; only an actual server-side account/data removal
   counts. Internal TestFlight is not blocked by this (it isn't reviewed
   under the same guideline and stays within the known internal cohort),
   but any future Review Notes submitted to Apple must disclose this gap
   honestly rather than omit it.
3. **Shared dev backend for Internal TestFlight** — not an App Review
   risk per se (Internal Testing isn't reviewed the same way), but a
   sync-related bug in a shared dev environment could surface as tester
   confusion; documented as an accepted Stage-1 tradeoff in
   `docs/IOS_RELEASE_PIPELINE.md`, not something App Review sees directly.
4. **iPad support with unconfirmed layout validation** — low risk (Apple
   rarely rejects for cosmetic iPad issues alone) but worth deciding
   deliberately, per §1, rather than by default.

## 4. What this document does not do

- Does not submit anything to App Store Connect.
- Does not create the App Store Connect app record.
- Does not answer Apple's live questionnaires on the user's behalf beyond
  drafting factual candidate answers for the user to enter themselves.
- Does not assert the app is ready for submission — it explicitly is not,
  per the open items above.
