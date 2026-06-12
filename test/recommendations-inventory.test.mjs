// test/recommendations-inventory.test.mjs
// 上层缺货/可做判断回归：analyzeRecipeInventory 把逐食材覆盖聚合为菜谱级 status / missing / uncertain。
// 内存 mock recipe + inventory，不读真实 data JSON、不测 DOM/网络。
// 经 staples 间接读 localStorage → 安装空内存 stub 保证确定性（普通食材非常备品，拦截 inert）。
// 断言均贴合实测真实行为。
import { test, beforeEach } from 'node:test';
import assert from 'node:assert/strict';

import { installLocalStorageStub, resetLocalStorage } from './helpers/localstorage-stub.mjs';
import {
  analyzeRecipeInventory,
  calculateStockStatus,
  getMissingRecipeIngredients
} from '../src/recommendations.js';

beforeEach(() => {
  installLocalStorageStub();
  resetLocalStorage(); // 空常备配置 → isPantryStaple('土豆')=false → 拦截对普通食材无影响
});

const RECIPE = { id: 'r1', name: '测试菜' };
const EMPTY_PACK = { recipe_ingredients: {} };
// 直接用 fallbackItems 传食材列表，绕过 pack.recipe_ingredients
const analyze = (inv, items) => analyzeRecipeInventory(RECIPE, EMPTY_PACK, inv, items);
const names = (arr) => arr.map(x => x.name || x.item);

// 1) 核心食材齐全且数量足够 → ok
test('核心食材齐全且数量足够 → status=ok', () => {
  const a = analyze(
    [{ name: '土豆', qty: 3, unit: '个', stockStatus: 'ok' }, { name: '猪肉', qty: 2, unit: '份', stockStatus: 'ok' }],
    [{ item: '土豆', qty: 2, unit: '个' }, { item: '猪肉', qty: 1, unit: '份' }, { item: '盐' }]
  );
  assert.equal(a.status, 'ok');
  assert.equal(a.totalCore, 2);      // 盐被当调料过滤
  assert.equal(a.matchCount, 2);
  assert.equal(a.missing.length, 0);
  assert.equal(a.uncertain.length, 0);
});

// 2) 缺少一个核心食材 → partial，并列出 missing
test('缺一个核心食材 → status=partial 且 missing 含缺项', () => {
  const a = analyze(
    [{ name: '土豆', qty: 3, unit: '个', stockStatus: 'ok' }],
    [{ item: '土豆', qty: 2, unit: '个' }, { item: '牛肉', qty: 1, unit: '份' }]
  );
  assert.equal(a.status, 'partial');
  assert.deepEqual(names(a.missing), ['牛肉']);
  assert.equal(a.matchCount, 1);
});

// 3) 全部核心食材缺失 → none
test('全部核心食材缺失 → status=none', () => {
  const a = analyze(
    [{ name: '土豆', qty: 3, unit: '个', stockStatus: 'ok' }],
    [{ item: '牛肉', qty: 1, unit: '份' }, { item: '鸡肉', qty: 1, unit: '份' }]
  );
  assert.equal(a.status, 'none');
  assert.deepEqual(names(a.missing).sort(), ['牛肉', '鸡肉']);
  assert.equal(a.matchCount, 0);
});

// 4) 调料类不应导致缺货
test('调料类食材被过滤，不计入 totalCore / 不进 missing', () => {
  const a = analyze(
    [{ name: '土豆', qty: 3, unit: '个', stockStatus: 'ok' }],
    [{ item: '土豆', qty: 2, unit: '个' }, { item: '盐' }, { item: '生抽' }]
  );
  assert.equal(a.status, 'ok');
  assert.equal(a.totalCore, 1);
  assert.ok(!names(a.missing).includes('盐'));
  assert.ok(!names(a.missing).includes('生抽'));
});

// 5) 同名不同单位 → 进 uncertain（unit-mismatch），不误算 missing
test('同名不同单位 → uncertain(unit-mismatch)，不算 missing', () => {
  const a = analyze(
    [{ name: '土豆', qty: 3, unit: '个', stockStatus: 'ok' }],
    [{ item: '土豆', qty: 1, unit: '斤' }]
  );
  assert.equal(a.status, 'partial');
  assert.equal(a.missing.length, 0);
  assert.equal(a.uncertain.length, 1);
  assert.equal(a.uncertain[0].reason, 'unit-mismatch');
  assert.equal(a.coverageConfidence, 'unit-mismatch');
});

// 6) 数量不足 → 体现缺口（进 missing）
test('数量不足 → 缺口体现在 missing（配合够量项 → partial）', () => {
  const a = analyze(
    [{ name: '土豆', qty: 3, unit: '个', stockStatus: 'ok' }, { name: '猪肉', qty: 2, unit: '份', stockStatus: 'ok' }],
    [{ item: '土豆', qty: 5, unit: '个' }, { item: '猪肉', qty: 1, unit: '份' }]
  );
  assert.equal(a.status, 'partial');
  assert.ok(names(a.missing).includes('土豆')); // 需求 5 > 库存 3 → 缺
});

test('数量不足（单一食材，无其它 match/uncertain）→ status=none（真实行为）', () => {
  const a = analyze(
    [{ name: '土豆', qty: 3, unit: '个', stockStatus: 'ok' }],
    [{ item: '土豆', qty: 5, unit: '个' }]
  );
  assert.equal(a.status, 'none');
  assert.ok(names(a.missing).includes('土豆'));
});

// 7) 库存只有 qty:0 的匹配项 → 不算可用（status-only → uncertain，非 match）
test('库存匹配项 qty=0 → status-only，不算可用、不进 missing', () => {
  const a = analyze(
    [{ name: '番茄', qty: 0, unit: '个', stockStatus: 'ok' }],
    [{ item: '番茄', qty: 1, unit: '个' }]
  );
  assert.equal(a.status, 'partial');
  assert.equal(a.matchCount, 0);           // qty0 不算可用匹配
  assert.equal(a.missing.length, 0);
  assert.equal(a.uncertain.length, 1);
  assert.equal(a.uncertain[0].reason, 'status-only');
});

// 8) 同义词匹配：马铃薯→土豆
test('同义词匹配：库存土豆 满足菜谱马铃薯 → ok', () => {
  const a = analyze(
    [{ name: '土豆', qty: 3, unit: '个', stockStatus: 'ok' }],
    [{ item: '马铃薯', qty: 2, unit: '个' }]
  );
  assert.equal(a.status, 'ok');
  assert.equal(a.matchCount, 1);
  assert.equal(a.missing.length, 0);
});

test('统一匹配用于缺货判断：番茄/西红柿双向、鸡腿覆盖鸡肉，不误报缺货', () => {
  const tomato = analyze(
    [{ name: '番茄', qty: 2, unit: '个', stockStatus: 'ok' }],
    [{ item: '西红柿', qty: 1, unit: '个' }]
  );
  assert.equal(tomato.status, 'ok');
  assert.equal(tomato.missing.length, 0);

  const chicken = analyze(
    [{ name: '鸡腿', qty: 2, unit: '个', stockStatus: 'ok' }],
    [{ item: '鸡肉', qty: 1, unit: '个' }]
  );
  assert.equal(chicken.status, 'ok');
  assert.equal(chicken.missing.length, 0);
});

// 额外：仅调料（无核心食材）→ unknown
test('菜谱仅含调料（totalCore=0）→ status=unknown', () => {
  const a = analyze([], [{ item: '盐' }, { item: '生抽' }]);
  assert.equal(a.status, 'unknown');
  assert.equal(a.totalCore, 0);
});

// 额外：包装函数 calculateStockStatus / getMissingRecipeIngredients
test('包装函数返回结构正确', () => {
  const cs = calculateStockStatus(
    RECIPE,
    { recipe_ingredients: { r1: [{ item: '土豆', qty: 2, unit: '个' }, { item: '牛肉', qty: 1, unit: '份' }] } },
    [{ name: '土豆', qty: 3, unit: '个', stockStatus: 'ok' }]
  );
  assert.deepEqual(Object.keys(cs).sort(), ['coverageConfidence', 'missing', 'needsConfirm', 'status', 'uncertain']);
  assert.equal(cs.status, 'partial');

  const miss = getMissingRecipeIngredients(
    RECIPE, EMPTY_PACK,
    [{ name: '土豆', qty: 3, unit: '个', stockStatus: 'ok' }],
    [{ item: '牛肉', qty: 1, unit: '份' }]
  );
  assert.deepEqual(names(miss), ['牛肉']);
});

// 守门：统一调料口径后，高汤/清水/十三香/咖喱 不应被当核心食材算缺货
test('菜谱仅含 高汤/清水/盐/生抽（均调料）→ 不算核心、不进 missing、status=unknown', () => {
  const a = analyze([], [{ item: '高汤' }, { item: '清水' }, { item: '盐' }, { item: '生抽' }]);
  assert.equal(a.totalCore, 0);
  assert.equal(a.missing.length, 0);
  assert.equal(a.status, 'unknown');
});

test('核心食材 + 高汤/十三香/咖喱 → 只对核心做缺货判断，调料不进 missing', () => {
  const a = analyze(
    [{ name: '土豆', qty: 3, unit: '个', stockStatus: 'ok' }],
    [{ item: '土豆', qty: 2, unit: '个' }, { item: '牛肉', qty: 1, unit: '份' }, { item: '高汤' }, { item: '十三香' }, { item: '咖喱' }]
  );
  assert.equal(a.totalCore, 2);                 // 仅 土豆 + 牛肉
  assert.deepEqual(names(a.missing), ['牛肉']); // 高汤/十三香/咖喱 不在 missing
  assert.equal(a.status, 'partial');
  for (const s of ['高汤', '十三香', '咖喱', '清水']) {
    assert.ok(!names(a.missing).includes(s), `${s} 不应进 missing`);
  }
});

// 守门：豆制品同义并入后，库存有同义品 → 不应误判缺货
test('菜谱要豆干/豆皮/腐竹，库存有香干/千张/支竹 → 不误判缺货（status=ok）', () => {
  const cases = [
    { need: '豆干', stock: '香干' },
    { need: '豆皮', stock: '千张' },
    { need: '腐竹', stock: '支竹' }
  ];
  for (const { need, stock } of cases) {
    const a = analyze(
      [{ name: stock, qty: 3, unit: '份', stockStatus: 'ok' }],
      [{ item: need, qty: 1, unit: '份' }]
    );
    assert.equal(a.missing.length, 0, `${need} 应被库存 ${stock} 满足，不进 missing`);
    assert.equal(a.status, 'ok', `${need} vs ${stock} → ok`);
  }
});
