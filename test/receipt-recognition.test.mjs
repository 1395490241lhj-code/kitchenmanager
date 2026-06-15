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

test('Freshway 小票：速食面和加工小食进入 review，不进 pantry/inventory', () => {
  const out = validateReceiptResult([
    { originalName: 'Spicy Seafood Noodle', name: 'Spicy Seafood Noodle', qty: 1, unit: '包' },
    { originalName: 'Dried Anchovy w/Peanut', name: 'Dried Anchovy w/Peanut', qty: 1, unit: '包' },
    { originalName: 'Snowy Cake', name: 'Snowy Cake', qty: 1, unit: '盒' }
  ]);
  assert.deepEqual(out.inventory, []);
  assert.deepEqual(out.pantry, []);
  assert.deepEqual(out.review.map(item => item.name), ['Spicy Seafood Noodle', 'Dried Anchovy w/Peanut', 'Snowy Cake']);
});

test('Freshway 小票：豆腐和鲜货进入 inventory，不被忽略', () => {
  const out = validateReceiptResult([
    { originalName: 'Medium Firm Tofu', name: 'Medium Firm Tofu', qty: 1, unit: '盒' },
    { originalName: 'Yu Choy', name: 'Yu Choy', qty: 1, unit: '把' },
    { originalName: 'Beansprout', name: 'Beansprout', qty: 1, unit: '袋' },
    { originalName: 'Stem Lettuce', name: 'Stem Lettuce', qty: 1, unit: '根' },
    { originalName: 'Chicken Leg 2 lb', name: 'Chicken Leg', qty: 2, unit: 'lb' }
  ]);
  assert.deepEqual(out.ignored, []);
  assert.deepEqual(out.inventory.map(item => item.name), ['Medium Firm Tofu', 'Yu Choy', 'Beansprout', 'Stem Lettuce', 'Chicken Leg']);
  assert.equal(out.inventory.at(-1).qty, 2);
  assert.equal(out.inventory.at(-1).unit, '份');
});

test('Freshway 小票：花生进 pantry 或 review，但绝不 ignored；小鱼干花生优先 review', () => {
  const out = validateReceiptResult([
    { originalName: 'Red Skin Peanut', name: 'Red Skin Peanut', qty: 1, unit: '包' },
    { originalName: 'Dried Anchovy w/Peanut', name: 'Dried Anchovy w/Peanut', qty: 1, unit: '包' }
  ]);
  assert.deepEqual(out.ignored, []);
  assert.deepEqual(out.pantry.map(item => item.name), ['Red Skin Peanut']);
  assert.deepEqual(out.review.map(item => item.name), ['Dried Anchovy w/Peanut']);
});

test('Freshway 小票：橘子水饺粽子糕点进入 review，姜进入 pantry', () => {
  const out = validateReceiptResult([
    { originalName: 'Tangerine', name: 'Tangerine', qty: 1, unit: '袋' },
    { name: '水饺', qty: 1, unit: '袋' },
    { name: '粽子', qty: 2, unit: '个' },
    { name: '糕点', qty: 1, unit: '盒' },
    { originalName: 'Ginger', name: 'Ginger', qty: 1, unit: '袋' }
  ]);
  assert.deepEqual(out.inventory, []);
  assert.deepEqual(out.review.map(item => item.name), ['Tangerine', '水饺', '粽子', '糕点']);
  assert.deepEqual(out.pantry.map(item => item.name), ['Ginger']);
});

test('review/pantry 项不强制把重量转成份，只有 inventory 生鲜转份', () => {
  const out = validateReceiptResult([
    { originalName: 'Spicy Seafood Noodle 0.81 lb', name: 'Spicy Seafood Noodle', qty: 0.81, unit: 'lb' },
    { originalName: 'Red Skin Peanut 0.5 lb', name: 'Red Skin Peanut', qty: 0.5, unit: 'lb' },
    { originalName: 'Pork 0.81 lb', name: 'Pork', qty: 0.81, unit: 'lb' }
  ]);
  assert.deepEqual(out.review.map(item => [item.name, item.qty, item.unit]), [['Spicy Seafood Noodle', 0.81, 'lb']]);
  assert.deepEqual(out.pantry.map(item => [item.name, item.qty, item.unit]), [['Red Skin Peanut', 0.5, 'lb']]);
  assert.deepEqual(out.inventory.map(item => [item.name, item.qty, item.unit]), [['Pork', 1, '份']]);
});

test('英文豆腐变体明确进入 inventory，绝不 ignored', () => {
  const out = validateReceiptResult([
    { originalName: 'Medium Firm Tofu', name: 'medium firm tofu', qty: 1, unit: '盒' },
    { originalName: 'Firm Tofu', name: 'firm tofu', qty: 1, unit: '盒' },
    { originalName: 'Soft Tofu', name: 'soft tofu', qty: 1, unit: '盒' }
  ]);
  assert.deepEqual(out.ignored, []);
  assert.deepEqual(out.inventory.map(item => item.name), ['medium firm tofu', 'firm tofu', 'soft tofu']);
});

test('英文冷冻/粽子类：pork dumplings / wonton / sticky rice dumpling 进入 review', () => {
  const out = validateReceiptResult([
    { originalName: 'Pork Dumplings', name: 'pork dumplings', qty: 1, unit: '袋' },
    { originalName: 'Wonton', name: 'wonton', qty: 1, unit: '袋' },
    { originalName: 'Sticky Rice Dumpling', name: 'sticky rice dumpling', qty: 2, unit: '个' }
  ]);
  assert.deepEqual(out.inventory, []);
  assert.deepEqual(out.pantry, []);
  assert.deepEqual(out.review.map(item => item.name), ['pork dumplings', 'wonton', 'sticky rice dumpling']);
});

test('orange 单独输入也作为水果进入 review', () => {
  const out = validateReceiptResult([
    { originalName: 'Orange', name: 'orange', qty: 1, unit: '袋' },
    { originalName: 'Mandarin', name: 'mandarin', qty: 1, unit: '袋' },
    { originalName: 'Tangerine', name: 'tangerine', qty: 1, unit: '袋' }
  ]);
  assert.deepEqual(out.inventory, []);
  assert.deepEqual(out.review.map(item => item.name), ['orange', 'mandarin', 'tangerine']);
});

test('green onion / scallion / garlic 明确进入 pantry', () => {
  const out = validateReceiptResult([
    { originalName: 'Green Onion', name: 'green onion', qty: 1, unit: '把' },
    { originalName: 'Scallion', name: 'scallion', qty: 1, unit: '把' },
    { originalName: 'Garlic', name: 'garlic', qty: 1, unit: '包' }
  ]);
  assert.deepEqual(out.inventory, []);
  assert.deepEqual(out.pantry.map(item => item.name), ['green onion', 'scallion', 'garlic']);
});

test('choy / yu choy / stem lettuce / beansprout 明确进入 inventory', () => {
  const out = validateReceiptResult([
    { originalName: 'Choy', name: 'choy', qty: 1, unit: '把' },
    { originalName: 'Yu Choy', name: 'yu choy', qty: 1, unit: '把' },
    { originalName: 'Stem Lettuce', name: 'stem lettuce', qty: 1, unit: '根' },
    { originalName: 'Beansprout', name: 'beansprout', qty: 1, unit: '袋' }
  ]);
  assert.deepEqual(out.ignored, []);
  assert.deepEqual(out.inventory.map(item => item.name), ['choy', 'yu choy', 'stem lettuce', 'beansprout']);
});

test('boneless skin-on chicken leg 进入 inventory，称重转份', () => {
  const out = validateReceiptResult([
    { originalName: 'Boneless Skin-On Chicken Leg 1.8 lb', name: 'boneless skin-on chicken leg', qty: 1.8, unit: 'lb' }
  ]);
  assert.equal(out.inventory[0].name, 'boneless skin-on chicken leg');
  assert.equal(out.inventory[0].qty, 2);
  assert.equal(out.inventory[0].unit, '份');
  assert.deepEqual(out.review, []);
  assert.deepEqual(out.ignored, []);
});

test('包装速食保留包/袋单位，但进入 review 默认不加入', () => {
  const out = validateReceiptResult([
    { originalName: 'Instant Noodle', name: 'instant noodle', qty: 1, unit: '包' },
    { originalName: 'Ramen', name: 'ramen', qty: 2, unit: '袋' }
  ]);
  assert.deepEqual(out.inventory, []);
  assert.deepEqual(out.review.map(item => [item.name, item.qty, item.unit]), [
    ['instant noodle', 1, '包'],
    ['ramen', 2, '袋']
  ]);
});

test('receipt 校验只做内存分类，用户确认前不写 localStorage', () => {
  const previous = globalThis.localStorage;
  const calls = [];
  globalThis.localStorage = {
    getItem() { return null; },
    setItem(key, value) { calls.push([key, value]); throw new Error('should not write'); },
    removeItem(key) { calls.push([key, null]); throw new Error('should not remove'); },
    clear() { calls.push(['clear', null]); throw new Error('should not clear'); }
  };
  try {
    const out = validateReceiptResult([
      { originalName: 'Medium Firm Tofu', name: 'medium firm tofu', qty: 1, unit: '盒' },
      { originalName: 'Instant Noodle', name: 'instant noodle', qty: 1, unit: '包' }
    ]);
    assert.equal(out.inventory.length, 1);
    assert.equal(out.review.length, 1);
    assert.deepEqual(calls, []);
  } finally {
    if (previous === undefined) delete globalThis.localStorage;
    else globalThis.localStorage = previous;
  }
});
