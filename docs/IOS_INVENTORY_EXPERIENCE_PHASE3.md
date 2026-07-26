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

Row layout at Accessibility sizes uses a `ViewThatFits`: status and quantity
share a line while they both fit and drop to stacked lines when they do not, so
they can neither overlap nor push the quantity off-screen. At default sizes the
quantity carries a higher layout priority, so a long name wraps rather than
squeezing the quantity out.

The existing Reduce Motion-aware inventory feedback transition remains in place;
its presentation no longer adds a shadow. All colours are semantic and work in
Dark Mode and increased contrast.

## Bottom tab bar clearance

The app uses an iOS 26 floating `TabView` with
`.tabBarMinimizeBehavior(.onScrollDown)`. The Inventory list previously scrolled
its last rows underneath that bar. The fix is a single list-level
`.safeAreaPadding(.bottom, InventoryChromeMetrics.bottomClearance)` — one fixed
inset, not a screen-height calculation, and not per-row padding — so the last
ingredient, the last search result, and the pantry empty-state CTA all come to
rest fully above the bar at both default and Accessibility XXXL sizes.

UI coverage asserts this against the tab bar's *expanded* top edge, captured
before any scrolling, because `.onScrollDown` shrinks the bar once the list
moves and comparing against the shrunken frame would test a weaker condition.

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

## Validation evidence

Exact executed/passed/failed/skipped counts, build results, and `.xcresult`
paths for this phase are recorded in the pull request body and the delivery
report. Screenshots are exported to
`~/Desktop/KitchenManager-Inventory-UI3-Review/final-fix/` and are deliberately
kept out of the repository.

Focused UI regression in `InventoryNavigationUITests` covers normal browsing,
search filtering, empty state, large inventory, Accessibility XXXL first-screen
readability, bottom tab-bar clearance at both text sizes, the pantry empty-state
CTA, Dark Mode, selection routing, and deletion safety.

## Deliberate non-goals

- No inventory sorting, expiry, restock, staple, deletion, or scan rules were
  changed.
- No data model, SwiftData schema, persistence, sync, authentication, Shopping,
  Recipe, Home, Settings, Import, or API change.
- No change to the tab architecture, and no app-wide Dynamic Type restriction.
- No new data fields, services, API calls, background work, or feature flags.
- Inventory detail editing remains the existing Form; this phase is limited to
  browsing, hierarchy, entry organization, and accessibility polish.
