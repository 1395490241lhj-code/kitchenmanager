import { beforeEach, test } from 'node:test';
import assert from 'node:assert/strict';

import {
  INGREDIENT_FAMILIES,
  getCanonicalName,
  getIngredientFamilyKey,
  getIngredientMatchNames,
} from '../src/ingredients.js';
import { getStockCoverageAnalysis } from '../src/inventory.js';
import { analyzeRecipeInventory, findRecipesUsingIngredients } from '../src/recommendations.js';
import { addShoppingItem, loadShoppingItems } from '../src/shopping.js';
import { classifyIngredientCompatibility } from '../scripts/dazhong-runtime-compatibility.mjs';
import { installLocalStorageStub, resetLocalStorage } from './helpers/localstorage-stub.mjs';

beforeEach(() => {
  installLocalStorageStub();
  resetLocalStorage();
});

test('p137 uses only the exact 子公鸡 alias and keeps the chicken family unchanged', () => {
  assert.equal(getCanonicalName('子公鸡'), '鸡肉');
  assert.deepEqual(INGREDIENT_FAMILIES.chicken, {
    broad: ['鸡肉'],
    members: ['鸡肉', '鸡脯肉', '鸡腿', '鸡翅'],
  });
  const runtime = classifyIngredientCompatibility('子公鸡', '1', '只');
  assert.equal(runtime.canonical, '鸡肉');
  assert.equal(runtime.compatibility, 'expected-unit-confirmation');
});

test('p161 keeps 鸡血 independent and passes the exact runtime-name gate', () => {
  assert.equal(getCanonicalName('鸡血'), '鸡血');
  assert.equal(getIngredientFamilyKey('鸡血'), '');
  assert.deepEqual(getIngredientMatchNames('鸡血'), ['鸡血']);
  const runtime = classifyIngredientCompatibility('鸡血', '500', 'g');
  assert.equal(runtime.canonical, '鸡血');
  assert.equal(runtime.compatibility, 'exact-compatible');
  assert.deepEqual(runtime.probes.map((probe) => probe.probeName), ['鸡血']);
});

test('鸡血 inventory and recommendation boundaries remain exact', () => {
  const stock = (name) => [{ name, qty: 500, unit: 'g', stockStatus: 'ok' }];
  assert.equal(getStockCoverageAnalysis(stock('鸡血'), '鸡血', 500, 'g').confidence, 'exact');
  assert.equal(getStockCoverageAnalysis(stock('鸭血'), '鸡血', 500, 'g').confidence, 'none');
  assert.equal(getStockCoverageAnalysis(stock('鸡肉'), '鸡血', 500, 'g').confidence, 'none');

  const recipe = { id: 'dz1979-p161', name: '拌鸡血', method: '拌匀。' };
  const pack = { recipes: [recipe], recipe_ingredients: { [recipe.id]: [{ item: '鸡血', qty: '500', unit: 'g' }] } };
  assert.equal(analyzeRecipeInventory(recipe, pack, stock('鸡血')).status, 'ok');
  assert.equal(analyzeRecipeInventory(recipe, pack, stock('鸭血')).status, 'none');
  assert.equal(analyzeRecipeInventory(recipe, pack, stock('鸡肉')).status, 'none');
  const options = { context: { plan: [], favoriteIds: [], recipeActivity: {}, today: '2026-08-08' } };
  assert.equal(findRecipesUsingIngredients(pack, [], ['鸡血'], options).length, 1);
  assert.equal(findRecipesUsingIngredients(pack, [], ['鸭血'], options).length, 0);
  assert.equal(findRecipesUsingIngredients(pack, [], ['鸡肉'], options).length, 0);
});

test('shopping preserves 鸡血 and does not merge it with 鸭血 or 鸡肉', () => {
  addShoppingItem('鸡血', 500, 'g', '菜谱');
  addShoppingItem('鸭血', 500, 'g', '菜谱');
  addShoppingItem('鸡肉', 500, 'g', '菜谱');
  assert.deepEqual(loadShoppingItems().map((item) => item.name).sort(), ['鸡肉', '鸡血', '鸭血'].sort());
});

test('existing chicken and duck vocabulary behavior is unchanged', () => {
  assert.equal(getCanonicalName('仔鸡'), '鸡肉');
  assert.equal(getCanonicalName('鸭'), '鸭肉');
  assert.equal(getStockCoverageAnalysis([{ name: '鸡腿', qty: 1, unit: '份', stockStatus: 'ok' }], '鸡肉', 1, '份').confidence, 'exact');
  assert.equal(getStockCoverageAnalysis([{ name: '鸭', qty: 1, unit: '份', stockStatus: 'ok' }], '鸭肉', 1, '份').confidence, 'exact');
});
