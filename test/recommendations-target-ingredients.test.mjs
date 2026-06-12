import { test, beforeEach } from 'node:test';
import assert from 'node:assert/strict';

import { installLocalStorageStub, resetLocalStorage } from './helpers/localstorage-stub.mjs';
import {
  findRecipesUsingIngredients,
  normalizeTargetIngredientNames
} from '../src/recommendations.js';

beforeEach(() => {
  installLocalStorageStub();
  resetLocalStorage();
});

const PACK = {
  recipes: [
    { id: 'beef-potato', name: '土豆炖牛肉', method: '炖熟即可' },
    { id: 'beef-pepper', name: '青椒牛肉', method: '炒熟即可' },
    { id: 'tomato-egg', name: '番茄炒蛋', method: '炒熟即可' },
    { id: 'seasoning-only', name: '调味汁', method: '拌匀即可' }
  ],
  recipe_ingredients: {
    'beef-potato': [
      { item: '牛肉', qty: 1, unit: '份' },
      { item: '土豆', qty: 2, unit: '个' },
      { item: '盐' }
    ],
    'beef-pepper': [
      { item: '牛肉', qty: 1, unit: '份' },
      { item: '青椒', qty: 2, unit: '个' }
    ],
    'tomato-egg': [
      { item: '西红柿', qty: 2, unit: '个' },
      { item: '鸡蛋', qty: 3, unit: '个' },
      { item: '盐' }
    ],
    'seasoning-only': [
      { item: '盐' },
      { item: '高汤' }
    ]
  }
};

const CONTEXT = { plan: [], recipeActivity: {}, favoriteIds: [], today: '2026-06-11' };

test('指定牛肉和土豆时，完全命中的本地菜谱优先', () => {
  const results = findRecipesUsingIngredients(
    PACK,
    [
      { name: '牛肉', qty: 1, unit: '份', stockStatus: 'ok' },
      { name: '土豆', qty: 3, unit: '个', stockStatus: 'ok' }
    ],
    ['牛肉', '土豆'],
    { context: CONTEXT }
  );
  assert.equal(results[0].id, 'beef-potato');
  assert.equal(results[0].targetHits.length, 2);
  assert.equal(results[0].targetTotal, 2);
  assert.equal(results[0].matchLabel, '用到 2/2');
});

test('番茄目标能匹配菜谱里的西红柿', () => {
  const results = findRecipesUsingIngredients(
    PACK,
    [
      { name: '番茄', qty: 2, unit: '个', stockStatus: 'ok' },
      { name: '鸡蛋', qty: 6, unit: '个', stockStatus: 'ok' }
    ],
    ['番茄', '鸡蛋'],
    { context: CONTEXT }
  );
  assert.equal(results[0].id, 'tomato-egg');
  assert.equal(results[0].targetHits.length, 2);
});

test('目标里的盐、水、高汤会被过滤，不参与目标匹配', () => {
  assert.deepEqual(normalizeTargetIngredientNames(['牛肉', '盐', '水', '高汤']), ['牛肉']);
  const results = findRecipesUsingIngredients(PACK, [], ['盐', '水', '高汤'], { context: CONTEXT });
  assert.deepEqual(results, []);
});

test('空目标不启用指定食材推荐', () => {
  assert.deepEqual(findRecipesUsingIngredients(PACK, [], [], { context: CONTEXT }), []);
});

test('缺库存时 missing 只包含核心食材，不包含调料', () => {
  const results = findRecipesUsingIngredients(PACK, [], ['牛肉', '土豆', '盐'], { context: CONTEXT });
  const top = results.find(item => item.id === 'beef-potato');
  const missingNames = top.inventoryMissing.map(item => item.name || item.item);
  assert.ok(missingNames.includes('牛肉'));
  assert.ok(missingNames.includes('土豆'));
  assert.ok(!missingNames.includes('盐'));
});

// ── 类别展开 + 包含匹配 + AI 草稿过滤（本轮升级）──────────────────────────────
import { parseTargetIngredients } from '../src/utils/ingredient-intent.js';
import { filterAiDraftCoreIngredients } from '../src/ai.js';

const PACK2 = {
  recipes: [
    { id: 'mushroom-tofu', name: '香菇烧豆腐', method: '烧熟即可' },
    { id: 'wing-mid', name: '可乐鸡翅', method: '烧熟即可' },
    { id: 'pork-pepper', name: '青椒肉丝', method: '炒熟即可' }
  ],
  recipe_ingredients: {
    'mushroom-tofu': [{ item: '香菇', qty: 4, unit: '朵' }, { item: '豆腐', qty: 1, unit: '块' }],
    'wing-mid': [{ item: '鸡翅中', qty: 8, unit: '个' }],
    'pork-pepper': [{ item: '猪肉', qty: 200, unit: 'g' }, { item: '青椒', qty: 2, unit: '个' }]
  }
};

test('类别匹配：菌菇 豆腐 → 命中香菇烧豆腐（经 targetDescriptors 候选组）', () => {
  const { targets } = parseTargetIngredients('菌菇 豆腐');
  const results = findRecipesUsingIngredients(PACK2, [], targets.map(t => t.canonical), {
    context: CONTEXT, targetDescriptors: targets
  });
  assert.equal(results[0].id, 'mushroom-tofu');
  assert.equal(results[0].targetHits.length, 2);
  assert.deepEqual(results[0].targetMatchedNames, results[0].targetHits);
});

test('类别匹配：肉片 青椒 → 命中青椒肉丝（猪肉类候选）', () => {
  const { targets } = parseTargetIngredients('肉片 青椒');
  const results = findRecipesUsingIngredients(PACK2, [], targets.map(t => t.canonical), {
    context: CONTEXT, targetDescriptors: targets
  });
  assert.equal(results[0].id, 'pork-pepper');
  assert.equal(results[0].targetHits.length, 2);
});

test('包含匹配：鸡翅 命中食材「鸡翅中」', () => {
  const { targets } = parseTargetIngredients('鸡翅');
  const results = findRecipesUsingIngredients(PACK2, [], targets.map(t => t.canonical), {
    context: CONTEXT, targetDescriptors: targets
  });
  assert.ok(results.some(r => r.id === 'wing-mid'));
});

test('类别匹配：绿叶菜 鸡蛋 → 命中菠菜/青菜类 + 鸡蛋菜', () => {
  const pack = {
    recipes: [{ id: 'spinach-egg', name: '菠菜炒蛋', method: '炒' }],
    recipe_ingredients: { 'spinach-egg': [{ item: '菠菜', qty: 1, unit: '把' }, { item: '鸡蛋', qty: 2, unit: '个' }] }
  };
  const { targets } = parseTargetIngredients('绿叶菜 鸡蛋');
  const results = findRecipesUsingIngredients(pack, [], targets.map(t => t.canonical), {
    context: CONTEXT, targetDescriptors: targets
  });
  assert.equal(results[0].id, 'spinach-egg');
  assert.equal(results[0].targetHits.length, 2);
});

test('结果上限 6 且 targetHits===0 的不返回', () => {
  const many = { recipes: [], recipe_ingredients: {} };
  for (let i = 0; i < 10; i++) {
    many.recipes.push({ id: `r${i}`, name: `牛肉菜${i}`, method: '做' });
    many.recipe_ingredients[`r${i}`] = [{ item: '牛肉', qty: 1, unit: '份' }];
  }
  const results = findRecipesUsingIngredients(many, [], ['牛肉'], { context: CONTEXT });
  assert.ok(results.length <= 6);
  assert.ok(results.every(r => r.targetHits.length > 0));
});

test('AI 草稿过滤：盐/水/葱姜蒜被剔除，仅留核心食材；全是调料则报错', () => {
  const out = filterAiDraftCoreIngredients({
    name: 'X', method: '1.',
    ingredients: [{ item: '牛肉' }, { item: '盐' }, { item: '水' }, { item: '葱' }, { item: '姜' }, { item: '高汤' }]
  });
  assert.deepEqual(out.ingredients.map(i => i.item), ['牛肉']);
  assert.throws(() => filterAiDraftCoreIngredients({ name: 'X', method: '1.', ingredients: [{ item: '盐' }, { item: '水' }] }), /核心食材/);
});
