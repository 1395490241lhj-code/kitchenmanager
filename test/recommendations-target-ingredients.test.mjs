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
