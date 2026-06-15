import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  classifyReceiptItem,
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
