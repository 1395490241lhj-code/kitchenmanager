# TestFlight Rollout Plan (Phase 2D-1)

Status: **workflow and manual-prerequisite checklist designed and
documented; nothing in this plan has been executed — no App Store Connect
app record exists, no build has been uploaded, no tester has been
invited.**

## 1. Internal vs. External TestFlight — policy

| | Internal Testing | External Testing |
| --- | --- | --- |
| Who | Team members already in the App Store Connect team (a small, known, trusted cohort — the same population as today's sideloaded dogfood testers) | Anyone invited by public link or email, outside the team |
| Apple review | Not required (existing build, existing team) | Requires **Beta App Review** before the build is usable by external testers |
| Backend | May continue using the current shared development Supabase project/Render backend — see `docs/IOS_RELEASE_PIPELINE.md` §1's topology decision | **Must not** connect to the unstable dev backend — blocked by default until a separate production/staging backend exists |
| Debug entry points | May remain reachable if a build enables them (should still default to `NO` even here, to keep internal/external builds as close as possible) | Must not be reachable |
| Test/real data mixing | Acceptable — internal testers already use dev/test data | Must not mix — external testers should never see or create data indistinguishable from a future real user's |
| Build expiry | Standard 90-day TestFlight expiry applies | Same |

**Consequence for this phase**: Internal TestFlight is the only channel
this plan prepares as "could plausibly start soon, once the manual
prerequisites in §3 are done." External TestFlight remains blocked until
the production backend condition (`docs/PRODUCTION_ENABLEMENT_READINESS.md`)
is resolved — this plan documents its workflow but does not treat it as
imminent.

## 2. Step-by-step workflow (as designed, not yet executed)

1. **Archive** — `Product > Archive` in Xcode (Release configuration,
   Generic iOS Device), or the equivalent `xcodebuild archive` invocation
   documented in `docs/IOS_SIGNING_AND_ARCHIVE.md`. Preceded by
   `npm run ios:release:check && npm run ios:archive:guard`.
2. **Organizer** — the resulting `.xcarchive` appears in Xcode's Organizer
   window for validation/distribution.
3. **Validate App** — Organizer's built-in pre-upload validation (checks
   entitlements, Info.plist completeness, icon sizes, provisioning
   match) before attempting a real upload.
4. **Distribute App → App Store Connect** — uploads the build.
5. **Processing** — App Store Connect processes the build (typically
   minutes); a failed processing state surfaces via email and the
   Activity tab, not usually requiring a resubmission unless the fix
   requires a code change.
6. **Missing Compliance** — App Store Connect will ask an export-compliance
   question for the first build of a given version unless it's answered
   in advance (see `docs/APP_STORE_METADATA_TEMPLATE.md`
   "Export compliance"); until answered, the build cannot be added to a
   testing group.
7. **Internal Testing group** — add the processed build to the "App Store
   Connect Users" internal group (or a named internal group); internal
   testers receive it immediately, no Beta App Review needed.
8. **External Testing group (future, not this phase)** — requires **Test
   Information** (What to Test notes, feedback email, marketing/support
   URLs) filled in, then submission for **Beta App Review** (similar in
   scope to, but distinct from, full App Store review).
9. **Tester groups** — internal (team members) vs. named external groups
   vs. a public link; this phase assumes internal-group-only.
10. **Build expiry** — TestFlight builds expire 90 days after upload;
    plan to re-upload before expiry for any build kept in active testing.
11. **Crash feedback / rollback** — testers can submit feedback and crash
    logs from the TestFlight app; if a build regresses, distribute the
    previous good build number to the group (TestFlight keeps prior
    builds available until they individually expire) and use
    `docs/PRODUCTION_ROLLBACK_RUNBOOK.md`'s general rollback posture for
    anything backend-side.
12. **Stopping testing** — a build/group can be marked "not testing" from
    App Store Connect at any time without deleting the underlying build.
13. **Release notes ("What to Test")** — must describe real, current
    functionality only; must not reference internal/debug-only behavior
    testers won't see.

## 3. Manual, account-level prerequisites (user must complete — not executed by this phase)

- Active Apple Developer Program membership on the configured team.
- Xcode signed into that Apple ID on the machine performing the real
  archive/upload.
- Apple Developer "Agreements, Tax, and Banking" in good standing in App
  Store Connect (required even for TestFlight-only distribution).
- An App Store Connect **app record** created for
  `com.lianghongjing.kitchenmanager` (Bundle ID must be registered first,
  if not already, via the Apple Developer portal).
- App Privacy ("nutrition label") questionnaire answered in App Store
  Connect — see `docs/APP_STORE_REVIEW_CHECKLIST.md` for the prepared,
  factual answers this phase drafted (not submitted).
- Age Rating questionnaire answered.
- Export compliance / encryption declaration answered (see
  `docs/APP_STORE_METADATA_TEMPLATE.md`).
- Support URL and (if App Store submission is later intended) Privacy
  Policy URL live and reachable.
- Internal TestFlight tester list populated (existing App Store Connect
  team members, or invited by Apple ID email).
- A distribution certificate + provisioning profile resolved (Automatic
  Signing handles this once the above are in place and Xcode is signed
  in) — see `docs/IOS_SIGNING_AND_ARCHIVE.md` §3.
- A demo/test account for reviewers, **only if** External Testing or App
  Store submission is pursued later (Internal Testing does not need one,
  since internal testers already have their own accounts).

None of the above is executed, simulated, or worked around by this phase —
each requires the account holder's direct action.

## 4. What "done" looks like for Internal TestFlight (not yet reached)

Internal TestFlight can be considered actually live only once: the App
Store Connect app record exists, a signed archive has been produced and
uploaded, it has finished Processing, Missing Compliance has been answered,
and at least one internal tester has successfully installed it via the
TestFlight app. **None of these have happened this phase** — see
`docs/PHASE2D1_VALIDATION.md` for exactly what was and wasn't attempted.
