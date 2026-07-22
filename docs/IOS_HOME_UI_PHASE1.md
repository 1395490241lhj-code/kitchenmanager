# iOS Home UI Phase 1 — Hierarchy and Action Refinement

## Goal

Refine the native Home dashboard as a calm daily triage surface without
changing business decisions, persistence, navigation architecture, or import
privacy behavior.

## Final information hierarchy

1. Date, greeting, optional household name, and quiet account-restoration state.
2. Today Plan as the primary visual container with the single state-derived
   prominent action.
3. The one highest-priority reminder, when one exists.
4. The clipboard import banner, only when the existing detector/policy says to
   show it.
5. Local persistence/module issues.

`HomeDashboardPresentation` is presentation-only and makes the supporting
section order deterministic. Reminder priority remains entirely in
`HomeDashboardSummary`.

## Toolbar and reachable actions

Home now keeps one right-side Smart Import button (`home.import.add.button`)
with its existing sheet, label, hint, and import choices. The duplicate Home
settings button and add-plan menu were removed. Settings remain in the existing
bottom **我的** tab.

Today Plan now offers a contextual `home.today.plan.add.button` when the
state-derived primary action is not already “添加今日菜品”. It opens the
existing `RecipeRecommendationBrowserView`; the recommendation route and
primary-action behavior are unchanged.

## Today Plan, reminder, and clipboard presentation

- The header uses a secondary date eyebrow and the greeting as the Home
  heading. It retains the existing guest/signed-in wording.
- The Today Plan card uses adaptive system surfaces, a restrained separator,
  completed-state de-emphasis, and Home-only brand tint for the primary action.
- Reminder content is one complete tappable card with icon, title, subtitle,
  and chevron. Existing identifiers and destinations are preserved; semantic
  error/warning/brand colors replace direct red/orange usage.
- The clipboard prompt is a smaller banner. It still says that its content is
  read only after the explicit native paste action; detection, Ignore, paste
  permissions, and Shared Import precedence are unchanged.

## Accessibility and adaptation

- The greeting is a VoiceOver heading; supporting header values remain separate
  readable elements.
- Every remaining action retains an individual label/hint and at least the
  shared 44-point minimum hit target where compact.
- Today Plan and clipboard actions switch to vertical layouts at accessibility
  Dynamic Type sizes. No fixed-height container or key-text single-line limit
  was introduced.
- System semantic backgrounds and adaptive theme colors support Dark Mode;
  the reminder also includes a symbol and text rather than relying on color.
- No new motion was added, so the established Reduce Motion behavior for Home
  feedback remains intact.

## Preview coverage

Focused isolated previews cover guest empty Home, signed-in/long household
copy, active/partial/completed plans, purchased-awaiting-stock-in and expired
reminders, clipboard prompt, local persistence issue, Dark Mode, Accessibility
Dynamic Type, and long recipe names. They do not connect to Supabase,
persistence, clipboard detection, or a network request.

## Visual review screenshots

Generated from the current branch on iPhone 17e simulator and intentionally
kept outside Git:

- `/tmp/kitchenmanager-ui1-home-review/empty-home.png`
- `/tmp/kitchenmanager-ui1-home-review/planned-home.png`
- `/tmp/kitchenmanager-ui1-home-review/attention-reminder-home.png`
- `/tmp/kitchenmanager-ui1-home-review/dark-home.png`
- `/tmp/kitchenmanager-ui1-home-review/accessibility-large-home.png`

## Explicitly unchanged boundaries

This phase does not modify `HomeDashboardSummary` business decisions,
`KitchenStore`, `RecipeStore`, SwiftData, persistence, sync, authentication,
Guest Merge, Shopping/stock-in semantics, recommendation logic, clipboard
detection/privacy policy, Shared Import, tabs, `AppNavigationStore`, Today Plan
models, PWA/Web, or non-Home feature layouts.

## Validation

All tests used iPhone 17e (iOS 27.0), serial execution, and fresh result
bundles:

- Debug simulator build: passed.
- Home summary + presentation tests: 18 passed, 0 skipped, 0 failed —
  `/tmp/kitchenmanager-ui1-home-summary-retry.xcresult`.
- `HomeDashboardUITests`: 8 passed, 0 skipped, 0 failed —
  `/tmp/kitchenmanager-ui1-home-ui.xcresult`.
- Full `KitchenManagerTests`: 774 passed, 5 skipped, 0 failed —
  `/tmp/kitchenmanager-ui1-full-unit.xcresult`. The skips are existing opt-in
  `HostedGuestMergeSmokeTests` with no hosted smoke credentials.
- Full `KitchenManagerUITests`: 26 passed, 1 skipped, 0 failed —
  `/tmp/kitchenmanager-ui1-full-ui.xcresult`. The skip is the existing hosted
  sync smoke, which requires development credentials and is unrelated to Home.
- `git diff --check`: passed.

## Suggested UI-2 follow-up

Use the same restraint to review one non-Home surface at a time, beginning with
a separately scoped recipe or inventory pass only after manual device checks
for this Home update.
