import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  classifyReceiptItem,
  normalizeReceiptQuantityForKitchen,
  validateReceiptItems,
  validateReceiptResult
} from '../src/ai.js';

test('新格式 receipt JSON 可解析出 inventory / pantry / review / ignored', () => {
  const out = validateReceiptResult({
    inventory: [{ originalName: 'Pork Belly', name: '五花肉', qty: 1, unit: '盒' }],
    pantry: [{ originalName: 'Noodles', name: '挂面', qty: 1, unit: '包' }],
    review: [{ originalName: 'Frozen Dumplings', name: '速冻水饺', qty: 1, unit: '袋' }],
    ignored: [{ originalName: 'Shopping Bag', reason: '非食品' }]
  });
  assert.equal(out.inventory[0].name, '五花肉');
  assert.equal(out.pantry[0].name, '挂面');
  assert.equal(out.review[0].name, '速冻水饺');
  assert.equal(out.ignored[0].originalName, 'Shopping Bag');
});

test('旧数组格式仍兼容，核心鲜货进入 inventory', () => {
  const out = validateReceiptResult([
    { originalName: 'Tomato', name: '番茄', qty: 3, unit: '个' },
    { originalName: 'Egg', name: '鸡蛋', qty: 6, unit: '个' }
  ]);
  assert.deepEqual(out.inventory.map(item => item.name), ['番茄', '鸡蛋']);
  assert.equal(validateReceiptItems([{ name: '番茄', qty: 3, unit: '个' }])[0].name, '番茄');
});

test('水饺 / 抄手 / 馄饨 / 汤圆 默认进入 review，不进入 inventory', () => {
  const out = validateReceiptResult([
    { name: '水饺' },
    { name: '抄手' },
    { name: '馄饨' },
    { name: '汤圆' }
  ]);
  assert.deepEqual(out.inventory, []);
  assert.deepEqual(out.review.map(item => item.name), ['水饺', '抄手', '馄饨', '汤圆']);
});

test('苹果 / 香蕉 / 葡萄等水果默认进入 review，不进入 inventory', () => {
  const out = validateReceiptResult([
    { name: '苹果' },
    { name: '香蕉' },
    { name: '葡萄' }
  ]);
  assert.deepEqual(out.inventory, []);
  assert.deepEqual(out.review.map(item => item.name), ['苹果', '香蕉', '葡萄']);
});

test('大米 / 挂面 / 面粉 / 干木耳 / 腐竹进入 pantry，不进入 inventory', () => {
  const out = validateReceiptResult([
    { name: '大米' },
    { name: '挂面' },
    { name: '面粉' },
    { name: '干木耳' },
    { name: '腐竹' }
  ]);
  assert.deepEqual(out.inventory, []);
  assert.deepEqual(out.pantry.map(item => item.name), ['大米', '挂面', '面粉', '干木耳', '腐竹']);
});

test('购物袋 / 税费 / 折扣进入 ignored 或被丢弃', () => {
  const out = validateReceiptResult([
    { originalName: 'Shopping Bag', name: '购物袋' },
    { originalName: 'Tax', name: '税费' },
    { originalName: 'Discount', name: '折扣' }
  ]);
  assert.deepEqual(out.inventory, []);
  assert.deepEqual(out.ignored.map(item => item.name), ['购物袋', '税费', '折扣']);
});

test('本地兜底优先：AI 错把水果/干货放 inventory 也会重新分组', () => {
  const out = validateReceiptResult({
    inventory: [
      { name: '苹果' },
      { name: '挂面' },
      { name: '五花肉' }
    ]
  });
  assert.deepEqual(out.inventory.map(item => item.name), ['五花肉']);
  assert.deepEqual(out.pantry.map(item => item.name), ['挂面']);
  assert.deepEqual(out.review.map(item => item.name), ['苹果']);
});

test('classifyReceiptItem 明确分组：佐料不进入 inventory，清水被忽略', () => {
  assert.equal(classifyReceiptItem('生抽').group, 'pantry');
  assert.equal(classifyReceiptItem('清水').group, 'ignored');
  assert.equal(classifyReceiptItem('豆腐').group, 'inventory');
});

test('橘子 / 桔子 / mandarin orange 进入 review，不进入 inventory', () => {
  const out = validateReceiptResult([
    { name: '橘子' },
    { name: '桔子' },
    { originalName: 'Mandarin Orange', name: 'mandarin orange' }
  ]);
  assert.deepEqual(out.inventory, []);
  assert.deepEqual(out.review.map(item => item.name), ['橘子', '桔子', 'mandarin orange']);
});

test('方便面 / instant noodle / ramen 进入 review，不进入 inventory', () => {
  const out = validateReceiptResult([
    { name: '方便面' },
    { originalName: 'Instant Noodle', name: 'instant noodle' },
    { originalName: 'Ramen', name: 'ramen' }
  ]);
  assert.deepEqual(out.inventory, []);
  assert.deepEqual(out.review.map(item => item.name), ['方便面', 'instant noodle', 'ramen']);
});

test('姜葱蒜英文别名进入 pantry，不进入 inventory', () => {
  const out = validateReceiptResult([
    { name: '姜' },
    { originalName: 'Ginger', name: 'ginger' },
    { originalName: 'Green Onion', name: 'green onion' },
    { originalName: 'Garlic', name: 'garlic' },
    { name: '大蒜' }
  ]);
  assert.deepEqual(out.inventory, []);
  assert.deepEqual(out.pantry.map(item => item.name), ['姜', 'ginger', 'green onion', 'garlic', '大蒜']);
});

test('小票重量会按份估算，不保存 lb/kg/g 到普通食材', () => {
  const out = validateReceiptResult([
    { originalName: 'Pork 2 lb', name: '猪肉', qty: 2, unit: 'lb' },
    { originalName: 'Beef 0.81 lb', name: '牛肉', qty: 0.81, unit: 'lb' },
    { originalName: 'Shrimp 450 g', name: '虾', qty: 450, unit: 'g' },
    { originalName: 'Fish 0.35 kg', name: '鱼', qty: 0.35, unit: 'kg' }
  ]);
  assert.deepEqual(out.inventory.map(item => [item.name, item.qty, item.unit]), [
    ['猪肉', 2, '份'],
    ['牛肉', 1, '份'],
    ['虾', 1, '份'],
    ['鱼', 1, '份']
  ]);
  assert.ok(out.inventory.every(item => !['lb', 'kg', 'g'].includes(item.unit)));
  assert.match(out.inventory[1].reason, /按 0.81 lb 估算/);
});

test('原文里的重量优先纠偏，避免 0.81 被当成个数入库', () => {
  const out = validateReceiptResult([
    { originalName: 'Beef 0.81 lb', name: '牛肉', qty: 0.81, unit: '个' }
  ]);
  assert.equal(out.inventory[0].qty, 1);
  assert.equal(out.inventory[0].unit, '份');
});

test('包装商品小数数量会取整，避免 0.81 个直接入库', () => {
  const out = validateReceiptResult([
    { originalName: 'Tomato pack', name: '番茄', qty: 0.81, unit: '个' }
  ]);
  assert.equal(out.inventory[0].qty, 1);
  assert.equal(out.inventory[0].unit, '个');
  assert.match(out.inventory[0].reason, /包装取整/);
});

test('normalizeReceiptQuantityForKitchen 可单独估算重量', () => {
  assert.deepEqual(
    normalizeReceiptQuantityForKitchen({ name: '猪肉', qty: 2, unit: 'lb' }, 'inventory'),
    { name: '猪肉', qty: 2, unit: '份', note: '按 2 lb 估算，可在加入前调整份数' }
  );
});
