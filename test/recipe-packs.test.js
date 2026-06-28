const test = require('node:test');
const assert = require('node:assert/strict');

const data = require('../data/recipe-packs.json');

const modulePromise = import('../src/recipe-packs.js');
async function loadRecipePacksModule() {
  return modulePromise;
}

test('can import src/recipe-packs.js', async () => {
  const recipePacks = await loadRecipePacksModule();

  assert.equal(typeof recipePacks.getRecipePacks, 'function');
  assert.equal(typeof recipePacks.getRecipePackRecipes, 'function');
  assert.equal(typeof recipePacks.getDefaultEnabledRecipePackIds, 'function');
  assert.equal(typeof recipePacks.getRecipePackById, 'function');
  assert.equal(typeof recipePacks.getRecipesByEnabledPacks, 'function');
  assert.equal(typeof recipePacks.getRecipesGroupedByPack, 'function');
  assert.equal(typeof recipePacks.summarizeRecipePackData, 'function');
});

test('can read formal recipe pack data', () => {
  assert.equal(data.status, 'experimental');
  assert.equal(Array.isArray(data.packs), true);
  assert.equal(Array.isArray(data.recipes), true);
});

test('getRecipePacks returns defined packs', async () => {
  const { getRecipePacks } = await loadRecipePacksModule();

  assert.equal(getRecipePacks(data).length, 5);
});

test('getRecipePackRecipes returns formal recipes', async () => {
  const { getRecipePackRecipes } = await loadRecipePacksModule();

  assert.equal(getRecipePackRecipes(data).length, 20);
  assert.ok(getRecipePackRecipes(data).length >= 20);
});

test('getDefaultEnabledRecipePackIds returns default pack ids', async () => {
  const { getDefaultEnabledRecipePackIds } = await loadRecipePacksModule();

  assert.deepEqual(getDefaultEnabledRecipePackIds(data), ['basic-home', 'quick-solo']);
});

test('getRecipePackById returns matching pack or null', async () => {
  const { getRecipePackById } = await loadRecipePacksModule();

  assert.equal(getRecipePackById(data, 'basic-home').name, '基础家常菜');
  assert.equal(getRecipePackById(data, 'missing'), null);
});

test('getRecipesByEnabledPacks filters by one enabled pack', async () => {
  const { getRecipesByEnabledPacks } = await loadRecipePacksModule();
  const recipes = getRecipesByEnabledPacks(data, ['quick-solo']);

  assert.ok(recipes.length > 0);
  assert.ok(recipes.every((recipe) => recipe.packs.includes('quick-solo')));
});

test('getRecipesByEnabledPacks filters by multiple packs without duplicates', async () => {
  const { getRecipesByEnabledPacks } = await loadRecipePacksModule();
  const recipes = getRecipesByEnabledPacks(data, ['basic-home', 'quick-solo']);
  const ids = recipes.map((recipe) => recipe.id);

  assert.equal(ids.length, new Set(ids).size);
  assert.ok(recipes.some((recipe) => recipe.packs.includes('basic-home')));
  assert.ok(recipes.some((recipe) => recipe.packs.includes('quick-solo')));
});

test('getRecipesByEnabledPacks returns empty array when enabled packs are empty', async () => {
  const { getRecipesByEnabledPacks } = await loadRecipePacksModule();

  assert.deepEqual(getRecipesByEnabledPacks(data, []), []);
});

test('getRecipesGroupedByPack includes all defined pack ids', async () => {
  const { getRecipesGroupedByPack } = await loadRecipePacksModule();
  const grouped = getRecipesGroupedByPack(data);
  const packIds = data.packs.map((pack) => pack.id);

  assert.deepEqual(Object.keys(grouped), packIds);
  for (const packId of packIds) {
    assert.equal(Array.isArray(grouped[packId]), true);
  }
});

test('summarizeRecipePackData returns counts and default packs', async () => {
  const { summarizeRecipePackData } = await loadRecipePacksModule();
  const summary = summarizeRecipePackData(data);

  assert.equal(summary.packCount, 5);
  assert.equal(summary.recipeCount, 20);
  assert.deepEqual(summary.defaultEnabledPackIds, ['basic-home', 'quick-solo']);
  assert.equal(typeof summary.recipesByPackCount, 'object');
  assert.equal(summary.recipesByPackCount['basic-home'] > 0, true);
  assert.equal(summary.recipesByPackCount['quick-solo'] > 0, true);
});

test('helpers handle invalid input safely', async () => {
  const {
    getRecipePacks,
    getRecipePackRecipes,
    getDefaultEnabledRecipePackIds,
    getRecipePackById,
    getRecipesByEnabledPacks,
    getRecipesGroupedByPack,
    summarizeRecipePackData
  } = await loadRecipePacksModule();

  assert.deepEqual(getRecipePacks(null), []);
  assert.deepEqual(getRecipePacks({ packs: 'bad' }), []);
  assert.deepEqual(getRecipePackRecipes({}), []);
  assert.deepEqual(getDefaultEnabledRecipePackIds(undefined), []);
  assert.equal(getRecipePackById(null, 'basic-home'), null);
  assert.equal(getRecipePackById(data, null), null);
  assert.deepEqual(getRecipesByEnabledPacks(null, ['basic-home']), []);
  assert.deepEqual(getRecipesByEnabledPacks(data, null), []);
  assert.deepEqual(getRecipesGroupedByPack(null), {});
  assert.deepEqual(summarizeRecipePackData(null), {
    packCount: 0,
    recipeCount: 0,
    defaultEnabledPackIds: [],
    recipesByPackCount: {}
  });
});
