// 菜谱食材匹配层回归：库存/搜索 alias、非核心角色、首批 15 道 static map 与推荐签名。
// 只读加载静态 source，所有断言在内存 pack / localStorage stub 上运行。
import { test, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

import { installLocalStorageStub, resetLocalStorage } from './helpers/localstorage-stub.mjs';
import {
  getCanonicalName,
  getIngredientFamilyKey,
  isSmartIngredientMatch
} from '../src/ingredients.js';
import {
  areIngredientsRelated,
  normalizeIngredientName,
  searchRecipes
} from '../src/recipe-search.js';
import {
  analyzeRecipeInventory,
  buildRecommendationSignature,
  getLocalRecommendations,
  scoreRecipe
} from '../src/recommendations.js';
import { S } from '../src/storage.js';
import { classifyRecipeIngredient } from '../src/utils/recipe-sanitizer.js';
import { isIngredientMatch, getStockCoverageAnalysis } from '../src/inventory.js';

beforeEach(() => {
  installLocalStorageStub();
  resetLocalStorage();
});

const ALIAS_GROUPS = [
  { name: '胡椒', canonical: '胡椒', values: ['胡椒', '胡椒面', '胡椒粉'], role: 'seasoning' },
  { name: '糖', canonical: '糖', values: ['糖', '白糖'], role: 'seasoning' },
  { name: '食用油/菜油', canonical: '菜油', values: ['食用油', '菜油'], role: 'seasoning' },
  { name: '猪肉/瘦肉', canonical: '猪肉', values: ['猪肉', '瘦肉'], inventoryCanonical: ['猪肉', '瘦肉'], role: 'core' },
  { name: '鸡肉/鸡脯肉', canonical: '鸡肉', values: ['鸡肉', '鸡脯肉'], inventoryCanonical: ['鸡肉', '鸡脯肉'], role: 'core' }
];

function singleIngredientPack(item, id = 'r1') {
  const recipe = { id, name: `测试${item}`, method: '炒熟即可' };
  return {
    recipes: [recipe],
    recipe_ingredients: { [id]: [{ item }] }
  };
}

test('五组 alias：库存与搜索双向一致，seasoning 默认 non-core guard 保持生效', () => {
  for (const group of ALIAS_GROUPS) {
    for (const value of group.values) {
      assert.equal(classifyRecipeIngredient(value).role, group.role, `${group.name}: ${value} role`);
      assert.equal(normalizeIngredientName(value), group.canonical, `${group.name}: ${value} search canonical`);
      if (group.role === 'seasoning') {
        assert.equal(getCanonicalName(value), group.canonical, `${group.name}: ${value} inventory canonical`);
      } else {
        // Core-specific canonical labels remain available for display; the
        // broad family/search canonical is asserted separately above.
        assert.equal(getCanonicalName(value), group.inventoryCanonical[group.values.indexOf(value)], `${group.name}: ${value} inventory canonical`);
      }
    }

    for (const a of group.values) {
      for (const b of group.values) {
        if (group.role === 'seasoning') {
          // 生产核心路径先过滤 seasoning；直接默认调用被 non-core guard 拦截。
          assert.equal(isSmartIngredientMatch(a, b), false, `${group.name}: default ${a} vs ${b}`);
          assert.equal(isSmartIngredientMatch(a, b, { includeNonCore: true }), true, `${group.name}: explicit ${a} vs ${b}`);
        } else {
          assert.equal(isIngredientMatch(a, b), true, `${group.name}: inventory ${a} vs ${b}`);
          assert.equal(isIngredientMatch(b, a), true, `${group.name}: inventory reverse ${b} vs ${a}`);
          const coverage = getStockCoverageAnalysis(
            [{ name: b, qty: 2, unit: '份', stockStatus: 'ok' }],
            a,
            1,
            '份'
          );
          assert.equal(coverage.confidence, 'exact', `${group.name}: stock coverage ${a} vs ${b}`);
        }

        const forward = searchRecipes(
          singleIngredientPack(b).recipes,
          a,
          singleIngredientPack(b)
        );
        const reverse = searchRecipes(
          singleIngredientPack(a).recipes,
          b,
          singleIngredientPack(a)
        );
        assert.ok(forward.length > 0, `${group.name}: search ${a} -> ${b}`);
        assert.ok(reverse.length > 0, `${group.name}: search ${b} -> ${a}`);
        assert.equal(
          singleIngredientPack(b).recipe_ingredients.r1[0].item,
          b,
          `${group.name}: raw display name remains ${b}`
        );
      }
    }
  }
});

test('糖 alias 不吞并红糖/冰糖，辣椒与青椒保持库存/search 语义分离', () => {
  assert.equal(getCanonicalName('糖'), '糖');
  assert.equal(getCanonicalName('白糖'), '糖');
  assert.notEqual(getCanonicalName('糖'), getCanonicalName('红糖'));
  assert.notEqual(getCanonicalName('糖'), getCanonicalName('冰糖'));
  assert.notEqual(normalizeIngredientName('白糖'), normalizeIngredientName('红糖'));
  assert.notEqual(normalizeIngredientName('白糖'), normalizeIngredientName('冰糖'));

  assert.equal(getCanonicalName('辣椒'), '辣椒');
  assert.equal(getCanonicalName('青椒'), '青椒');
  assert.notEqual(getCanonicalName('辣椒'), getCanonicalName('青椒'));
  assert.equal(getIngredientFamilyKey('辣椒'), 'pepperHot');
  assert.equal(getIngredientFamilyKey('青椒'), 'pepper');
  assert.equal(isSmartIngredientMatch('辣椒', '二荆条'), true);
  assert.equal(isSmartIngredientMatch('青椒', '菜椒'), true);
  assert.equal(isSmartIngredientMatch('辣椒', '青椒'), false);
  assert.equal(isSmartIngredientMatch('青椒', '辣椒'), false);
  assert.equal(areIngredientsRelated('辣椒', '青椒'), false);
  assert.equal(areIngredientsRelated('青椒', '辣椒'), false);

  const pack = {
    recipes: [
      { id: 'green', name: '清炒一号', method: '炒熟' },
      { id: 'hot', name: '香辣二号', method: '炒熟' }
    ],
    recipe_ingredients: {
      green: [{ item: '青椒' }],
      hot: [{ item: '辣椒' }]
    }
  };
  assert.deepEqual(searchRecipes(pack.recipes, '青椒', pack).map(x => x.recipe.id), ['green']);
  assert.deepEqual(searchRecipes(pack.recipes, '辣椒', pack).map(x => x.recipe.id), ['hot']);

  const scopedSeasonings = {
    recipes: [
      { id: 'sugar', name: 'test-sugar', method: '调味' },
      { id: 'white-sugar', name: 'test-white-sugar', method: '调味' },
      { id: 'red-sugar', name: 'test-red-sugar', method: '调味' },
      { id: 'rock-sugar', name: 'test-rock-sugar', method: '调味' },
      { id: 'pepper-powder', name: 'test-pepper-powder', method: '调味' },
      { id: 'black-pepper', name: 'test-black-pepper', method: '调味' },
      { id: 'canola-oil', name: 'test-canola-oil', method: '调味' },
      { id: 'food-oil', name: 'test-food-oil', method: '调味' },
      { id: 'sesame-oil', name: 'test-sesame-oil', method: '调味' }
    ],
    recipe_ingredients: {
      sugar: [{ item: '糖' }],
      'white-sugar': [{ item: '白糖' }],
      'red-sugar': [{ item: '红糖' }],
      'rock-sugar': [{ item: '冰糖' }],
      'pepper-powder': [{ item: '胡椒粉' }],
      'black-pepper': [{ item: '黑胡椒' }],
      'canola-oil': [{ item: '菜油' }],
      'food-oil': [{ item: '食用油' }],
      'sesame-oil': [{ item: '香油' }]
    }
  };
  const searchIds = query => new Set(searchRecipes(
    scopedSeasonings.recipes,
    query,
    scopedSeasonings
  ).map(result => result.recipe.id));
  assert.deepEqual([...searchIds('糖')].sort(), ['sugar', 'white-sugar']);
  assert.deepEqual([...searchIds('白糖')].sort(), ['sugar', 'white-sugar']);
  assert.equal(searchIds('糖').has('red-sugar'), false);
  assert.equal(searchIds('糖').has('rock-sugar'), false);
  assert.deepEqual([...searchIds('胡椒')].sort(), ['pepper-powder']);
  assert.deepEqual([...searchIds('菜油')].sort(), ['canola-oil', 'food-oil']);
  assert.deepEqual([...searchIds('食用油')].sort(), ['canola-oil', 'food-oil']);
});

test('陈皮/草果/草碱均为非核心 seasoning，首批三道菜不因缺少它们降低 coverage/status/score', () => {
  for (const name of ['陈皮', '草果', '草碱']) {
    assert.equal(classifyRecipeIngredient(name).role, 'seasoning', `${name} role`);
    assert.equal(isSmartIngredientMatch(name, name), false, `${name} default non-core guard`);
    assert.equal(isSmartIngredientMatch(name, name, { includeNonCore: true }), true, `${name} explicit match`);
  }

  const cases = [
    { id: 'chenpi', name: '陈皮鸡', items: ['仔鸡', '辣椒', '陈皮'], seasoning: '陈皮' },
    { id: 'caoguo', name: '豆渣猪头', items: ['猪头肉', '猪头骨', '豆渣', '草果'], seasoning: '草果' },
    { id: 'caojian', name: '菠饺玻璃肚', items: ['猪肚', '瘦肉', '菠菜', '面粉', '草碱'], seasoning: '草碱' }
  ];
  for (const entry of cases) {
    const recipe = { id: entry.id, name: entry.name, method: '做熟即可' };
    const pack = {
      recipes: [recipe],
      recipe_ingredients: { [entry.id]: entry.items.map(item => ({ item })) }
    };
    const core = entry.items.filter(item => classifyRecipeIngredient(getCanonicalName(item)).role === 'core');
    const inv = core.map(name => ({ name, qty: 1, unit: '', stockStatus: 'ok' }));
    const withSeasoningStock = [...inv, { name: entry.seasoning, qty: 1, unit: '', stockStatus: 'ok' }];
    const without = analyzeRecipeInventory(recipe, pack, inv);
    const withStock = analyzeRecipeInventory(recipe, pack, withSeasoningStock);
    assert.equal(without.status, 'ok', `${entry.name} seasoning absent status`);
    assert.equal(without.coverage, 1, `${entry.name} seasoning absent coverage`);
    assert.equal(without.totalCore, core.length, `${entry.name} core count`);
    assert.deepEqual(
      { status: withStock.status, coverage: withStock.coverage, totalCore: withStock.totalCore },
      { status: without.status, coverage: without.coverage, totalCore: without.totalCore },
      `${entry.name} seasoning stock must not alter analysis`
    );
    const scoreWithout = scoreRecipe(recipe, pack, inv, { plan: [], favoriteIds: [], recipeActivity: {}, today: '2026-06-11' });
    const scoreWith = scoreRecipe(recipe, pack, withSeasoningStock, { plan: [], favoriteIds: [], recipeActivity: {}, today: '2026-06-11' });
    assert.equal(scoreWith.score, scoreWithout.score, `${entry.name} seasoning stock must not alter score`);
    assert.ok(!without.core.some(item => item.item === getCanonicalName(entry.seasoning)), `${entry.name} seasoning excluded`);
  }
});

function loadStaticIngredients() {
  const context = { window: {} };
  vm.createContext(context);
  vm.runInContext(fs.readFileSync(new URL('../data/recipe-methods.js', import.meta.url), 'utf8'), context);
  return context.window.RECIPE_INGREDIENTS;
}

test('首批 15 道逐道移除一个真正主料仍变 partial/none，误分类项不进入 core', () => {
  const source = loadStaticIngredients();
  const names = [
    '菠饺白肺', '菠饺玻璃肚', '叉烧奶猪', '陈皮鸡', '豆渣猪头', '鹅黄肉',
    '肥肠豆沙汤', '芙蓉鸡片', '芙蓉肉糕', '芙蓉肉片', '芙蓉杂烩', '福建仔鸡',
    '腐乳空心菜', '干煸花菜', '干煸四季豆'
  ];
  const recipes = names.map((name, index) => ({ id: `static-${index}`, name, method: '做熟即可' }));
  const recipe_ingredients = Object.fromEntries(recipes.map(recipe => [
    recipe.id,
    (source[recipe.name] || []).map(item => ({ item }))
  ]));
  const pack = { recipes, recipe_ingredients };

  for (const recipe of recipes) {
    const allItems = recipe_ingredients[recipe.id];
    const core = allItems.filter(item => classifyRecipeIngredient(getCanonicalName(item.item)).role === 'core');
    assert.ok(core.length > 0, `${recipe.name} must retain at least one core ingredient`);
    const inventory = core.map(item => ({ name: item.item, qty: 1, unit: '', stockStatus: 'ok' }));
    const full = analyzeRecipeInventory(recipe, pack, inventory);
    assert.equal(full.status, 'ok', `${recipe.name} all core stockable`);
    assert.equal(full.coverage, 1, `${recipe.name} full coverage`);

    const removed = core[0].item;
    const partialInventory = inventory.slice(1);
    const afterRemoval = analyzeRecipeInventory(recipe, pack, partialInventory);
    const expectedStatus = core.length === 1 ? 'none' : 'partial';
    assert.equal(afterRemoval.status, expectedStatus, `${recipe.name} removing ${removed}`);
    assert.ok(afterRemoval.missing.some(item => item.name === getCanonicalName(removed)), `${recipe.name} missing ${removed}`);
    assert.ok(!afterRemoval.missing.some(item => ['陈皮', '草果', '草碱'].includes(item.name)), `${recipe.name} no seasoning false-missing`);
  }
});

test('推荐签名包含 canonical+role+相关常备状态，稳定排序且忽略无关常备状态', () => {
  const basePack = {
    recipes: [{ id: 'r', name: '签名菜', method: '炒熟' }],
    recipe_ingredients: { r: [{ item: '猪肉' }, { item: '盐' }] }
  };
  const inv = [{ name: '猪肉', qty: 1, unit: '', stockStatus: 'ok' }];
  const context = {
    plan: [], favoriteIds: [], recipeActivity: {}, today: '2026-06-11',
    stapleNames: ['盐', '糖'],
    stapleStates: { 盐: { status: 'SUFFICIENT' }, 糖: { status: 'SUFFICIENT' } }
  };
  const base = buildRecommendationSignature(basePack, inv, context);
  const renamed = buildRecommendationSignature({
    ...basePack,
    recipe_ingredients: { r: [{ item: '瘦肉' }, { item: '盐' }] }
  }, inv, context);
  const roleChanged = buildRecommendationSignature({
    ...basePack,
    recipe_ingredients: { r: [{ item: '猪肉' }, { item: '水' }] }
  }, inv, context);
  const stapleChanged = buildRecommendationSignature(basePack, inv, {
    ...context,
    stapleStates: { 盐: { status: 'INSUFFICIENT' }, 糖: { status: 'SUFFICIENT' } }
  });
  const unrelatedStapleChanged = buildRecommendationSignature(basePack, inv, {
    ...context,
    stapleStates: { 盐: { status: 'SUFFICIENT' }, 糖: { status: 'INSUFFICIENT' } }
  });
  assert.notEqual(renamed, base, 'same-count canonical rename changes signature');
  assert.notEqual(roleChanged, base, 'role change changes signature');
  assert.notEqual(stapleChanged, base, 'related staple status changes signature');
  assert.equal(unrelatedStapleChanged, base, 'unrelated staple status does not invalidate');

  const reversed = buildRecommendationSignature({
    recipes: basePack.recipes,
    recipe_ingredients: { r: [{ item: '盐' }, { item: '猪肉' }] }
  }, inv.slice().reverse(), {
    ...context,
    favoriteIds: new Set(['x']),
    stapleStates: { 糖: { status: 'SUFFICIENT' }, 盐: { status: 'SUFFICIENT' } }
  });
  const baseWithFavorite = buildRecommendationSignature(basePack, inv, { ...context, favoriteIds: ['x'] });
  assert.equal(reversed, baseWithFavorite, 'signature serialization is order-stable');
});

test('推荐签名纯函数不隐式读取 localStorage', () => {
  const pack = {
    recipes: [{ id: 'r', name: '纯签名菜', method: '炒熟' }],
    recipe_ingredients: { r: [{ item: '猪肉' }, { item: '盐' }] }
  };
  const previousStorage = globalThis.localStorage;
  globalThis.localStorage = new Proxy({}, {
    get() {
      throw new Error('signature helper must not read localStorage');
    }
  });
  try {
    assert.doesNotThrow(() => buildRecommendationSignature(pack, [], {}));
  } finally {
    globalThis.localStorage = previousStorage;
  }
});

test('推荐缓存遇到相关常备状态变化会重算，无关状态不触发变化', () => {
  const pack = {
    recipes: [{ id: 'r', name: '缓存菜', method: '炒熟' }],
    recipe_ingredients: { r: [{ item: '猪肉' }, { item: '盐' }] }
  };
  const inv = [{ name: '猪肉', qty: 1, unit: '', stockStatus: 'ok' }];
  const first = getLocalRecommendations(pack, inv, true);
  const firstSignature = S.load(S.keys.rec_signature, '');
  assert.equal(first[0].status, 'ok');

  S.save(S.keys.staples, { 糖: { status: 'INSUFFICIENT' } });
  const unrelated = getLocalRecommendations(pack, inv, false);
  const unrelatedSignature = S.load(S.keys.rec_signature, '');
  assert.equal(unrelatedSignature, firstSignature);
  assert.equal(unrelated[0].status, 'ok');

  S.save(S.keys.staples, { 糖: { status: 'INSUFFICIENT' }, 盐: { status: 'INSUFFICIENT' } });
  const related = getLocalRecommendations(pack, inv, false);
  const relatedSignature = S.load(S.keys.rec_signature, '');
  assert.notEqual(relatedSignature, firstSignature);
  assert.equal(related[0].status, 'partial');
  assert.ok(related[0].missing.some(item => item.name === '盐'));
});
