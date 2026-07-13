import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const root = new URL("../ios-native/Kitchen Manager/KitchenManager/", import.meta.url);
const read = name => readFileSync(new URL(name, root), "utf8");
const features = read("MainFeatureViews.swift");
const store = read("KitchenStore.swift");
const theme = read("AppTheme.swift");
const pantry = read("PantryStaples.swift");
const home = read("HomeView.swift");
const content = read("ContentView.swift");
const uiTests = read("../KitchenManagerUITests/InventoryNavigationUITests.swift");

test("fresh inventory uses adaptive lifecycle cards rather than plain list rows", () => {
  assert.match(features, /store\.sortedFreshInventory/);
  assert.match(features, /LazyVGrid\([\s\S]*GridItem\(\.adaptive\(minimum: 145, maximum: 210\)/);
  assert.match(features, /InventoryFoodCard\(item: item\)/);
  assert.match(features, /Button \{[\s\S]*onSelectItem\(item\.id\)[\s\S]*InventoryFoodCard\(item: item\)/);
  assert.match(content, /NavigationStack\(path: \$inventoryPath\)/);
  assert.match(content, /InventoryView\(onSelectItem:[\s\S]*inventoryPath\.append\(InventoryRoute\.detail\(itemID\)\)/);
  assert.match(features, /\.navigationDestination\(for: InventoryRoute\.self\)/);
  assert.match(features, /\.swipeActions\(edge: \.trailing/);
  assert.match(features, /\.alert\("删除这项食材？"/);
  assert.match(uiTests, /func testTappingEachInventoryCardPushesOnlyThatItem\(\)/);
});

test("inventory card communicates amount, a single expiry phrase, and a compact progress bar", () => {
  assert.match(features, /private struct InventoryFoodCard/);
  assert.match(features, /item\.expiryStatusText/);
  assert.match(features, /item\.quantity\.formatted\(\)/);
  assert.match(features, /item\.unit/);
  assert.match(features, /private struct InventoryExpiryProgressBar/);
  assert.match(features, /\.frame\(height: 4\)/);
  assert.match(features, /accessibilityReduceMotion/);
  assert.match(features, /\.accessibilityLabel\(/);
});

test("expiry lifecycle has one compatible progress calculation and urgency sort", () => {
  assert.match(store, /var createdAt: Date\?/);
  assert.match(store, /decodeIfPresent\(Date\.self, forKey: \.createdAt\)/);
  assert.match(store, /var expiryProgress: Double\?/);
  assert.match(store, /createdAt \?\? updatedAt/);
  assert.match(store, /var sortedFreshInventory/);
  assert.match(store, /expiryStatus\.sortPriority/);
  assert.match(store, /var expiryStatusText/);
});

test("inventory colors are dynamic and pantry quantity progress remains separate", () => {
  for (const name of [
    "inventoryFreshBackground",
    "inventoryUpcomingBackground",
    "inventoryExpiringBackground",
    "inventoryTodayBackground",
    "inventoryExpiredBackground",
    "inventoryUnknownBackground"
  ]) {
    assert.match(theme, new RegExp(`static let ${name}`));
  }
  assert.match(store, /var stapleStockProgress: Double\?/);
  assert.match(pantry, /StapleStockProgressBar/);
  assert.match(pantry, /\.frame\(height: 3\)/);
});

test("inventory detail is a single value-based push with an editable expiry date", () => {
  const detail = pantry.slice(pantry.indexOf("struct InventoryItemDetailView"), pantry.indexOf("struct PantryStaplesView"));
  assert.match(features, /onSelectItem\(item\.id\)/);
  assert.match(features, /case \.detail\(let itemID\):[\s\S]*InventoryItemDetailView\(itemID: itemID\)/);
  assert.match(uiTests, /XCTAssertTrue\([\s\S]*detailTitle\.waitForExistence/);
  assert.doesNotMatch(detail, /tabViewStyle\(\.page/);
  assert.doesNotMatch(detail, /ScrollView\(\.horizontal/);
  assert.match(detail, /Section\("保质期"\)/);
  assert.match(detail, /InventoryExpirySuggestion\.suggestedExpiryDate/);
  assert.match(detail, /DatePicker\(\s*"到期日期"/);
});

test("home expiry and shopping sheets share one material list container", () => {
  assert.match(home, /private struct HomeStatusSheetContainer/);
  assert.match(home, /List \{/);
  assert.match(home, /\.scrollContentBackground\(\.hidden\)/);
  assert.match(home, /\.presentationBackground\(\.(?:thin|regular)Material\)/);
  assert.match(home, /HomeStatusSheetContainer\(title: "临期食材", path: \$path\)/);
  assert.match(home, /HomeStatusSheetContainer\(title: "待买清单", path: \$path\)/);
  assert.match(home, /\.presentationDetents\(\[\.medium, \.large\]\)/);
});
