# iOS Home UI Phase 1B — Screenshot-Driven Visual Fixes

## Scope

This follow-up corrects visual and accessibility regressions found in the
real Phase UI-1 simulator review. It is a Home-only presentation pass; it
does not change stores, persistence, sync, authentication, Shared Import,
clipboard detection, stock-in state, recommendation logic, tabs, or Web/PWA.

## Findings from the UI-1 screenshots

- The Today Plan card could show the stock-in CTA, which conflicted with an
  otherwise empty plan.
- The date inherited an English simulator locale while Home copy is Chinese.
- The empty Home navigation bar spent too much vertical space above the
  content.
- The Header and plan card expanded too aggressively at accessibility sizes,
  and a floating tab bar could cover the final Home controls.
- The native paste affordance exposed an English label and made the clipboard
  banner feel taller and looser than its surrounding Home content.
- The last local-issue action could sit under the tab bar, and an unfinished
  plan used the system-blue utensil symbol instead of the Home brand tint.

## Presentation changes

`HomeDashboardSummary` still owns reminder priority and continues to report a
purchased-awaiting-stock-in reminder before other reminder types. A small
presentation-only mapping now gives the Today Plan card an action derived only
from its own state:

- empty: add a Today Plan dish;
- active or partially complete: view Today Plan;
- complete: browse recipes.

Therefore stock-in stays a separate reminder and retains its existing
destination/confirmation flow; it cannot replace the Today Plan CTA.

The Header now uses a fixed `zh_Hans_CN` formatter for the compact
`M月d日 EEEE` date and puts the existing Smart Import action inside the Header.
Home itself hides only its navigation bar; pushed Today Plan and recipe
recommendation destinations retain their existing navigation bars and back
behavior.

## Accessibility, layout, and privacy

- Header chrome caps only its date and greeting Dynamic Type behavior, keeps
  the greeting a VoiceOver heading, and leaves plan, reminder, issue, and
  clipboard content fully Dynamic-Type responsive.
- One Home-level bottom safe-area clearance lets final clipboard and module
  issue actions scroll above the floating tab bar without adding oversized
  padding to each card.
- Clipboard import remains the same native `UIPasteControl`: it is now
  icon-only behind an inert Chinese `粘贴导入` label. Content is still read only
  after the explicit native paste action; no `UIPasteboard` read or alternate
  paste implementation was added.
- The clipboard actions use width-fitting/vertical layouts, and local issues
  retain their existing vertical fallback and identifiers.
- Unfinished plan symbols use `AppTheme.brand`; completed plans remain
  visually secondary. Error and warning semantic colors are unchanged.

## Validation evidence

All commands use the iPhone 17e iOS 27.0 simulator with serial testing and
fresh result bundles:

- Debug simulator build: passed.
- Home summary and presentation tests: 21 passed, 0 skipped, 0 failed.
- Home UI tests at Accessibility 3 Dynamic Type: 10 passed, 0 skipped,
  0 failed.
- Full `KitchenManagerTests`: 777 passed, 5 existing opt-in hosted-smoke
  skips, 0 failed.
- Full `KitchenManagerUITests`: 28 passed, 1 existing hosted-sync smoke skip,
  0 failed (384.4 seconds), in
  `/tmp/kitchenmanager-ui1b-resume-full-ui.xcresult`.
- `git diff --check`: passed.

Focused coverage includes the state/action mapping with a purchased reminder,
Chinese date formatting under a fixed UTC date, header Smart Import reachability,
localized clipboard presentation, stock-in navigation, all existing Home
states, and both seeded module issues.

## Screenshot evidence

The final simulator review is intentionally outside Git at:

`/Users/lianghongjing/Desktop/KitchenManager-UI1-Review/final-fix/`

It contains standard, dark, iPhone SE, and Accessibility 3 captures for empty,
planned, stock-in reminder, clipboard, and module-issue Home states. These
captures verify the localized date, Header import action, distinct stock-in
reminder, native Chinese paste label, bottom scroll clearance, and non-overlap
at large Dynamic Type.

## Explicitly unchanged boundaries

No Phase UI-2 work is included. `HomeDashboardSummary` business priority,
KitchenStore write behavior, SwiftData/persistence, sync and authentication
boundaries, Shopping/stock-in state machine, clipboard detection policy,
Shared Import, recommendation behavior, the five-tab contract, and all
non-Home screens are unchanged.
