# App Store Metadata Template (Phase 2D-1)

Status: **document template only — no App Store Connect listing has been
created, and no field below has been submitted anywhere.** Every value is
either a factual statement about the current codebase or an explicitly
labeled placeholder/candidate for the user to finalize. No real personal
contact information, address, or account email is filled in.

## App identity

- **App Name candidates**: "Kitchen Manager"; "Kitchen Manager: Inventory
  & Recipes" (fallback if the plain name collides with an existing App
  Store listing — collision has not been checked, since that requires an
  App Store Connect app record, which does not exist yet).
- **Subtitle** (30 chars max, candidate): "Track food, plan meals" — must
  be re-measured against the real character limit before submission.
- **Promotional Text** (170 chars max, candidate, editable post-release
  without a new build): "Keep your kitchen inventory, shopping list, and
  weekly meal plan in sync — sign in only when you want to."
- **Category**: Food & Drink (primary); Productivity/Utilities as a
  plausible secondary — final choice is the user's, not derived from code.
- **Copyright**: `<candidate: full legal name or company name> — to be
  filled in by the user, not guessed>`.

## Description (draft, factual to current feature set only)

> Kitchen Manager helps you track what's in your kitchen, plan what to
> cook, and keep your shopping list up to date. Add items to your
> inventory, plan meals for the week, log what you've used, and manage
> your own recipes — all usable immediately without an account. Sign in
> only if you want your data to sync across devices.

This description deliberately mentions **only** shipped, real
functionality (inventory, shopping list, weekly plan, consumption
tracking, user recipes, optional sync) — it does not mention crash
reporting, rate limiting, or any other implementation detail invisible to
an end user.

## Keywords (candidate, comma-separated, 100 chars max — not yet measured)

`kitchen,inventory,pantry,recipes,meal plan,shopping list,grocery,food
tracker`

## URLs (none of these exist yet — placeholders, not fabricated)

- **Support URL**: `<required before submission — not yet created>`
- **Marketing URL**: optional; `<not yet created>`
- **Privacy Policy URL**: `<required before submission — not yet created;
  must accurately describe what §"App Privacy answers" below states>`

## Age Rating

No violence, no mature content, no gambling, no user-generated content
shared publicly, no unrestricted web access. Expected candidate: **4+**.
Final answer must come from actually completing Apple's age-rating
questionnaire in App Store Connect, not from this document.

## Review Notes (draft, for App Review — not yet submitted)

> This app works fully offline/guest-first with local data only. Signing
> in is optional and enables sync of the same data across the user's own
> devices via our backend. No demo account is required for Guest mode. If
> sync review is needed, a demo account will be provided at that time —
> see "Demo account requirement" below.

## Demo account requirement

- **Not required for Guest-mode review** — every core feature (inventory,
  shopping list, weekly plan, consumption, recipes) works without signing
  in.
- **Required only if App Review specifically needs to test sign-in/sync**
  — a dedicated test account should be created at that time (not a real
  user's account), with credentials supplied only through App Store
  Connect's own Review Notes field, never committed to this repository.

## Export compliance / encryption declaration

The app uses only standard OS-provided HTTPS/TLS (via `URLSession` and the
Supabase/Express backend's standard TLS termination) — no proprietary or
non-standard cryptography is implemented. The standard App Store Connect
answer for this profile is typically "Yes, uses encryption" + "exempt"
(standard HTTPS exemption), but the exact wording must be confirmed by the
user directly in App Store Connect's own questionnaire at submission time,
since Apple's exact question wording changes and this document cannot
submit on the user's behalf.

## Content rights

No third-party copyrighted content (images, text, video, music) is
bundled with the app. All UI copy and (once created) icon artwork must be
either original or properly licensed — this document doesn't assert
compliance for artwork that doesn't exist yet (see the app icon blocker in
`docs/IOS_SIGNING_AND_ARCHIVE.md`).

## Account / data deletion

The app supports Guest mode with fully local data (deletable by the user
uninstalling the app or clearing local data — no account involved). For
signed-in users, an in-account or in-app data-deletion path is **not yet
confirmed to exist** in the current codebase — this must be verified
against the actual account/settings UI before claiming compliance with
Apple's account-deletion requirement (App Store Review Guideline 5.1.1(v)).
This is flagged as an open item for `docs/APP_STORE_REVIEW_CHECKLIST.md`,
not resolved by this document.

## App Privacy answers (draft — see also §"Privacy Manifest / App Privacy" in `docs/IOS_SIGNING_AND_ARCHIVE.md`)

- **Data collected**: account email (only if the user signs in;
  authentication only, not shared/sold); household/inventory/recipe
  content the user enters (only if signed in, for sync purposes).
- **Data linked to identity**: yes, for signed-in users — email and
  content are associated with their account for sync. Guest-mode data
  is local-only and never transmitted.
- **Tracking**: **none** — no advertising identifier, no cross-app/cross-site
  tracking, no data broker sharing.
- **ATT (AppTrackingTransparency)**: **not needed** — the app performs no
  tracking as Apple defines it.
- **Third-party SDKs**: none currently integrated that collect data (crash
  reporting is a no-op abstraction today — see
  `docs/CRASH_REPORTING.md`; this section must be revisited the moment a
  real provider like Sentry is wired in, since that will add a real
  third-party data recipient).

## Contact information checklist (not filled in — user must supply directly in App Store Connect)

- App Store Connect account holder's real name/contact details.
- A support contact reachable at the Support URL above.
- Any App Review contact phone/email required at submission.

None of these are fabricated or guessed here.
