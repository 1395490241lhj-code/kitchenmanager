import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const root = new URL("../ios-native/Kitchen Manager/KitchenManager/", import.meta.url);
const read = name => readFileSync(new URL(name, root), "utf8");
const store = read("KitchenStore.swift");
const consumption = read("InventoryConsumption.swift");
const views = read("MainFeatureViews.swift");
const pantry = read("PantryStaples.swift");
const consumptionTests = read("../KitchenManagerTests/ConsumptionPersistenceTests.swift");
const shoppingTests = read("../KitchenManagerTests/ShoppingListPersistenceTests.swift");

test("native inventory staple fields remain backward-decodable", () => {
  for (const field of ["isStaple", "autoSuggestRestock"]) {
    assert.match(store, new RegExp(`decodeIfPresent\\(Bool\\.self, forKey: \\.${field}\\) \\?\\? false`));
  }
  for (const field of ["lowStockThreshold", "defaultRestockQuantity", "stapleNote", "stapleCategory"]) {
    assert.match(store, new RegExp(`decodeIfPresent\\([^\\n]+forKey: \\.${field}\\)`));
  }
});

test("staple status has one converter-aware source of truth", () => {
  assert.match(store, /func stapleStockStatus\(/);
  assert.match(store, /currentQuantity <= 0.*return \.outOfStock/s);
  assert.match(store, /UnitConverter\.convert\(currentQuantity, from: currentUnit, to: minimumUnit\)/);
  assert.match(store, /return current < minimumQuantity \? \.low : \.sufficient/);
});

test("pantry restock suggestions reuse the existing engine", () => {
  assert.match(consumption, /item\.isStaple && item\.autoSuggestRestock/);
  assert.match(consumption, /item\.defaultRestockQuantity[\s\S]+item\.lowStockThreshold/);
  assert.match(consumption, /source: \.pantryStaple/);
  assert.match(consumption, /guard suggestions\[key\] == nil else \{ continue \}/);
});

test("shopping additions normalize and merge convertible units", () => {
  assert.match(store, /IngredientNormalizer\.matchKey\(\$0\.name\)/);
  assert.match(store, /UnitConverter\.areConvertible\(\$0\.unit, cleanUnit\)/);
  assert.match(store, /UnitConverter\.convert\(safeQuantity, from: cleanUnit, to: shoppingItems\[index\]\.unit\)/);
  assert.match(views, /source: suggestion\.source == \.pantryStaple \? "来自常备货架"/);
});

test("native pantry UI, persistence, backup, and settings stay connected", () => {
  // Narrowed to `InventoryView`'s own body: the UI-3 redesign extracted the
  // summary/header/row subviews below it, and the old wider slice would have
  // let those satisfy assertions meant for the list itself.
  const inventoryView = views.slice(views.indexOf("struct InventoryView"), views.indexOf("private struct InventoryNoticeOverlay"));
  const settingsView = views.slice(views.indexOf("struct SettingsView"), views.indexOf("struct BackupRestoreView"));

  // UI-3 renamed the in-list section from the old "常备货架" heading to
  // "常备食材" and replaced the bespoke header/metric views with
  // the shared `ListSectionHeader`. What must not regress is the *wiring*: the
  // staple section, its filter, its rows, and its empty state all still
  // resolve to the same pre-existing pantry flows.
  assert.doesNotMatch(inventoryView, /Text\("常备货架"\)/);

  // 1. The staple section and its filter still exist, driven by the same
  //    `PantryStapleFilter` state and `store.pantryStaples` source.
  assert.match(inventoryView, /ListSectionHeader\(title: "常备食材", count: displayedStaples\.count\)/);
  assert.match(inventoryView, /@State private var stapleFilter: PantryStapleFilter = \.all/);
  assert.match(inventoryView, /store\.pantryStaples\.filter\(stapleFilter\.includes\)/);
  assert.match(inventoryView, /Picker\("筛选", selection: \$stapleFilter\)[\s\S]*ForEach\(PantryStapleFilter\.allCases\)/);

  // 2 & 3. Staple rows still render through the existing `PantryStapleRow`
  //    presentation over the filtered staples — not a duplicated local list —
  //    and tapping one still pushes via the shared `onSelectItem` route, the
  //    same detail route fresh items use. Asserted as one contiguous block so
  //    the tap wiring cannot be satisfied by the fresh-item `ForEach` above.
  assert.match(
    inventoryView,
    /ForEach\(displayedStaples\) \{ item in\s*Button \{\s*onSelectItem\(item\.id\)\s*\} label: \{\s*PantryStapleRow\(item: item\)\s*\}/
  );

  // The staple empty state still opens the pre-existing `AddPantryStapleView`
  // sheet rather than a new flow.
  assert.match(inventoryView, /Button\("添加常备食材"\) \{ isShowingAddStaple = true \}/);
  assert.match(inventoryView, /\.sheet\(isPresented: \$isShowingAddStaple\) \{\s*AddPantryStapleView\(\)/);

  // 4. Accessibility identifiers/labels the focused UI tests drive stay put.
  assert.match(inventoryView, /\.accessibilityIdentifier\("inventory\.staple\.filter\.button"\)/);
  assert.match(inventoryView, /\.accessibilityIdentifier\("inventory\.staple\.empty\.add\.button"\)/);
  assert.match(inventoryView, /\.accessibilityLabel\("常备食材筛选：\\\(stapleFilter\.rawValue\)"\)/);

  // 5. The batch pantry restock action survived the copy change from
  //    "补齐常备货架（n）" and still feeds every pantry-sourced suggestion into
  //    the same `addSuggestion` path.
  assert.match(inventoryView, /restockSuggestions\.filter \{ \$0\.source == \.pantryStaple \}/);
  assert.match(inventoryView, /项常备补货/);
  assert.match(inventoryView, /stapleSuggestions\.forEach\(addSuggestion\)/);

  assert.match(pantry, /struct AddPantryStapleView/);
  assert.match(pantry, /struct InventoryItemDetailView/);
  assert.match(store, /func cancelStaple\(_ id: UUID\)/);
  assert.match(store, /func exportBackupData\(\) throws -> Data/);
  assert.match(store, /func restoreBackupData\(_ data: Data\) throws/);
  assert.match(settingsView, /Toggle\("常备食材补货提醒"/);
  assert.match(settingsView, /NavigationLink \{[\s\S]*PantryStaplesView\(\)[\s\S]*Text\("管理常备货架"\)/);
});

test("stock-in and consumption mutate the same persisted inventory", () => {
  const applyConsumption = store.slice(store.indexOf("func applyConsumption("), store.indexOf("func undoConsumption("));
  const stockIn = store.slice(store.indexOf("func stockInCompletedShopping()"), store.indexOf("func saveWeeklyPlan("));
  assert.match(applyConsumption, /var updatedInventory = inventory/);
  assert.match(applyConsumption, /let resulting = max\(0, previous - consumeInItemUnit\)[\s\S]*updatedInventory\[index\]\.quantity = resulting/);
  assert.match(applyConsumption, /inventoryPersistence\.replaceInventory\(with: updatedInventory\)[\s\S]*consumptionPersistence\.replaceRecords/);
  assert.match(stockIn, /var updated = inventory[\s\S]*Self\.mergeOrAppendInventoryItem\(/);
  assert.match(stockIn, /inventoryPersistence\.replaceInventory\(with: updated\)[\s\S]*shoppingListPersistence\.replaceShoppingItems/);
  assert.match(consumptionTests, /func testApplyFailureRollsBackInventoryAndDoesNotPublishRecord\(\)/);
  assert.match(consumptionTests, /func testStoreRestartUndoAndRepeatedUndoPersist\(\)/);
  assert.match(shoppingTests, /func testStockInCompletedPersistsInventoryAndRemovesOnlyCompletedShopping\(\)/);
  assert.match(shoppingTests, /func testStockInShoppingFailureRollsBackInventoryAndKeepsShoppingInMemory\(\)/);
});
