import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const root = new URL("../ios-native/Kitchen Manager/KitchenManager/", import.meta.url);
const read = name => readFileSync(new URL(name, root), "utf8");
const features = read("MainFeatureViews.swift");
const receipt = read("ReceiptImport.swift");
const store = read("KitchenStore.swift");
const shopping = read("ShoppingListGenerator.swift");
const expiry = read("InventoryExpirySuggestion.swift");

test("inventory plus menu exposes only normal and staple entry", () => {
  const toolbar = features.slice(features.indexOf('.navigationTitle("食材")'), features.indexOf('.sheet(item: $recordMode)'));
  assert.match(toolbar, /Button\("添加食材", systemImage: "square\.and\.pencil"\)/);
  assert.match(toolbar, /Button\("添加常备食材", systemImage: "cabinet"\)/);
  assert.doesNotMatch(toolbar, /Button\("扫描小票"/);
  assert.doesNotMatch(toolbar, /Button\("批量录入"/);
  assert.match(toolbar, /\.accessibilityLabel\("录入食材"\)/);
  assert.match(receipt, /case receipt = "拍小票"/);
});

test("manual batch entry uses the single ingredient parser and all supported separators", () => {
  assert.match(receipt, /let parsed = IngredientParser\.parse\(line\)/);
  assert.match(receipt, /CharacterSet\(charactersIn: "\\n,，、;；"\)/);
  assert.match(receipt, /let quantity = parsed\.quantity \?\? 1/);
  assert.match(receipt, /let unit = parsed\.unit \?\? "份"/);
  assert.doesNotMatch(receipt, /let parts = line\.split/);
});

test("ingredient parser recognizes compact suffix quantities without splitting product names", () => {
  assert.match(shopping, /splitTrailingQuantityAndUnit/);
  assert.match(shopping, /"公斤"/);
  for (const unit of ["份", "个", "颗", "盒", "瓶", "把", "块", "克", "千克", "毫升", "升"]) {
    assert.match(shopping, new RegExp(`"${unit}"`));
  }
  for (const numeral of ["一", "二", "两", "三", "四", "五", "六", "七", "八", "九", "十"]) {
    assert.match(shopping, new RegExp(`"${numeral}"`));
  }
  assert.match(shopping, /维生素B2片/);
  assert.match(shopping, /suffix directly attached to an ASCII letter/);
});

test("all non-staple inventory creation flows receive one conservative expiry suggestion", () => {
  const addInventory = store.slice(store.indexOf("func addInventory("), store.indexOf("func importInventory("));
  const importInventory = store.slice(store.indexOf("func importInventory("), store.indexOf("private static func mergeOrAppendInventoryItem("));
  const mergeInventory = store.slice(store.indexOf("private static func mergeOrAppendInventoryItem("), store.indexOf("func updateInventory("));
  assert.match(addInventory, /Self\.mergeOrAppendInventoryItem\(/);
  assert.match(importInventory, /Self\.mergeOrAppendInventoryItem\([\s\S]*category: item\.category/);
  assert.match(mergeInventory, /InventoryExpirySuggestion\.suggestedExpiryDate\([\s\S]*category: category/);
  assert.match(mergeInventory, /let effectiveExpiryDate = expiryDate \?\? \(isStaple[\s\S]*\? nil[\s\S]*suggestedExpiryDate/);
  assert.match(receipt, /let explicitExpiryDate = item\.expiryDate/);
  assert.match(receipt, /let suggestedExpiryDate = explicitExpiryDate \?\?[\s\S]*InventoryExpirySuggestion\.suggestedExpiryDate/);
  assert.match(receipt, /InventoryImportItem\([\s\S]*expiryDate: \$0\.expiryDate,[\s\S]*category: \$0\.category/);
  assert.match(receipt, /private var manualItems: \[InventoryImportItem\][\s\S]*expiryDate: \$0\.expiryDate/);
});

test("expiry rules are bounded to known fresh categories and skip shelf-stable foods", () => {
  for (const term of ["韭菜花", "菠菜", "番茄", "猪肉", "虾", "牛奶", "鸡蛋", "豆腐", "苹果", "冷冻肉"]) {
    assert.match(expiry, new RegExp(`"${term}"`));
  }
  for (const term of ["大米", "面粉", "食用油", "生抽", "咖啡豆"]) {
    assert.match(expiry, new RegExp(`"${term}"`));
  }
  for (const days of [90, 2, 3, 5, 7, 21]) {
    assert.match(expiry, new RegExp(`return ${days}`));
  }
  assert.match(expiry, /Unrecognized ordinary ingredient:[\s\S]*return 7/);
  assert.match(expiry, /guard !name\.isEmpty, !category\.contains\("常备"\) else \{ return nil \}/);
});
