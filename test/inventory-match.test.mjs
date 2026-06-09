// test/inventory-match.test.mjs
// 库存食材匹配 / 覆盖判断回归。纯函数，零网络/零 localStorage/零 DOM，不读真实 data JSON。
// 断言贴合当前真实实现（实测核对过），只锁公开返回值与稳定不变量。
import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  isInventoryAvailable,
  isIngredientMatch,
  getStockCoverageAnalysis
} from '../src/inventory.js';

// ── 一、isInventoryAvailable ──
test('isInventoryAvailable 真实行为', () => {
  assert.equal(isInventoryAvailable({ qty: 2, stockStatus: 'ok' }), true);   // 有量 + 正常
  assert.equal(isInventoryAvailable({ qty: 2, stockStatus: 'low' }), true);  // low 仍算有量
  assert.equal(isInventoryAvailable({ qty: 0, stockStatus: 'ok' }), false);  // qty 0 → 不可用
  assert.equal(isInventoryAvailable({ qty: 5, stockStatus: 'empty' }), false); // empty → 不可用
  assert.equal(isInventoryAvailable({ stockStatus: 'ok' }), false); // 仅状态无 qty → 当前实现按「不可用」
  assert.ok(!isInventoryAvailable(null)); // 空对象 → falsy（当前实现返回 null）
});

// ── 二、isIngredientMatch：应匹配 ──
test('isIngredientMatch 应匹配（别名 / 泛称 / generic）', () => {
  assert.equal(isIngredientMatch('土豆', '马铃薯'), true); // 别名
  assert.equal(isIngredientMatch('土豆', '洋芋'), true);   // 别名
  assert.equal(isIngredientMatch('香菇', '干香菇'), true); // 前缀归一
  assert.equal(isIngredientMatch('猪肉', '五花肉'), true); // RECIPE_GENERIC_MATCHES
  assert.equal(isIngredientMatch('鸡肉', '鸡腿'), true);   // RECIPE_GENERIC_MATCHES
  assert.equal(isIngredientMatch('蘑菇', '香菇'), true);   // RECIPE_GENERIC_MATCHES
  assert.equal(isIngredientMatch('肉', '猪肉'), true);     // 泛称「肉」canonical 归到「猪肉」
});

// ── 二、isIngredientMatch：不应匹配 ──
test('isIngredientMatch 不应匹配（防误配 / 防污染）', () => {
  assert.equal(isIngredientMatch('豆瓣酱', '黄豆酱'), false); // 不同酱料不等价
  assert.equal(isIngredientMatch('鸡肉', '鸡精'), false);     // 鸡肉不被鸡精污染
  assert.equal(isIngredientMatch('鱼', '鱼香'), false);       // 鱼不被鱼香误判
  assert.equal(isIngredientMatch('牛肉', '鸡肉'), false);     // 不同肉类
  assert.equal(isIngredientMatch('豆腐', '豆瓣酱'), false);   // 豆腐 ≠ 豆瓣酱
});

// ── 二、isIngredientMatch：边界（空名）──
test('isIngredientMatch 空名一律不匹配', () => {
  assert.equal(isIngredientMatch('', '土豆'), false);
  assert.equal(isIngredientMatch('土豆', ''), false);
  assert.equal(isIngredientMatch('', ''), false);
});

// ── 二、isIngredientMatch：豆制品同义（并入 INGREDIENT_ALIASES 后应匹配）──
test('isIngredientMatch 豆制品同义应匹配', () => {
  assert.equal(isIngredientMatch('豆干', '香干'), true);
  assert.equal(isIngredientMatch('豆干', '豆腐干'), true);
  assert.equal(isIngredientMatch('豆皮', '千张'), true);
  assert.equal(isIngredientMatch('豆皮', '百叶'), true);
  assert.equal(isIngredientMatch('腐竹', '支竹'), true);
});

test('isIngredientMatch 豆制品防误伤（不应匹配）', () => {
  assert.equal(isIngredientMatch('豆瓣酱', '豆干'), false);
  assert.equal(isIngredientMatch('豆腐', '豆皮'), false);   // 不因「豆」字误配
  assert.equal(isIngredientMatch('豆干', '豆腐'), false);
  assert.equal(isIngredientMatch('腐乳', '腐竹'), false);
  assert.equal(isIngredientMatch('素鸡', '千张'), false);   // 素鸡未并入，仍不匹配
});

// ── 三、getStockCoverageAnalysis ──
const inv = [
  { name: '土豆', qty: 3, unit: '个', stockStatus: 'ok' },
  { name: '番茄', qty: 0, unit: '个', stockStatus: 'ok' }, // 有状态无数量
  { name: '牛肉', qty: 1, unit: '斤', stockStatus: 'ok' }
];

test('getStockCoverageAnalysis 同名同单位 → exact，coveredQty 暴露库存总量', () => {
  const a = getStockCoverageAnalysis(inv, '土豆', 2, '个'); // 需求 2 ≤ 库存 3
  assert.equal(a.confidence, 'exact');
  assert.equal(a.coveredQty, 3);
  assert.deepEqual(a.matchedItems.map(x => x.name), ['土豆']);
});

test('getStockCoverageAnalysis 同名同单位但需求超量 → 仍 exact，缺口由 coveredQty 体现', () => {
  const a = getStockCoverageAnalysis(inv, '土豆', 5, '个'); // 需求 5 > 库存 3
  assert.equal(a.confidence, 'exact'); // confidence 不表达「够不够」
  assert.equal(a.coveredQty, 3);
  assert.ok(a.coveredQty < 5); // 缺口：调用方据此判断不足
});

test('getStockCoverageAnalysis 同名不同单位 → unit-mismatch，不误判 exact', () => {
  const a = getStockCoverageAnalysis(inv, '土豆', 1, '斤');
  assert.equal(a.confidence, 'unit-mismatch');
  assert.equal(a.coveredQty, 0);
});

test('getStockCoverageAnalysis 同名但 qty=0 且状态 ok → status-only', () => {
  const a = getStockCoverageAnalysis(inv, '番茄', 1, '个');
  assert.equal(a.confidence, 'status-only');
  assert.equal(a.coveredQty, 0);
});

test('getStockCoverageAnalysis 别名匹配（马铃薯→土豆）→ exact', () => {
  const a = getStockCoverageAnalysis(inv, '马铃薯', 1, '个');
  assert.equal(a.confidence, 'exact');
  assert.equal(a.coveredQty, 3);
});

test('getStockCoverageAnalysis 无匹配 → none', () => {
  const a = getStockCoverageAnalysis(inv, '鸡肉', 1, '份');
  assert.equal(a.confidence, 'none');
  assert.equal(a.coveredQty, 0);
  assert.equal(a.matchedItems.length, 0);
});

test('getStockCoverageAnalysis 多个同名同单位库存项 → 数量聚合', () => {
  const inv2 = [
    { name: '土豆', qty: 3, unit: '个', stockStatus: 'ok' },
    { name: '土豆', qty: 2, unit: '个', stockStatus: 'ok' }
  ];
  const a = getStockCoverageAnalysis(inv2, '土豆', 1, '个');
  assert.equal(a.confidence, 'exact');
  assert.equal(a.coveredQty, 5); // 3 + 2 聚合
  assert.equal(a.matchedItems.length, 2);
});

// ── 四、边界：空 inventory / 空名 ──
test('getStockCoverageAnalysis 空 inventory / 空名 → none', () => {
  assert.equal(getStockCoverageAnalysis([], '土豆', 1, '个').confidence, 'none');
  assert.equal(getStockCoverageAnalysis(inv, '', 1, '个').confidence, 'none');
});
