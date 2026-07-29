# iOS Shopping Experience

## Scope

The native Shopping tab is a local-first shopping workflow. This phase changes
presentation and interaction only; it does not add a SwiftData model field,
Supabase schema, sync protocol, background task, or network classification.

## Information architecture

In ordinary mode, the page contains an always-visible native name search, one
quiet summary, pending items grouped by category, and a purchased section. The
summary gives pending count the leading position and demotes purchased and
non-empty category counts to secondary text instead of presenting three
equal-weight metrics. The list keeps the existing add, toggle, bulk, and
stock-in business operations.

Each category header includes a quiet item count. Item names are the primary
row content; source and quantity are secondary. At Accessibility Dynamic Type
sizes, quantity and source move below the name instead of competing for a
narrow trailing column. Page chrome is bounded, but shopping-item content
keeps unrestricted Dynamic Type.

Purchased items are collapsed at first. A matching purchased item is shown
temporarily while a non-empty search query is active; unrelated purchased
items and their section are not rendered for a pending-only or no-match query.
Clearing the query restores the user’s prior collapsed/expanded preference for
this session.
Expanded purchased rows use the same layout as pending rows but reduce color
and add strikethrough without removing the readable quantity.

The truly empty list provides a direct `添加买菜项目` action wired to the same
existing add-item sheet as the toolbar. Search-empty remains a distinct state
and does not offer a second data path.

## Categories, search, and order

`ShoppingCategory` supplies this fixed display order:

1. 蔬果 (Produce)
2. 肉类 (Meat)
3. 海鲜 (Seafood)
4. 乳制品 (Dairy)
5. 烘焙 (Bakery)
6. 冷冻 (Frozen)
7. 粮油干货 (Pantry)
8. 调味香料 (Spices)
9. 饮品 (Beverages)
10. 其他 (Other)

The mapper uses only built-in normalized-name keywords. It makes no network
request; an unknown name is always `Other`. Pending items are placed in the
fixed category order, then sorted by localized stable name comparison.

Search trims leading/trailing whitespace and matches item names
case-insensitively. It never changes persisted shopping data. An empty search
result is distinct from an actually empty shopping list.

## Purchased and bulk actions

The toolbar’s native bulk menu provides:

- Mark all pending items purchased.
- Clear purchased items, after a destructive confirmation that includes the
  affected count.
- Add purchased items to inventory, using the existing
  `KitchenStore.stockInCompletedShopping()` transaction.
- Expand or collapse the purchased section.

Inapplicable actions are disabled. Clear Purchased touches only completed
shopping rows. Stock-in preserves the existing inventory behavior: existing
quantities are accumulated rather than replaced, a failed shopping persistence
write restores the inventory snapshot, and no consumption record is written.

## Shopping Mode

Shopping Mode is a session-only focused view. It hides the ordinary summary,
search field, add action, and bulk menu; keeps fixed category ordering; makes
the entire item row an accessible purchase toggle; and shows the remaining
pending count. The mode header and category chrome remain secondary to the
larger pending-item names. When all items are purchased it shows an explicit
completion state, retains access to completed items so a purchase can be
undone, and does not automatically clear items, stock inventory, or exit the
mode.

Leaving Shopping Mode returns to the normal presentation. The mode, its
progress, and purchased-section expansion are not persisted and are not
synchronized across devices.

## Recipe and inventory boundaries

Recipe and planning workflows continue to reuse the existing missing-
ingredient logic: ingredients already sufficiently stocked are not added, and
shortages add only the calculated difference when quantity conversion is
available. This phase does not alter recipes. Purchased stock-in likewise
reuses the existing accumulation/rollback path and does not create inventory
consumption records.

## Accessibility

Stable identifiers include:

- `shopping.search`, `shopping.search.empty`, `shopping.empty`,
  `shopping.empty.add.button`, and `shopping.add.button`
- `shopping.summary.pending`, `shopping.summary.purchased`,
  `shopping.summary.categories`
- `shopping.section.<category>`, `shopping.item.<uuid>`, and
  `shopping.purchased.toggle`
- `shopping.bulk.menu`, `shopping.bulk.clearPurchased`,
  `shopping.bulk.stockIn`, `shopping.bulk.expandPurchased`, and
  `shopping.bulk.collapsePurchased`
- `shopping.mode.toggle`, `shopping.mode.container`,
  `shopping.mode.remaining`, `shopping.mode.item.<uuid>`,
  `shopping.mode.exit`, and `shopping.mode.completed`

Category and purchased controls announce counts and state. Every item button
announces name, quantity, unit, non-manual source when present, purchase state,
and the exact toggle action. Toolbar symbols keep 44pt targets and bounded
chrome sizing; row text is never scale-compressed or line-limited. A single
list-level bottom inset lets the final content scroll above the expanded
floating tab bar. There is no custom Shopping animation, so Reduce Motion keeps
the system list/sheet behavior without a parallel transition.

## Previews and tests

Preview-only sample storage covers ordinary mode with multiple categories,
purchased items expanded, no search results, and an empty list. It also covers
Shopping Mode with multiple categories, one remaining item, all items
completed, and an empty list. Samples use an isolated `UserDefaults` suite and
are not part of the production runtime path.

`ShoppingExperienceTests` covers category mapping/order, summary and search
presentation (including hiding an unrelated purchased section), purchased
visibility, bulk availability and effects, stock-in accumulation, and Shopping
Mode state. `ShoppingExperienceUITests` covers the summary/action hierarchy,
search (including the pending-only purchased-section regression), purchased
collapse, bulk actions and stock-in confirmation, empty-state add-sheet wiring,
Accessibility XXXL reachability, and the Shopping Mode entry/toggle/exit path.

## Non-goals

This phase does not include online categorization, barcode scanning, store
routes, Apple Sign in, CloudKit, a new sync source, or cross-device Shopping
Mode state.
