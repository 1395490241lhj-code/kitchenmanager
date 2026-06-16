import test from 'node:test';
import assert from 'node:assert/strict';
import { installLocalStorageStub, resetLocalStorage, dump } from './helpers/localstorage-stub.mjs';
import { S } from '../src/storage.js?v=219';
import { applyCookCalibration, computeCookDeductions } from '../src/inventory.js?v=219';
import {
  buildLocalCookedMealCandidates,
  getRecipeCoreItems,
  matchCookedMealRecipe,
  mergeCookedMealCandidates,
  normalizeAiCookedMealResult
} from '../src/utils/cooked-meal.js?v=219';
import { validateCookedMealResult } from '../src/ai.js?v=219';

test.beforeEach(() => {
  installLocalStorageStub();
  resetLocalStorage();
});

test('输入已有菜谱名，可以匹配 recipe，并只取核心食材', () => {
  const pack = {
    recipes: [
      { id: 'r1', name: '西红柿炒鸡蛋' },
      { id: 'r2', name: '青菜豆腐汤' }
    ],
    recipe_ingredients: {
      r1: [
        { item: '番茄', qty: 2, unit: '个' },
        { item: '鸡蛋', qty: 3, unit: '个' },
        { item: '盐', qty: '', unit: '' }
      ]
    }
  };

  const recipe = matchCookedMealRecipe('我刚做了番茄炒蛋', pack.recipes);
  assert.equal(recipe?.id, 'r1');
  assert.deepEqual(getRecipeCoreItems(recipe, pack).map(item => item.item), ['番茄', '鸡蛋']);
});

test('输入“我炒了鸡腿和豆芽”，能从库存中匹配鸡腿、豆芽', () => {
  const inv = [
    { name: '鸡腿', qty: 2, unit: '份', stockStatus: 'ok' },
    { name: '豆芽', qty: 1, unit: '袋', stockStatus: 'ok' },
    { name: '盐', qty: 1, unit: '包', stockStatus: 'ok' }
  ];

  const candidates = buildLocalCookedMealCandidates('我炒了鸡腿和豆芽', inv);
  assert.deepEqual(candidates.map(item => item.item).sort(), ['豆芽', '鸡腿']);
});

test('AI 返回候选会被库存和核心食材过滤，确认前不写 localStorage', () => {
  const inv = [
    { name: '青菜', qty: 2, unit: '份', stockStatus: 'ok' },
    { name: '豆腐', qty: 1, unit: '盒', stockStatus: 'ok' },
    { name: '盐', qty: 1, unit: '包', stockStatus: 'ok' }
  ];
  const before = dump();
  const result = normalizeAiCookedMealResult({
    dishes: [{
      name: '青菜豆腐汤',
      usedIngredients: [
        { name: '青菜', qty: 1, unit: '份', reason: '用户提到青菜' },
        { name: '豆腐', qty: 1, unit: '盒', reason: '用户提到豆腐' },
        { name: '盐', qty: 1, unit: '勺', reason: '调味' },
        { name: '不存在的菜', qty: 1, unit: '份', reason: '幻觉' }
      ]
    }],
    needsReview: true
  }, inv);

  assert.deepEqual(result.candidates.map(item => item.item).sort(), ['豆腐', '青菜']);
  assert.deepEqual(dump(), before);
});

test('用户取消时不写库存；确认后才扣减库存', () => {
  const inv = [
    { name: '鸡腿', qty: 2, unit: '份', stockStatus: 'ok', buyDate: '2026-06-01', shelf: 7 },
    { name: '豆芽', qty: 1, unit: '袋', stockStatus: 'ok', buyDate: '2026-06-01', shelf: 7 }
  ];
  S.save(S.keys.inventory, inv);
  const candidates = buildLocalCookedMealCandidates('我炒了鸡腿和豆芽', inv);
  const predictions = computeCookDeductions(candidates, inv);

  assert.equal(S.load(S.keys.inventory, [])[0].qty, 2, '只生成建议时不能写库存');

  const calibrations = predictions.map(p => p.unitType === 'PIECE'
    ? { match: p.match, name: p.name, unitType: 'PIECE', finalQty: Math.max(0, p.currentQty - 1) }
    : { match: p.match, name: p.name, unitType: 'GEAR', finalGear: p.predictedGear });
  applyCookCalibration(inv, calibrations);

  const after = S.load(S.keys.inventory, []);
  assert.equal(after.find(item => item.name === '鸡腿').qty, 1);
  assert.equal(after.find(item => item.name === '豆芽').qty, 0);
});

test('直接选食材模式可以从库存加入确认列表，来源为你手动添加', () => {
  const manual = mergeCookedMealCandidates([
    { item: '莴笋', qty: 1, unit: '份', reason: '你手动添加', matchName: '莴笋' }
  ]);
  assert.equal(manual.length, 1);
  assert.equal(manual[0].item, '莴笋');
  assert.equal(manual[0].reason, '你手动添加');
});

test('AI 顶层 usedIngredients 格式也能校验，调料会被过滤', () => {
  const result = validateCookedMealResult({
    usedIngredients: [
      { name: '鸡腿', qty: 1, unit: '份', reason: '用户提到鸡腿' },
      { name: '盐', qty: 1, unit: '勺', reason: '调味' }
    ],
    needsReview: true
  });
  assert.equal(result.dishes.length, 1);
  assert.deepEqual(result.dishes[0].usedIngredients.map(item => item.name), ['鸡腿']);
});

test('空输入或模糊描述不会生成本地候选', () => {
  const inv = [{ name: '鸡腿', qty: 2, unit: '份', stockStatus: 'ok' }];
  assert.deepEqual(buildLocalCookedMealCandidates('', inv), []);
  assert.deepEqual(buildLocalCookedMealCandidates('我做了个汤', inv), []);
});
