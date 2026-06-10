// test/food-input-parser.test.mjs
// 「每行一个食材」轻量解析回归。纯函数，零网络/零 localStorage/零 DOM。
import { test } from 'node:test';
import assert from 'node:assert/strict';

import { parseFoodLines } from '../src/utils/food-input-parser.js';

test('名称 + 数量 + 单位（有无空格都支持）', () => {
  assert.deepEqual(parseFoodLines('鸡蛋 6个'), [{ name: '鸡蛋', qty: 6, unit: '个' }]);
  assert.deepEqual(parseFoodLines('鸡蛋 6 个'), [{ name: '鸡蛋', qty: 6, unit: '个' }]);
  assert.deepEqual(parseFoodLines('鸡蛋6个'), [{ name: '鸡蛋', qty: 6, unit: '个' }]);
});

test('只有数量没有单位 → unit 留空（由调用方推断）', () => {
  assert.deepEqual(parseFoodLines('鸡蛋 6'), [{ name: '鸡蛋', qty: 6, unit: '' }]);
});

test('只写名字 → qty=1，unit 留空', () => {
  assert.deepEqual(parseFoodLines('土豆'), [{ name: '土豆', qty: 1, unit: '' }]);
});

test('多行混合 + 空行忽略', () => {
  assert.deepEqual(parseFoodLines('鸡蛋 6个\n\n番茄 3个\n土豆\n   \n豆腐 1盒'), [
    { name: '鸡蛋', qty: 6, unit: '个' },
    { name: '番茄', qty: 3, unit: '个' },
    { name: '土豆', qty: 1, unit: '' },
    { name: '豆腐', qty: 1, unit: '盒' }
  ]);
});

test('小数数量', () => {
  assert.deepEqual(parseFoodLines('牛肉 1.5斤'), [{ name: '牛肉', qty: 1.5, unit: '斤' }]);
});

test('空字符串 / null / undefined → []', () => {
  assert.deepEqual(parseFoodLines(''), []);
  assert.deepEqual(parseFoodLines('   '), []);
  assert.deepEqual(parseFoodLines(null), []);
  assert.deepEqual(parseFoodLines(undefined), []);
});
