# iOS Settings Experience — Phase UI-5A

## Goals

Presentation-only redesign of the native 我的 / Settings screen: clearer
information hierarchy, a guest-first account area, coherent section grouping,
scannable rows, and full Dynamic Type / VoiceOver / Dark Mode support — with the
destructive local-data action separated from ordinary settings.

Nothing about authentication, sync, reminders, backup, appearance persistence, or
the clear-local-data mutation changed. This phase touches only how Settings is
presented.

## Implemented hierarchy

| # | Section | Contents |
| --- | --- | --- |
| 1 | 账号 | Account/guest entry row + optional account error, with the guest explanation as a section footer |
| 2 | 外观 | 显示模式 picker |
| 3 | 菜谱 | 菜谱库模式 picker + optional recipe-library error |
| 4 | 提醒 | 食材到期提醒, its three lead-time toggles, 常备食材补货提醒; footer about the permission prompt |
| 5 | 常备食材 | 管理常备货架 → `PantryStaplesView` |
| 6 | 数据 | 备份与恢复 → `BackupRestoreView` |
| 7 | 关于 | 版本 + privacy note |
| 8 | *(unnamed, last)* | 清除全部本地数据 + "此操作无法撤销" footer |
| 9 | 开发者 | `#if DEBUG` only, unchanged, and only when the smoke controller is available |

Changes from the previous order:

- **管理常备货架 moved out of 提醒** into its own 常备食材 section. Managing the
  pantry shelf is a pantry preference, not a notification setting; it sat among
  the reminder toggles purely by accident of growth. Same destination.
- **清除全部本地数据 moved out of 数据** into its own trailing section. It
  previously shared a section with 备份与恢复, so a destructive action sat one row
  below an ordinary one.
- Section names 外观 / 菜谱 / 提醒 / 数据 / 关于 are deliberately unchanged: they
  are asserted by `test/ios-native-core-alignment.test.mjs`, and single-purpose
  sections are conventional in iOS Settings.

## Guest-first design

The account row now reads as a complete state rather than a deficiency:

- **游客模式** — the mode, first.
- **本机功能已全部可用** — plain statement that nothing is missing locally.
- **登录或创建账号** — the action, tinted, so the destination is obvious.

The previous row was `LabeledContent("游客模式", value: "登录或创建账号")`, where the
action was rendered as a trailing *value*, reading like a status rather than
something to tap.

The nuanced explanation moved from an in-section paragraph to the section
**footer**, which is where iOS puts this kind of qualification. Its wording is
**byte-identical** to before: local use needs no sign-in, signing in prepares
future cross-device sync and can optionally merge local inventory to the family
cloud, and shopping lists, plans, and recipes stay on-device.

An earlier draft shortened it by one word ("继续"), which broke two static
contracts that pin the exact string — `test/ios-native-auth-phase1.test.mjs` and
`GuestMergeUIPhase2B3UITests`. The wording was restored rather than churning those
tests: UI-5A's improvement is hierarchy, not rewording, so there was no
user-facing gain to justify the contract change. It now lives in
`SettingsView.guestAccountFooter` so the new UI test asserts the same constant the
screen renders instead of a hand-copied duplicate.

Guest mode is never styled as an error, warning, or disabled state, and no
promotional copy was added.

## Accessibility behavior

- The account row is one combined VoiceOver element reading mode → status →
  action, in that visual order, inside a `NavigationLink` (so it keeps its button
  and disclosure semantics).
- `SettingsAccountRow` stacks vertically at **every** type size, so the action
  text can never be squeezed against the disclosure chevron. There is no
  horizontal layout to break at large sizes.
- Row symbols are capped at `.xxLarge` (`SettingsChromeMetrics.symbolTypeLimit`)
  so glyphs stay in their slot; **all text keeps unrestricted Dynamic Type**.
- No `minimumScaleFactor` anywhere, no fixed row or text heights, no
  `GeometryReader`. Rows grow taller and copy wraps.
- Interactive rows carry `minHeight: 44`.
- Icons are `accessibilityHidden(true)`; no information is conveyed by icon or
  colour alone — the destructive action is identified by its wording, its
  `.destructive` role, *and* its isolated position, not only by red text.
- Stable identifiers were added so tests no longer depend on copy:
  `settings.account.entry`, `settings.account.guest.footer`,
  `settings.account.error`, `settings.appearance.picker`,
  `settings.recipeLibrary.picker`, `settings.recipeLibrary.error`,
  `settings.expiryNotifications.toggle`, `settings.stapleNotifications.toggle`,
  `settings.pantry.manage.link`, `settings.backup.link`,
  `settings.about.version`, `settings.cleardata.button`.

### Bottom clearance

One Form-level `safeAreaInset(edge: .bottom)` spacer of 72pt
(`SettingsChromeMetrics.bottomClearance`) — never per-row padding, no
screen-height calculation. The trailing destructive row and the About footer come
to rest above the **expanded** floating tab bar. UI coverage measures against the
tab bar's own reported `frame.minY`, captured before any scrolling, because
`.tabBarMinimizeBehavior(.onScrollDown)` shrinks the bar once the form moves.

`SettingsChromeMetrics` is intentionally a separate type from
`InventoryChromeMetrics` rather than importing an Inventory-named type into
Settings; the clearance value matches because both screens sit under the same bar.

## Dark Mode behavior

All colours are semantic: system `Form`/`Section` chrome, `.secondary` for
supporting copy, `.tint` for the account action, and the system `.destructive`
role for the clear-data button. No hard-coded colour values were introduced, so
account, preference, reminder, pantry, data, about, and destructive sections all
follow the system palette. Verified through the existing
`UITEST_FORCE_DARK_APPEARANCE` DEBUG path — no new appearance mechanism, and
nothing Release-visible.

### Appearance-contamination trap

The app's DEBUG appearance hook resets the persisted `appearance` preference only
for launches carrying *some* `UITEST_`-prefixed argument. The first draft of these
tests launched with no such argument (only
`-UIPreferredContentSizeCategoryName`, or nothing at all), so the reset never
fired and every non-dark test inherited the `appearance=dark` written by the dark
test in the same file — the "standard" screenshot came out dark, showing
显示模式 = 深色.

The fix is test-side only: every launch now passes a benign
`UITEST_SETTINGS_EXPERIENCE` argument, which matches no seed but satisfies the
hook's prefix check, so non-dark launches reset to `.system` and the dark launch
still resolves to `.dark`. No production change was needed; the hook itself was
already correct.

## Destructive-action safety

- Still `Button("清除全部本地数据", role: .destructive)` → `isShowingClearDataAlert`.
- Alert title, message, `清除` (`.destructive`) and `取消` (`.cancel`) are
  byte-identical to before.
- The mutation is still exactly `store.clearAllLocalData()` +
  `recipeStore.clearLocalData()`.
- It is now visually and structurally separated: its own trailing section, with a
  short "此操作无法撤销，且不会影响远端菜谱库。" footer.
- Deletion was **not** made easier to reach — it moved further from ordinary rows.
- The UI test opens the confirmation, asserts both buttons, screenshots it, then
  **cancels**. No test executes the destructive action.

## Unchanged behavior

Guest local usability; sign-in/sign-up requests; auth state restoration; Keychain
and session handling; account error handling; sync; guest merge; household/family;
reminder permission requests; reminder scheduling; persisted reminder values;
appearance persistence; recipe-library mode persistence; backup export; backup
import; backup file type and payload; restore replacement; backup error handling;
clear-local-data mutation scope and confirmation semantics; existing navigation
destinations; sign-out; account deletion; reauthentication; ownership transfer;
irreversible-action roles and wording.

No model, store, service, API, persistence, SwiftData, or migration code was
touched. All existing bindings and action closures are reused as-is — no action
was reimplemented.

## Excluded UI-5B scope

This phase makes **no claim** about signed-in lifecycle presentation. The
signed-in branch was updated only to use the same row component; it was not
designed, exercised, or screenshotted, because UI-5A deliberately adds no
deterministic signed-in fixture. Signed-in account/household/sync presentation,
sign-out, deletion, and reauthentication presentation belong to UI-5B.

## Tests

New `ios-native/Kitchen Manager/KitchenManagerUITests/SettingsExperienceUITests.swift`:

1. Guest Settings at standard type — account status first, local usability stated,
   sign-in reachable, ordinary controls present.
2. Core entries reachable — appearance, both reminder toggles, pantry, backup,
   about, destructive entry.
3. Clear-local-data confirmation — opens, destructive and cancel both present,
   ordering separated from backup, then **cancelled**.
4. Accessibility XXXL — account content on the first screen, footer not truncated
   (asserted via absence of an ellipsis), backup and destructive rows reachable and
   above the expanded tab bar.
5. Standard-size bottom clearance.
6. Dark Mode via `UITEST_FORCE_DARK_APPEARANCE`.
7. Backup entry navigation to the existing destination — no export, no restore.

`GuestMergeUIPhase2B3UITests` was updated for the **element** contract only: the
guest row is now one combined accessibility element, so `游客模式` is matched via
`settings.account.entry`'s label rather than as a standalone static text. The
footer string it asserts is unchanged, and its behavioural assertions — no merge UI
before sign-in, no manual sync UI, tapping through reaches 登录 — are unchanged.

## Rollback boundary

Reverting this phase means reverting the `SettingsView` body, the two new
presentation helpers (`SettingsChromeMetrics`, `SettingsAccountRow`), the guest
footer constant in `MainFeatureViews.swift`, the new UI test file, and the
`GuestMergeUIPhase2B3UITests` contract update. No data, schema, or persisted value
changes, so rollback needs no migration and cannot affect stored user data.
