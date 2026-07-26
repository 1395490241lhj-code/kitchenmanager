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

// Phase UI-3 replaced the adaptive `LazyVGrid` of tinted cards with a searchable
// inset-grouped List. The grid and the per-card `InventoryExpiryProgressBar` are
// deliberately gone, so the assertions below cover the surviving *wiring* —
// source, row presentation, tap route, destination, swipe-delete, confirmation —
// rather than the retired markup.
test("fresh inventory renders as list rows routed through the explicit detail push", () => {
  assert.match(features, /store\.sortedFreshInventory/);
  // Matches a call, not the word: `InventoryView` still carries a comment
  // explaining why the explicit push replaced value-based links in the old grid.
  assert.doesNotMatch(features, /LazyVGrid\(/);
  assert.match(features, /\.listStyle\(\.insetGrouped\)/);
  assert.match(features, /\.searchable\(text: \$searchText/);
  assert.match(
    features,
    /ForEach\(displayedFreshInventory\) \{ item in\s*Button \{\s*onSelectItem\(item\.id\)\s*\} label: \{\s*InventoryFoodCard\(item: item\)\s*\}/
  );
  assert.match(features, /InventorySectionHeader\(title: "食材", count: displayedFreshInventory\.count\)/);
  assert.match(content, /NavigationStack\(path: \$inventoryPath\)/);
  assert.match(content, /InventoryView\(onSelectItem:[\s\S]*inventoryPath\.append\(InventoryRoute\.detail\(itemID\)\)/);
  assert.match(features, /\.navigationDestination\(for: InventoryRoute\.self\)/);
  assert.match(features, /\.swipeActions\(edge: \.trailing/);
  assert.match(features, /\.alert\("删除这项食材？"/);
  assert.match(uiTests, /func testTappingEachInventoryCardPushesOnlyThatItem\(\)/);
});

test("inventory row communicates amount and a single expiry phrase as text plus symbol", () => {
  assert.match(features, /private struct InventoryFoodCard/);
  assert.match(features, /item\.expiryStatusText/);
  assert.match(features, /item\.quantity\.formatted\(\)/);
  assert.match(features, /item\.unit/);
  // Expiry is no longer encoded twice (tinted card background + progress bar);
  // it is one status phrase paired with an SF Symbol, so the state never depends
  // on colour alone.
  assert.doesNotMatch(features, /private struct InventoryExpiryProgressBar/);
  assert.match(features, /private var statusSymbol: String/);
  assert.match(features, /Image\(systemName: statusSymbol\)/);
  assert.match(features, /accessibilityReduceMotion/);
  assert.match(features, /\.accessibilityLabel\(/);
  // The row stays one VoiceOver element with a navigation hint.
  assert.match(features, /\.accessibilityElement\(children: \.ignore\)[\s\S]*\.accessibilityHint\("打开食材详情"\)/);
});

test("inventory chrome is capped at accessibility sizes while food content is not", () => {
  // Page chrome (title, summary, headers, symbols) is bounded in one place;
  // names, quantities, and status text keep unrestricted Dynamic Type.
  assert.match(features, /enum InventoryChromeMetrics/);
  assert.match(features, /static let summaryTypeLimit = DynamicTypeSize\.accessibility1/);
  assert.match(features, /static let headerTypeLimit = DynamicTypeSize\.accessibility1/);
  assert.match(features, /static let symbolTypeLimit = DynamicTypeSize\.xxLarge/);
  // Large title at default sizes, inline at accessibility sizes.
  assert.match(
    features,
    /\.navigationBarTitleDisplayMode\(dynamicTypeSize\.isAccessibilitySize \? \.inline : \.large\)/
  );
  // Status and quantity fall back to stacked lines instead of overlapping.
  assert.match(features, /ViewThatFits\(in: \.horizontal\)/);
  // The staple row gets the same accessibility-size fallback.
  assert.match(pantry, /dynamicTypeSize\.isAccessibilitySize/);
  assert.match(pantry, /\.dynamicTypeSize\(\.\.\.InventoryChromeMetrics\.symbolTypeLimit\)/);
});

test("inventory list reserves one bottom inset for the floating tab bar", () => {
  assert.match(features, /static let bottomClearance: CGFloat/);
  assert.match(features, /\.safeAreaPadding\(\.bottom, InventoryChromeMetrics\.bottomClearance\)/);
  assert.match(uiTests, /func testInventoryBottomContentClearsFloatingTabBar\(\)/);
  assert.match(uiTests, /func testPantryEmptyStateCTAClearsTabBarAndOpensExistingFlow\(\)/);
  assert.match(uiTests, /func testLastSearchResultClearsTabBar\(\)/);
  assert.match(uiTests, /func testAccessibilityXXXLKeepsFirstIngredientOnFirstScreen\(\)/);
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
