import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const root = new URL("../ios-native/Kitchen Manager/KitchenManager/", import.meta.url);
const read = file => readFileSync(new URL(file, root), "utf8");
const recipes = read("RecipeViews.swift");
const recipeModel = read("Recipe.swift");
const shopping = read("ShoppingListGenerator.swift");
const features = read("MainFeatureViews.swift");
const home = read("HomeView.swift");
const pantry = read("PantryStaples.swift");
const kitchen = read("KitchenStore.swift");
const service = read("RecipeService.swift");
const editor = read("RecipeDraftEditor.swift");
const addRecipe = read("AddRecipeViews.swift");
const generator = read("AIRecipeGenerator.swift");
const imageImport = read("RecipeImageImport.swift");
const server = read("../../../server.js");

test("recipe add menu uses explicit push routes for all four actions", () => {
  for (const route of ["manual", "linkImport", "imageImport", "aiGenerator"]) {
    assert.match(recipes, new RegExp(`Button \\{ route = \\.${route} \\}`));
  }
  assert.match(recipes, /\.navigationDestination\(item: \$route\)/);
  assert.match(recipes, /\.accessibilityLabel\("添加菜谱"\)/);
});

test("shopping add button opens a focused medium form", () => {
  assert.match(features, /Button\("添加", systemImage: "plus"\) \{ isShowingAddItem = true \}/);
  assert.match(features, /AddShoppingItemView\(\)[\s\S]*\.presentationDetents\(\[\.medium\]\)/);
  assert.match(features, /TextField\("名称", text: \$name\)\.focused\(\$isNameFocused\)/);
  assert.match(features, /store\.addShopping\(name: cleanName/);
});

test("home keeps food-entry ownership out of Today after IA consolidation", () => {
  const homeView = home.slice(
    home.indexOf("struct HomeView: View"),
    home.indexOf("private struct HomeDashboardHeader")
  );
  const importToolbar = homeView.slice(
    homeView.indexOf(".toolbar {"),
    homeView.indexOf(".navigationDestination")
  );

  // Today owns Kitchen AI, not the old all-purpose Smart Import launcher.
  assert.match(importToolbar, /Label\("问 Kitchen AI", systemImage: KitchenAISymbol\.emblem\)/);
  assert.match(importToolbar, /\.accessibilityIdentifier\("home\.kitchenAI\.open"\)/);
  assert.doesNotMatch(importToolbar, /smartImport|recordMode|selectedTab/);
  assert.doesNotMatch(homeView, /home\.import\.add\.button|SmartImportSheet|SmartImportRoute/);

  // Food entry remains one tap away on the Inventory tab and reuses the
  // existing RecordFoodSheet rather than introducing a second flow.
  assert.match(
    features,
    /Button\("添加食材", systemImage: "plus"\)\s*\{\s*recordMode = \.manual\s*\}/
  );
  assert.match(
    features,
    /\.sheet\(item: \$recordMode\) \{ mode in\s*RecordFoodSheet\(initialMode: mode\)\s*\}/
  );
});
test("recipe seasonings are a real backward-compatible field", () => {
  assert.match(recipeModel, /let seasonings: \[String\]/);
  assert.match(recipeModel, /decodeIfPresent\(\[String\]\.self, forKey: \.seasonings\)/);
  assert.match(recipeModel, /RecipeIngredientClassifier\.classify\(legacyIngredients, recipeTitle: title\)/);
  assert.match(recipes, /RecipeDetailSection\("调料与辅料"\)/);
  assert.match(recipes, /if !recipe\.seasonings\.isEmpty/);
});
test("classifier moves bean flour, starch, oil, and liquids into seasonings conservatively", () => {
  for (const term of ["豆粉", "水淀粉", "食用油", "高汤"]) {
    assert.match(recipeModel, new RegExp(`"${term}"`));
  }
  assert.match(recipeModel, /name\.contains\("淀粉"\) \|\| name\.contains\("豆粉"\)/);
  assert.match(recipeModel, /豌豆粉.*凉粉/s);
  assert.match(recipeModel, /aromaticNames/);
});

test("recipe editor supports user-controlled moves between ingredient buckets", () => {
  assert.match(editor, /Section\("调料与辅料"\)/);
  assert.match(editor, /RecipeIngredientBucketEditor/);
  assert.match(editor, /移到调料与辅料/);
  assert.match(editor, /移到食材/);
  assert.match(editor, /Button\("删除"/);
});

test("all editable recipe save and plan entries share draft eligibility", () => {
  assert.match(editor, /var isSaveEligible: Bool \{ \(try\? makeRecipe\(\)\) != nil \}/);
  assert.match(addRecipe, /return editableDraft\.isSaveEligible/);
  assert.match(addRecipe, /\.disabled\(!draft\.isSaveEligible\)/);
  assert.match(addRecipe, /generatorStore\.isGenerating \|\| !isDraftSaveEligible/);
  assert.match(addRecipe, /hasAddedCurrentDraftToPlan \|\| !isDraftSaveEligible/);
  assert.match(imageImport, /return draft\.isSaveEligible/);
  assert.match(recipes, /\.disabled\(!draft\.isSaveEligible\)/);
});

test("home IA removes the legacy smart-import stack while share handoff keeps recipe import available", () => {
  // Home IA consolidation deliberately removed the old multi-purpose
  // SmartImportSheet/SmartImportRoute stack from Today.
  assert.doesNotMatch(home, /enum SmartImportRoute: Hashable/);
  assert.doesNotMatch(home, /struct SmartImportSheet: View/);
  assert.doesNotMatch(home, /HomeSheet\.smartImport/);

  // Link import still arrives from the share/clipboard handoff and reuses the
  // canonical ImportRecipeView instead of reviving the removed Home stack.
  assert.match(
    home,
    /\.sheet\(item: sharedImportSheetBinding\) \{ request in\s*sharedImportSheetContent\(request\)\s*\}/
  );
  assert.match(
    home,
    /private func sharedImportSheetContent\(_ request: SharedImportRequest\) -> some View \{[\s\S]*ImportRecipeView\([\s\S]*autoStart: true/
  );
  assert.match(home, /case \.clipboardImport\(let presentation\):[\s\S]*ImportRecipeView\(/);
});
test("all recipe generation and import prompts require auxiliary materials in seasonings", () => {
  assert.match(generator, /豆粉、淀粉、生粉、水淀粉/);
  assert.match(imageImport, /豆粉、淀粉、生粉、水淀粉/);
  assert.match(server, /豆粉、淀粉、生粉、红薯淀粉、玉米淀粉、水淀粉/);
  assert.match(server, /豆粉、淀粉、生粉、水淀粉、食用油/);
});

test("settings only retains consumer sections and isolates developer text", () => {
  const settings = features.slice(
    features.indexOf("struct SettingsView"),
    features.indexOf("struct BackupRestoreView")
  );
  for (const heading of ["外观", "菜谱", "提醒", "数据", "关于"]) {
    assert.match(settings, new RegExp(`(?:Section\\(\\"${heading}\\"\\)|Text\\(\\"${heading}\\"\\))`));
  }
  assert.match(settings, /Toggle\("食材到期提醒"/);
  assert.match(settings, /Toggle\("常备食材补货提醒"/);
  assert.match(settings, /#if DEBUG[\s\S]*Section\("开发者"\)/);
  assert.doesNotMatch(settings, /AI 模型配置/);
  assert.match(settings, /清除全部本地数据/);
});

test("shopping defaults to core ingredients and can include seasonings", () => {
  assert.match(shopping, /includeSeasonings: Bool = false/);
  assert.match(shopping, /includeSeasonings \? recipe\.ingredients \+ recipe\.seasonings : recipe\.ingredients/);
  assert.match(shopping, /@AppStorage\("shoppingIncludesSeasonings"\)/);
  assert.match(shopping, /Toggle\("包含调料"/);
});

test("pantry supports status and quantity modes without a second store", () => {
  assert.match(kitchen, /enum StapleTrackingMode:[\s\S]*case status[\s\S]*case quantity/);
  assert.match(kitchen, /enum StapleAvailabilityStatus:[\s\S]*case available[\s\S]*case low[\s\S]*case missing/);
  assert.match(pantry, /store\.cycleStapleStatus\(item\.id\)/);
  assert.match(pantry, /store\.adjustStapleQuantity\(item\.id, by: -1\)/);
  assert.doesNotMatch(pantry, /class .*Store/);
});

test("recipe library mode, filters, matching, and user override priority are wired", () => {
  assert.match(service, /case curated[\s\S]*case full/);
  assert.match(recipeModel, /remoteRecipes\.filter \{ !userIDs\.contains\(\$0\.id\) \}/);
  assert.match(recipes, /case favorites[\s\S]*case frequent[\s\S]*case cookable[\s\S]*case nearlyCookable/);
  assert.match(recipes, /missingCoreIngredientCount/);
  assert.match(features, /Picker\("菜谱库模式"/);
});
