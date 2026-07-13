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
  const inventoryView = views.slice(views.indexOf("struct InventoryView"), views.indexOf("private struct InventoryFoodCard"));
  const settingsView = views.slice(views.indexOf("struct SettingsView"), views.indexOf("struct BackupRestoreView"));
  assert.match(inventoryView, /Text\("常备货架"\)/);
  assert.match(views, /补齐常备货架/);
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
