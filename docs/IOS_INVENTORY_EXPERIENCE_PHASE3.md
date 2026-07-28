# iOS Inventory Experience — Phase UI-3

## Scope

Phase UI-3 is a presentation-only refinement of the native iOS Inventory tab.
It does not alter SwiftData, models, storage, business rules, sync,
authentication, or the inventory navigation architecture.

## Problems with the previous Inventory screen

- The first screen opened on a row of three equal-weight metric tiles (在库 /
  快到期 / 已缺货). Every count was styled identically, so nothing indicated
  which number the user should act on, and the tiles pushed the actual food
  list below the fold.
- Food itself was rendered as a `LazyVGrid` of tinted cards with a per-card
  expiry progress bar. The tint plus the bar encoded expiry twice, the cards
  competed with each other for attention, and long ingredient names truncated
  to a single line.
- There was no way to find a specific ingredient other than scanning the whole
  grid.
- The primary "add food" action was buried as the first row of a `+` menu,
  giving it the same weight as receipt scanning and pantry creation.
- The staple section was headed "常备货架" while the rest of the app called the
  same concept 常备食材.

## New information hierarchy

- Inventory is a searchable, inset-grouped native list instead of a grid of
  metric cards.
- Sections are ordered by what the user came to do: availability summary →
  食材 → 常备食材 → 补货建议 → 最近消耗. Each header carries its own count
  (`食材 10 项`), so counts sit next to the content they describe.
- Food rows give name, quantity, and expiry state distinct typographic roles.
  Status is always conveyed as text *and* an SF Symbol rather than by colour
  alone, and the tinted card background and duplicate progress bar are gone.
- Each row stays a single VoiceOver element with a detail-navigation hint.
- `添加食材` is now its own toolbar button. Receipt scan and pantry creation
  moved into an adjacent overflow menu. No input or import flow was replaced.

## Summary de-noising

The three equal tiles collapse into one quiet row: the in-stock count is the
only prominent value, and a single secondary line appears *only* when there is
something actionable — expiring items first, otherwise low-stock items. When
neither applies, the summary is just the in-stock count. VoiceOver reads the
whole row as one sentence.

## Search and filtering

`.searchable` filters the presentation of the current inventory by name only.
It never writes data and never changes the existing focus filter, pantry
filter, detail, or deletion behaviour. While a search is active the summary,
restock suggestions, and 最近消耗 rows are hidden so results are not diluted;
clearing the query restores them. A no-match query gets its own
`ContentUnavailableView` rather than an empty list.

## Pantry (常备食材) empty state

- Renamed from 常备货架 to 常备食材 for consistency with Settings and the
  restock copy.
- The empty state shows one title, one explanatory line, and one CTA. The
  redundant `常备食材 0 项` section header that previously sat directly above
  the identically-worded `还没有常备食材` title was removed.
- The CTA has a ≥44pt hit target, a stable identifier
  (`inventory.staple.empty.add.button`), and still opens the pre-existing
  `AddPantryStapleView` sheet. No new pantry capability was introduced.

## Accessibility fallbacks

Dynamic Type is **not** restricted app-wide, and it is not restricted for food
content. Ingredient names, quantities, and status text scale without limit; rows
simply grow taller. What is bounded is page *chrome*, collected in one place as
`InventoryChromeMetrics`:

| Element | Behaviour at Accessibility sizes |
| --- | --- |
| Navigation title 食材 | Large title at default sizes; collapses to the inline title at Accessibility sizes. Still a VoiceOver heading, never truncated, no `minimumScaleFactor`. |
| Availability summary | Stacks vertically (`13 项` / `在库` / `2 项即将到期`), count drops from `.title3` to `.headline`, and the row is capped at `.accessibility1` so the overview cannot outgrow the list it summarizes. |
| Section headers | `.subheadline` semibold, capped at `.accessibility1`, so 食材 / 常备食材 stay heading-weight instead of scaling into display titles. Marked `.isHeader`. |
| Staple filter menu | Same cap as headers, with a 44pt minimum height. |
| Row status glyph | Tracks text size up to `.xxLarge`, then holds, so it stays inside its fixed 28pt slot instead of crowding out the food name. |
| Toolbar `+` / `…` | Glyphs capped at `.xxLarge` with 44×44 minimum hit targets. The menu's own rows keep full Dynamic Type. |
| Search field | Placement becomes `.navigationBarDrawer(displayMode: .always)` so the drawer sizes to its own content. See "The empty grey capsule" below. |

### Row layout at Accessibility sizes

The row becomes one explicit left-aligned column in a fixed order:

```
HStack(alignment: .top) {
    statusIcon
    VStack(alignment: .leading) {
        name
        expiry status
        quantity
    }
}
```

Nothing is pinned to the trailing edge, so the quantity can never be squeezed
into a narrow column or wrapped onto a line that reads as unrelated. An earlier
attempt used `ViewThatFits` with a side-by-side arrangement first; it kept
choosing that arrangement, which is exactly what pushed the quantity right and
wrapped it. Every string keeps unrestricted Dynamic Type — no `lineLimit(1)`, no
`minimumScaleFactor`; the row simply grows taller.

At default sizes the layout is unchanged: name and status on the left, quantity
trailing with a higher layout priority so a long name wraps rather than squeezing
the quantity out.

`PantryStapleRow` follows the same principle, and additionally splits its detail
caption so 当前数量 and 最低库存 each get a full-width line, with the stepper below
them rather than beside a squeezed text column.

The existing Reduce Motion-aware inventory feedback transition remains in place;
its presentation no longer adds a shadow. All colours are semantic and work in
Dark Mode and increased contrast.

## Bottom tab bar clearance

The app uses an iOS 26 floating `TabView` with
`.tabBarMinimizeBehavior(.onScrollDown)`. The Inventory list previously scrolled
its last rows underneath that bar.

The clearance is a single Inventory-level empty spacer in the bottom safe area:

```swift
.safeAreaInset(edge: .bottom) {
    Color.clear
        .frame(height: InventoryChromeMetrics.bottomClearance)  // 72pt
        .accessibilityHidden(true)
}
```

One inset, never per-row padding, and a fixed value rather than a screen-height
calculation or a `GeometryReader` layout system. An earlier attempt used
`.safeAreaPadding(.bottom, 44)`, which did not reserve enough room.

UI coverage measures against the tab bar's own reported `frame.minY` — never a
hardcoded coordinate — and captures it *before* any scrolling so it reflects the
**expanded** bar. `.onScrollDown` minimizes the bar while the list moves, so
asserting only against the minimized bar would pass while real content sat
underneath the expanded one. Coverage runs at default size, in Dark Mode, and at
Accessibility XXXL.

Measured with the bar expanded at `(0, 761, 390, 83)`, top edge 761pt:

| Appearance | Last row frame | Gap above bar |
| --- | --- | --- |
| Default | `(16, 648, 358, 52.3)` | 60.7pt |
| Dark | `(16, 657, 358, 52.3)` | 51.7pt |
| Accessibility XXXL | `(16, 505.7, 358, 155.3)` | 100.0pt |

A screenshot taken *mid-scroll* still shows the translucent bar over content —
that is inherent to a floating tab bar, not the defect. The defect was content
that could not come to **rest** above it, which the `*-bottom` screenshots and the
table above cover.

## The empty grey capsule

At Accessibility sizes the page title collapses to inline, and an inline
navigation bar always shows the search drawer. With `.searchable`'s default
`.automatic` placement, UIKit pinned that drawer to a fixed ~63pt — too short for
Accessibility XXXL text — so the magnifier glyph and the "搜索食材" prompt were
clipped to nothing and only the drawer's grey capsule painted. The result was a
large, empty, rounded grey block directly under the title.

It was never a skeleton, a loading state, the summary background, an
`opacity(0)`-hidden view, or a UI-test fixture artifact: the accessibility tree
reported a real `SearchField` at `{{16, 101}, {358, 63}}` with
`placeholderValue: '搜索食材'` and a `magnifyingglass` child, none of which was
being drawn.

A launch-argument matrix confirmed both the trigger and the fix:

| Variant | Search field |
| --- | --- |
| inline title + `.automatic` | 63pt — contents clipped, empty capsule |
| large title + `.automatic` | absent (hidden until pulled down) |
| inline title + `.navigationBarDrawer(displayMode: .always)` | **124pt — glyph and prompt both render** |
| inline title + `.navigationBarDrawer(displayMode: .automatic)` | 63pt — same as `.automatic` |

Placement is therefore explicit at Accessibility sizes only; default sizes keep
`.automatic` and its standard hidden-until-pulled-down behavior, so the
normal-size page is untouched. `testSearchFieldIsNeverAnEmptyPlaceholder` asserts
that whenever the field is on screen it carries both its prompt and its glyph and
that its height is at least its content height — the condition that was violated.

## Node static assertion update

Three static test files carried assertions describing Inventory markup that UI-3
legitimately replaced. All three were updated to assert wiring instead of retired
surface strings; no assertion was deleted outright, no `skip` was added, and no
package script or CI workflow was touched.

`test/ios-native-inventory-ui.test.mjs` required the adaptive `LazyVGrid` of
tinted cards and `private struct InventoryExpiryProgressBar`. Both are gone by
design. It now asserts the List presentation (`insetGrouped`, `searchable`, the
`ForEach`/`Button`/`InventoryFoodCard` block, the section header), that expiry is
conveyed as one status phrase *plus* an SF Symbol rather than encoded twice, and
— as new coverage — the `InventoryChromeMetrics` caps, the inline-title switch,
the `ViewThatFits` fallback, and the single bottom inset.

`test/ios-native-inventory-entry.test.mjs` required
`Button("添加食材", systemImage: "square.and.pencil")` and
`accessibilityLabel("录入食材")` — the single plus-menu that UI-3 split into a
dedicated 添加食材 button plus an overflow menu. It now asserts the promoted
primary action, the overflow menu's identifier and contents, that the retired
"扫描小票"/"批量录入" labels stay retired, and that all three actions still
resolve to the pre-existing `RecordFoodSheet` modes and `AddPantryStapleView`.

`test/ios-native-pantry-staples.test.mjs` asserted the old visual structure:
`Text("常备货架")` inside `InventoryView` and the literal `补齐常备货架`. Both
described markup that UI-3 legitimately replaced. They were updated to assert
real wiring instead of surface strings:

1. The staple section and its filter still exist, driven by the same
   `PantryStapleFilter` state and `store.pantryStaples` source.
2. Staple rows still render through the existing `PantryStapleRow`, asserted as
   one contiguous `ForEach`/`Button`/`label` block so the fresh-item loop above
   cannot satisfy it.
3. Tapping a staple still routes through the shared `onSelectItem` detail route,
   and the empty state still opens `AddPantryStapleView`.
4. The accessibility identifiers and labels the focused UI tests drive are
   present.
5. The batch pantry restock action still filters `source == .pantryStaple` and
   feeds every result through `addSuggestion`.

The old visual-structure requirement is now asserted *absent*
(`doesNotMatch(/Text\("常备货架"\)/)`). The `InventoryView` slice was also
narrowed to end at `InventoryNoticeOverlay`, because UI-3 extracted the summary,
header, and row subviews and the previous wider slice would have let those
satisfy assertions meant for the list itself. `"来自常备货架"` (a persisted
shopping-item source value) and Settings' `管理常备货架` link are unchanged data
and navigation, so their assertions were left alone. No other assertion was
removed, and no package script or CI workflow was touched.

Note: `test/ios-native-core-alignment.test.mjs` was inspected and required no
change — it passes unmodified (12/12). The stale Pantry assertions were in
`ios-native-pantry-staples.test.mjs`, not the core-alignment file.

## Additional fixes found by reviewing the real screenshots

Two defects were visible in the regenerated screenshots and are fixed here:

- **`PantryStapleRow` at Accessibility sizes.** The row was a flat `HStack`, so
  the trailing stepper kept its intrinsic width and squeezed the name and detail
  text down to one or two characters per line ("榄 / 油"). It now stacks the
  full-width text above the control at Accessibility sizes, and its cabinet glyph
  is capped like the fresh-inventory glyph. The stepper and status-cycle actions
  still call the same `store.adjustStapleQuantity` / `store.cycleStapleStatus`
  methods — presentation only.
- **The Dark Mode screenshot was not dark.** The UI test passed
  `"-AppleInterfaceStyle", "Dark"` as a launch argument, which silently does
  nothing; `XCUIDevice.shared.appearance = .dark` also failed to reach the app
  before its first render. The screenshot was therefore a duplicate of the light
  one, and Dark Mode was never actually exercised. A DEBUG-only
  `UITEST_FORCE_DARK_APPEARANCE` launch argument now writes the app's own
  `appearance` preference before the first body evaluation, driving the exact
  `preferredColorScheme(.dark)` path a user gets from 设置 → 显示模式 → 深色. Because
  that preference persists in UserDefaults, any UI-test launch without the flag
  explicitly resets it to `.system`, so one dark screenshot cannot tint later
  tests.

## Post-main integration review — 2026-07-28

The branch was updated with a normal `git merge --no-ff origin/main` at
`817b29f3c5962d7ee2cde28e54b8cb9fb23e2886`. The only merge conflicts were the
two documentation files (`CHANGELOG.md` and `PROJECT_STATUS.md`); the current
Home, Clipboard Import, Recipe, Share Extension, and App Icon work was kept
intact. No Inventory production source was changed by conflict resolution.

Post-merge validation on iPhone 17e / iOS 27.0:

- Debug and Release builds: passed.
- Focused Inventory unit tests: 128 passed, 0 failed, 0 skipped.
- Inventory UI: 10 passed, 0 failed, 0 skipped.
- Home + Clipboard UI: 13 passed, 0 failed, 0 skipped.
- Recipe focused UI: 7 passed, 0 failed, 0 skipped.
- Full unit suite: 782 passed, 5 pre-existing skips, 0 failed.
- Full UI suite: 44 passed, 1 pre-existing skip, 0 failed.
- Focused Node static tests: 37 passed, 0 failed, 0 skipped.
- `npm test`: run after documentation reconciliation; result is recorded in
  the PR body and delivery report.
- `git diff --check`: clean.

Fresh post-main screenshots are exported outside Git to
`~/Desktop/KitchenManager-Inventory-UI3-Review/post-main-update/`. The folder
contains the requested 12 named PNGs for normal, search, empty, large,
Dark Mode, Accessibility XXXL/bottom, pantry accessibility evidence, Home
clipboard, Import paste control, and Recipe detail. The pantry file reuses the
captured Accessibility Inventory frame because the empty-state test has no
attachment of its own; no production behavior is inferred from that naming.

The focused and full `.xcresult` bundles remain at:

- `/tmp/kitchenmanager-inventory-phase3-focused-unit.xcresult`
- `/tmp/kitchenmanager-inventory-phase3-focused-ui.xcresult`
- `/tmp/kitchenmanager-inventory-phase3-home-clipboard-ui.xcresult`
- `/tmp/kitchenmanager-inventory-phase3-recipe-ui.xcresult`
- `/tmp/kitchenmanager-inventory-phase3-full-unit.xcresult`
- `/tmp/kitchenmanager-inventory-phase3-full-ui.xcresult`

## Validation evidence

Exact executed/passed/failed/skipped counts, build results, and `.xcresult`
paths for this phase are recorded above and in the pull request body.
Screenshots are deliberately kept out of the repository.

Focused UI regression in `InventoryNavigationUITests` covers normal browsing,
search filtering, empty state, large inventory, Accessibility XXXL first-screen
readability, the Accessibility row's vertical name/status/quantity order, the
search field never rendering as an empty placeholder, bottom tab-bar clearance at
default / Dark Mode / Accessibility XXXL, the pantry empty-state CTA and its
explanatory line, selection routing, and deletion safety.

## Deliberate non-goals

- No inventory sorting, expiry, restock, staple, deletion, or scan rules were
  changed.
- No data model, SwiftData schema, persistence, sync, authentication, Shopping,
  Recipe, Home, Settings, Import, or API change.
- No change to the tab architecture, and no app-wide Dynamic Type restriction.
- No new data fields, services, API calls, background work, or feature flags.
- Inventory detail editing remains the existing Form; this phase is limited to
  browsing, hierarchy, entry organization, and accessibility polish.
