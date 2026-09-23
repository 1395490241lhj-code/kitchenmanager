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

function contrastRatio(foreground, background) {
  const luminance = hex => {
    const channels = hex.match(/[\da-f]{2}/gi).map(value => parseInt(value, 16) / 255);
    const linear = channels.map(value => value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4);
    return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2];
  };
  const values = [luminance(foreground), luminance(background)].sort((a, b) => b - a);
  return (values[0] + 0.05) / (values[1] + 0.05);
}

// Phase UI-3 replaced the adaptive `LazyVGrid` of tinted cards with a searchable
// inset-grouped List. The grid and the per-card `InventoryExpiryProgressBar` are
// deliberately gone, so the assertions below cover the surviving *wiring* —
// source, row presentation, tap route, destination, swipe-delete, confirmation —
// rather than the retired markup.
test("fresh inventory renders as list rows routed through the explicit detail push", () => {
  assert.match(features, /store\.sortedFreshInventory/);
  assert.doesNotMatch(features, /LazyVGrid\(/);
  assert.match(features, /\.listStyle\(\.plain\)/);
  assert.match(features, /\.searchable\(\s*text: \$searchText/);
  assert.match(
    features,
    /ForEach\(displayedFreshInventory\) \{ item in\s*Button \{\s*onSelectItem\(item\.id\)\s*\} label: \{\s*InventoryFoodCard\(\s*item: item,\s*tonight: InventoryTonightLinkage\.summary\(for: item, in: tonight\)\s*\)\s*\}/
  );
  assert.match(features, /KitchenSectionLabel\(title: "食材", count: displayedFreshInventory\.count, showsRail: false\)/);
  assert.match(content, /NavigationStack\(path: \$navigationStore\.inventoryPath\)/);
  assert.match(content, /InventoryView\(onSelectItem:[\s\S]*navigationStore\.inventoryPath\.append\(\.detail\(itemID\)\)/);
  assert.match(features, /\.navigationDestination\(for: InventoryRoute\.self\)/);
  assert.match(features, /\.swipeActions\(edge: \.trailing/);
  assert.match(features, /\.alert\("删除这项食材？"/);
  assert.match(uiTests, /func testTappingEachInventoryCardPushesOnlyThatItem\(\)/);
});
test("inventory row communicates amount and a single expiry phrase without color-only decoration", () => {
  assert.match(features, /private struct InventoryFoodCard/);
  assert.match(features, /item\.expiryStatusText/);
  assert.match(features, /item\.quantity\.formatted\(\)/);
  assert.match(features, /item\.unit/);
  assert.doesNotMatch(features, /private struct InventoryExpiryProgressBar/);
  assert.doesNotMatch(features, /private var statusSymbol: String/);
  assert.match(features, /private var statusText: String/);
  assert.match(features, /private var showsUrgency: Bool/);
  assert.match(features, /\.accessibilityLabel\(accessibilityLabel\)/);
  assert.match(features, /\.accessibilityElement\(children: \.ignore\)[\s\S]*\.accessibilityHint\("打开食材详情"\)/);
});
test("inventory chrome is capped at accessibility sizes while food content is not", () => {
  const foodCard = features.slice(
    features.indexOf("private struct InventoryFoodCard"),
    features.indexOf("struct ShoppingView")
  );
  assert.match(features, /enum ChromeMetrics/);
  assert.match(features, /static let summaryTypeLimit = DynamicTypeSize\.accessibility1/);
  assert.match(features, /static let headerTypeLimit = DynamicTypeSize\.accessibility1/);
  assert.match(features, /static let symbolTypeLimit = DynamicTypeSize\.xxLarge/);
  assert.match(
    features,
    /\.navigationBarTitleDisplayMode\(dynamicTypeSize\.isAccessibilitySize \? \.inline : \.large\)/
  );
  assert.doesNotMatch(foodCard, /ViewThatFits/);
  assert.match(
    features,
    /private var accessibilityLayout: some View \{\s*VStack\(alignment: \.leading, spacing: 6\) \{\s*Text\(item\.name\)[\s\S]*?statusLabel\s*quantityLabel/
  );
  assert.doesNotMatch(features, /\.minimumScaleFactor\(/);
  assert.match(pantry, /dynamicTypeSize\.isAccessibilitySize/);
  assert.match(pantry, /\.dynamicTypeSize\(\.\.\.ChromeMetrics\.symbolTypeLimit\)/);
  assert.match(pantry, /private var detailLines: \[String\]/);
  assert.ok(pantry.includes('return ["当前 \\(item.quantity.formatted()) \\(item.unit)", "最低 \\(minimumText)"]'));
  assert.doesNotMatch(pantry, /\.minimumScaleFactor\(/);
});
test("inventory relies on native tab safe-area handling without a manual bottom spacer", () => {
  assert.doesNotMatch(features, /static let bottomClearance: CGFloat/);
  assert.doesNotMatch(
    features,
    /\.safeAreaInset\(edge: \.bottom\) \{\s*Color\.clear\s*\.frame\(height: ChromeMetrics\.bottomClearance\)/
  );
  assert.doesNotMatch(features, /GeometryReader/);
  assert.match(uiTests, /func testInventoryBottomContentClearsFloatingTabBar\(\)/);
  assert.match(uiTests, /func testPantryEmptyStateCTAClearsTabBarAndOpensExistingFlow\(\)/);
  assert.match(uiTests, /func testLastSearchResultClearsTabBar\(\)/);
  assert.match(uiTests, /func testAccessibilityXXXLKeepsFirstIngredientOnFirstScreen\(\)/);
  assert.match(uiTests, /\("normal",[\s\S]*\("dark",[\s\S]*\("accessibilityXXXL",/);
  assert.match(uiTests, /tabBar\.frame\.minY/);
});
test("the accessibility search field is never an empty placeholder", () => {
  assert.match(
    features,
    /private var searchPlacement: SearchFieldPlacement \{[\s\S]*\.navigationBarDrawer\(displayMode: \.always\)/
  );
  assert.match(
    features,
    /\.searchable\(\s*text: \$searchText,\s*placement: searchPlacement,\s*prompt: "搜索食材"/
  );
  assert.match(uiTests, /func testSearchFieldIsNeverAnEmptyPlaceholder\(\)/);
  assert.match(uiTests, /func testAccessibilityRowStacksNameStatusQuantityVertically\(\)/);
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

test("inventory lifecycle text colors keep identity and meet normal-text contrast", () => {
  for (const [name, light, dark] of [
    ["inventoryFresh", "237A42", "30D158"],
    ["inventoryUpcoming", "8A6500", "FFD60A"],
    ["inventoryExpiring", "A04B00", "FFB340"],
    ["inventoryToday", "B33A00", "FF9F0A"],
    ["inventoryExpired", "D92D2A", "FF6961"]
  ]) {
    assert.match(theme, new RegExp(`static let ${name} = (?:danger|adaptive\\(light: 0x${light}, dark: 0x${dark}\\))`));
    assert.ok(contrastRatio(light, "FFFFFF") >= 4.5, `${name} light contrast`);
    assert.ok(contrastRatio(dark, "1C1C1E") >= 4.5, `${name} dark contrast`);
  }
  assert.match(store, /case \.normal: return AppTheme\.inventoryFresh/);
  assert.match(store, /case \.soon: return AppTheme\.inventoryExpiring/);
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
