# iOS UI Foundation Phase 0

## Goal

Phase UI-0 establishes a small presentation-only foundation for feedback and
accessibility. It corrects known semantic errors without changing navigation,
business state machines, persistence, sync, authentication, or import logic.

## Scope

- Added `AppFeedbackStyle` for success, warning, error, and informational
  system-icon semantics.
- Added `AppFeedbackView`, which combines text and SF Symbol feedback and posts
  one VoiceOver announcement for each displayed message when VoiceOver is on.
- Kept `KitchenStore.inventoryNotice` as a String. The UI recognizes only the
  existing fixed `已添加 … 项食材` success copy; all other notices conservatively
  use error presentation so an unknown migration/persistence failure cannot
  look successful.
- Fixed the Inventory notice success-icon bug and made its dismissal transition
  honor Reduce Motion.
- Changed the Home import toolbar label to `导入与添加` with a matching hint;
  the existing identifier, sheet, icon, and import flow are unchanged.
- Added stable selection semantics to receipt compact rows and replaced fixed
  quantity/unit widths and negative padding with a Dynamic-Type accessibility
  size fallback.
- Added a shared 44-point minimum hit-target token and used it only in the
  affected compact controls.

## Dynamic Type and Reduce Motion

Receipt quantity, unit, and expiry controls use a horizontal layout at regular
sizes and a simple vertical fallback for accessibility Dynamic Type sizes. The
row no longer relies on fixed 52/48-point fields or negative padding. Inventory
and Home feedback use opacity-only transitions when Reduce Motion is enabled;
normal motion retains a small bottom movement plus opacity.

## VoiceOver

Feedback is announced as `成功：…`, `提醒：…`, or `错误：…` with the matching
system icon. Receipt selection controls expose the ingredient name, selected
state, and toggle hint. The Home import control keeps
`home.import.add.button` and now accurately describes all Smart Import choices.

## Previews and tests

Previews cover Inventory success/error, dark mode, large text, receipt selected
and unselected rows, a long ingredient name, and large text. Focused unit tests
cover semantic icons and conservative inventory notice mapping. Existing Home
and Receipt UI tests retain their identifiers and now assert the updated Home
label and the receipt selection control's accessible name/state.

## Explicit non-goals

This phase does not change SwiftData models, KitchenStore persistence behavior,
inventory mutation, shopping or stock-in state, recipes, import parsing,
AI/ASR/OCR, authentication, Guest merge, sync, tabs, navigation architecture,
or PWA/Web code. Other legacy Toast implementations remain unchanged and are
deferred for a later, separately validated cleanup.

## Follow-up

UI-1 should address Home reminder/prompt ordering and remaining Home hierarchy
details. Full physical-device VoiceOver, maximum Dynamic Type, dark mode,
rotation, and Reduce Motion checks remain manual validation work.
