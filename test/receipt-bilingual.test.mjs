import { test } from 'node:test';
import assert from 'node:assert/strict';

import { validateReceiptResult } from '../src/ai.js';

test('中英双证据：牛肉 Beef 按中文优先进入 inventory', () => {
  const out = validateReceiptResult({
    review: [{
      rawText: '牛肉 Beef',
      zhText: '牛肉',
      enText: 'Beef',
      canonicalName: '牛肉',
      qty: 1,
      unit: '份',
      group: 'review'
    }]
  });

  assert.deepEqual(out.inventory.map(item => item.name), ['牛肉']);
  assert.match(out.inventory[0].reason, /中文优先|中英一致/);
});

test('中英双证据：豆腐 Tofu 中英一致进入 inventory', () => {
  const out = validateReceiptResult([
    { rawText: '豆腐 Tofu', zhText: '豆腐', enText: 'Tofu', qty: 1, unit: '盒' }
  ]);

  assert.deepEqual(out.inventory.map(item => item.name), ['豆腐']);
  assert.equal(out.inventory[0].unit, '盒');
});

test('中英双证据：姜 Ginger 进入 pantry，不 ignored', () => {
  const out = validateReceiptResult([
    { rawText: '姜 Ginger', zhText: '姜', enText: 'Ginger', qty: 1, unit: '份' }
  ]);

  assert.deepEqual(out.inventory, []);
  assert.deepEqual(out.ignored, []);
  assert.deepEqual(out.pantry.map(item => item.name), ['姜']);
});

test('加工食品：猪肉白菜饺 Pork Cabbage Dumplings 进入 review', () => {
  const out = validateReceiptResult([
    { rawText: '猪肉白菜饺 Pork Cabbage Dumplings', zhText: '猪肉白菜饺', enText: 'Pork Cabbage Dumplings', qty: 1, unit: '袋' }
  ]);

  assert.deepEqual(out.inventory, []);
  assert.deepEqual(out.ignored, []);
  assert.deepEqual(out.review.map(item => item.name), ['猪肉白菜饺']);
});

test('甜点：芋泥雪贝 Taro Snowy Cake 进入 review', () => {
  const out = validateReceiptResult([
    { rawText: '芋泥雪贝 Taro Snowy Cake', zhText: '芋泥雪贝', enText: 'Taro Snowy Cake', qty: 1, unit: '盒' }
  ]);

  assert.deepEqual(out.inventory, []);
  assert.deepEqual(out.review.map(item => item.name), ['芋泥雪贝']);
});

test('中英文冲突：牛肉 Pork 进入 review 并提示需要确认', () => {
  const out = validateReceiptResult([
    { rawText: '牛肉 Pork', zhText: '牛肉', enText: 'Pork', qty: 1, unit: '份' }
  ]);

  assert.deepEqual(out.inventory, []);
  assert.deepEqual(out.review.map(item => item.name), ['牛肉']);
  assert.match(out.review[0].reason, /中英文信息不一致|需要确认/);
});

test('未知但像食物：Green Ton Choy 进入 review，不 ignored', () => {
  const out = validateReceiptResult([
    { rawText: 'Green Ton Choy', enText: 'Green Ton Choy', qty: 0.94, unit: 'lb' }
  ]);

  assert.deepEqual(out.inventory, []);
  assert.deepEqual(out.ignored, []);
  assert.deepEqual(out.review.map(item => item.name), ['Green Ton Choy']);
});

test('明显非食物：TAX 进入 ignored', () => {
  const out = validateReceiptResult([
    { rawText: 'TAX', enText: 'TAX' }
  ]);

  assert.deepEqual(out.ignored.map(item => item.name), ['TAX']);
});

test('没有中文时用英文：Medium Firm Tofu 进入 inventory', () => {
  const out = validateReceiptResult([
    { rawText: 'Medium Firm Tofu', enText: 'Medium Firm Tofu', qty: 1, unit: '盒' }
  ]);

  assert.deepEqual(out.inventory.map(item => item.name), ['豆腐']);
  assert.deepEqual(out.ignored, []);
});
