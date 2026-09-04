# Phase 1B — Inventory behavior parity checklist

Baseline: `906842c`, captured from `InventoryView` in `MainFeatureViews.swift`
before the Phase 1B presentation change. The redesign is presentation-only:
every row below must still be reachable and still do the same thing.

Working checklist for one rollout. Delete it once Phase 1 is sealed.

## 1. Actions and routing

| Action | Identifier | Destination / effect |
| --- | --- | --- |
| Add ingredient | `inventory.add.button` | `RecordFoodSheet(.manual)` |
| More actions menu | `inventory.more.button` | scan receipt / add staple / prepared |
| Scan receipt | menu item | `RecordFoodSheet(.receipt)` |
| Add staple | menu item | `AddPantryStapleView` sheet |
| Prepared batches | menu item | `PreparedComponentsView` |
| Open an ingredient | `inventory.item.<uuid>` | `InventoryItemDetailView` via `InventoryRoute.detail` |
| Delete an ingredient | trailing swipe | confirm alert → `KitchenStore.deleteInventory` |
| Empty-state add | `inventory.empty.add.button` | `RecordFoodSheet(.manual)` |
| Staple empty-state add | `inventory.staple.empty.add.button` | `AddPantryStapleView` |
| Staple filter | `inventory.staple.filter.button` | `PantryStapleFilter` picker |
| Restock one | `inventory.restock.add.button` | `KitchenStore.addShopping` |
| Restock all staples | `inventory.restock.addAll.button` | `addShopping` per suggestion |
| Recent consumption | section row | `RecentConsumptionView` |
| Clear focus filter | 清除 button | `navigationStore.inventoryFocus = .all` |
| Search | native `.searchable` | filters both fresh and staple lists |

## 2. State that must still render

- focus banner when `inventoryFocus != .all` (expired / expiringSoon / lowStock)
- summary counts row (available / expiring / low stock)
- fresh ingredient list, sorted by `sortedFreshInventory`
- staple list with its filter
- restock suggestions from `RestockSuggestionEngine`
- empty inventory, empty staples, empty search, empty focus result
- inventory notice overlay (success and failure wording)

## 3. Domain rules that must not be re-derived

| Fact | Authority |
| --- | --- |
| expired / today / soon / upcoming / normal / unknown | `InventoryItem.expiryStatus` |
| status wording (`已过期 N 天`, `今天到期`, `剩余 N 天`) | `InventoryItem.expiryStatusText` |
| out of stock | `InventoryItem.isAvailable` |
| staple sufficiency | `InventoryItem.stapleStatus` |
| priority ordering | `KitchenStore.sortedFreshInventory` |
| restock suggestions | `RestockSuggestionEngine` |
| tonight's dishes | `KitchenStore.todayPlans` + `RecipeStore.recipe(id:)` |
| ingredient ↔ inventory matching | `IngredientNormalizer.matchKey` |

## 4. Behavior that must not change

- deletion stays behind the confirmation alert; no swipe-to-delete without it
- navigation pushes through `InventoryRoute`, never `NavigationLink(value:)`
- search filters both lists and shows its own empty state
- staples remain stock-tracked, never date-tracked
- the notice overlay auto-dismisses on its existing timer
