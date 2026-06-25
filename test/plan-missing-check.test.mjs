import { beforeEach, test } from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';

import { installLocalStorageStub, resetLocalStorage } from './helpers/localstorage-stub.mjs';
import { S } from '../src/storage.js';
import { addMissingRecipeIngredientsToShopping } from '../src/recommendations.js';
import {
  addRecipeToPlanWithMissingCheck,
  getPlanMissingItems
} from '../src/components/plan-missing-check.js';
import { loadShoppingItems } from '../src/shopping.js';

beforeEach(() => {
  installLocalStorageStub();
  resetLocalStorage();
});

const PACK = {
  recipes: [
    { id: 'tomato-egg-noodle', name: '番茄鸡蛋面', method: '煮面后拌炒' },
    { id: 'tomato-egg', name: '番茄炒蛋', method: '炒熟即可' }
  ],
  recipe_ingredients: {
    'tomato-egg-noodle': [
      { item: '番茄', qty: 2, unit: '个' },
      { item: '鸡蛋', qty: 2, unit: '个' },
      { item: '手工挂面', qty: 1, unit: '份' },
      { item: '盐', qty: 1, unit: '适量' }
    ],
    'tomato-egg': [
      { item: '番茄', qty: 2, unit: '个' },
      { item: '鸡蛋', qty: 2, unit: '个' },
      { item: '盐', qty: 1, unit: '适量' }
    ]
  }
};

const BASE_INV = [
  { name: '番茄', qty: 2, unit: '个', buyDate: '2026-06-25', shelf: 7, stockStatus: 'ok' },
  { name: '鸡蛋', qty: 2, unit: '个', buyDate: '2026-06-25', shelf: 14, stockStatus: 'ok' }
];

function readProjectFile(file) {
  return readFileSync(new URL(`../${file}`, import.meta.url), 'utf8');
}

function listJsFiles(dir) {
  const root = new URL(`../${dir}`, import.meta.url).pathname;
  const out = [];
  const walk = current => {
    for (const name of readdirSync(current)) {
      const full = join(current, name);
      if (statSync(full).isDirectory()) walk(full);
      else if (full.endsWith('.js')) out.push(full);
    }
  };
  walk(root);
  return out;
}

test('食材齐全的菜加入今日计划时不弹缺菜确认', async () => {
  let confirmCalled = false;
  const result = await addRecipeToPlanWithMissingCheck('tomato-egg', PACK, BASE_INV, {
    toast: false,
    confirmMissing: () => { confirmCalled = true; return true; }
  });

  assert.equal(result.added, true);
  assert.deepEqual(result.missing, []);
  assert.equal(confirmCalled, false);
  assert.equal(S.load(S.keys.plan, []).length, 1);
  assert.deepEqual(loadShoppingItems(), []);
});

test('食材不全时仍加入今日计划，并把核心缺食材传给确认弹窗', async () => {
  let promptedNames = [];
  const result = await addRecipeToPlanWithMissingCheck('tomato-egg-noodle', PACK, BASE_INV, {
    toast: false,
    confirmMissing: ({ missing }) => {
      promptedNames = missing.map(item => item.name || item.item);
      return false;
    }
  });

  assert.equal(result.added, true);
  assert.deepEqual(promptedNames, ['手工挂面']);
  assert.deepEqual(result.missing.map(item => item.name), ['手工挂面']);
  assert.equal(S.load(S.keys.plan, []).some(item => item.id === 'tomato-egg-noodle'), true);
  assert.deepEqual(loadShoppingItems(), []);
});

test('用户确认后缺食材加入买菜清单，不包含调料', async () => {
  const result = await addRecipeToPlanWithMissingCheck('tomato-egg-noodle', PACK, BASE_INV, {
    toast: false,
    confirmMissing: () => true
  });

  const shopping = loadShoppingItems();
  assert.equal(result.shoppingAddedCount, 1);
  assert.deepEqual(shopping.map(item => item.name), ['手工挂面']);
  assert.equal(shopping.some(item => item.name === '盐'), false);
});

test('加入计划缺菜检测只判断有没有，不因数量不足打扰', async () => {
  let confirmCalled = false;
  const sparseButPresentInv = [
    { name: '番茄', qty: 1, unit: '个', stockStatus: 'ok' },
    { name: '鸡蛋', qty: 1, unit: '个', stockStatus: 'ok' }
  ];
  const result = await addRecipeToPlanWithMissingCheck('tomato-egg', PACK, sparseButPresentInv, {
    toast: false,
    confirmMissing: () => {
      confirmCalled = true;
      return true;
    }
  });

  assert.equal(result.added, true);
  assert.deepEqual(result.missing, []);
  assert.equal(confirmCalled, false);
});

test('用户取消后只保留今日计划，不加入买菜清单', async () => {
  const result = await addRecipeToPlanWithMissingCheck('tomato-egg-noodle', PACK, BASE_INV, {
    toast: false,
    confirmMissing: () => false
  });

  assert.equal(result.added, true);
  assert.equal(result.confirmedShopping, false);
  assert.equal(S.load(S.keys.plan, []).length, 1);
  assert.deepEqual(loadShoppingItems(), []);
});

test('补到买菜只加入缺食材，不加入今日计划', () => {
  const recipe = PACK.recipes[0];
  const missing = getPlanMissingItems(recipe, PACK, BASE_INV);
  const count = addMissingRecipeIngredientsToShopping(recipe, PACK, BASE_INV, PACK.recipe_ingredients[recipe.id], missing);

  assert.equal(count, 1);
  assert.deepEqual(loadShoppingItems().map(item => item.name), ['手工挂面']);
  assert.deepEqual(S.load(S.keys.plan, []), []);
});

test('demo 模式可在缺食材确认前推进计划步骤', async () => {
  let demoAdded = false;
  await addRecipeToPlanWithMissingCheck('tomato-egg-noodle', PACK, BASE_INV, {
    toast: false,
    confirmMissing: () => false,
    onPlanAdded: added => { demoAdded = added; }
  });

  assert.equal(demoAdded, true);
  assert.equal(S.load(S.keys.plan, []).some(item => item.id === 'tomato-egg-noodle'), true);
});

test('用户可见加入计划入口不再直接调用 addRecipeToPlan 或手写 plan.push', () => {
  const allowed = new Set([
    'src/components/plan-missing-check.js',
    'src/recommendations.js'
  ]);
  const directCalls = [];
  const rootPrefix = new URL('../', import.meta.url).pathname;
  for (const file of listJsFiles('src')) {
    const rel = file.slice(rootPrefix.length);
    if (allowed.has(rel)) continue;
    const source = readFileSync(file, 'utf8');
    if (/\baddRecipeToPlan\(/.test(source)) directCalls.push(rel);
  }
  assert.deepEqual(directCalls, []);

  const card = readProjectFile('src/components/recipe-card.js');
  assert.doesNotMatch(card, /plan\.push\(/);
  assert.doesNotMatch(card, /markRecipePlanned/);
});

test('详情页和快速弹窗加入计划入口都走统一缺菜检测', () => {
  const detail = readProjectFile('src/views/recipe-detail-view.js');
  const quick = readProjectFile('src/components/recipe-quick-modal.js');
  assert.match(detail, /addRecipeToPlanWithMissingCheck\(id, pack, inv/);
  assert.match(detail, /source: 'recipe-detail'/);
  assert.doesNotMatch(detail, /addRecipeToPlan,/);
  assert.match(quick, /addRecipeToPlanWithMissingCheck\(id, pack, inventory/);
  assert.match(quick, /source: 'quick-modal'/);
});
