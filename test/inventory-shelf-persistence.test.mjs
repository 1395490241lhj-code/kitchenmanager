// test/inventory-shelf-persistence.test.mjs
// shelf=0（当天到期）是合法值，JS 里 0 是 falsy，loadInventory() 之前用 `!i.shelf` 判断
// 缺失会把明确保存的 shelf=0 错误替换成默认值。这里直接调用真实的 loadInventory()/
// saveInventory() 验证修复，不做源码字符串断言。
import test, { beforeEach } from 'node:test';
import assert from 'node:assert/strict';

import { installLocalStorageStub, resetLocalStorage } from './helpers/localstorage-stub.mjs';
import { S } from '../src/storage.js';
import { isMissingShelfValue, loadInventory, normalizeShelfValue, saveInventory } from '../src/inventory.js';

beforeEach(() => {
  installLocalStorageStub();
  resetLocalStorage();
});

// 用非干货食材名，避免触发 loadInventory 里干货专属的 shelf 兜底分支（不在本次修复范围）。
const NAME = '苹果';

function seedInventory(items) {
  S.save(S.keys.inventory, items);
}

test('shelf=0 经过 loadInventory 后仍为 0', () => {
  seedInventory([{ name: NAME, qty: 1, unit: '个', shelf: 0 }]);
  const [item] = loadInventory([]);
  assert.equal(item.shelf, 0);
});

test("shelf='0' 经过 loadInventory 后归一为数字 0", () => {
  seedInventory([{ name: NAME, qty: 1, unit: '个', shelf: '0' }]);
  const [item] = loadInventory([]);
  assert.equal(item.shelf, 0);
  assert.equal(typeof item.shelf, 'number');
});

test('shelf undefined 使用默认值', () => {
  seedInventory([{ name: NAME, qty: 1, unit: '个' }]);
  const [item] = loadInventory([]);
  assert.equal(item.shelf, 7);
});

test('shelf null 使用默认值', () => {
  seedInventory([{ name: NAME, qty: 1, unit: '个', shelf: null }]);
  const [item] = loadInventory([]);
  assert.equal(item.shelf, 7);
});

test("shelf='' 使用默认值", () => {
  seedInventory([{ name: NAME, qty: 1, unit: '个', shelf: '' }]);
  const [item] = loadInventory([]);
  assert.equal(item.shelf, 7);
});

test("shelf='   '（纯空格）使用默认值", () => {
  seedInventory([{ name: NAME, qty: 1, unit: '个', shelf: '   ' }]);
  const [item] = loadInventory([]);
  assert.equal(item.shelf, 7);
});

test('shelf=7 保持 7', () => {
  seedInventory([{ name: NAME, qty: 1, unit: '个', shelf: 7 }]);
  const [item] = loadInventory([]);
  assert.equal(item.shelf, 7);
});

test("shelf='14' 正常归一为数字 14", () => {
  seedInventory([{ name: NAME, qty: 1, unit: '个', shelf: '14' }]);
  const [item] = loadInventory([]);
  assert.equal(item.shelf, 14);
  assert.equal(typeof item.shelf, 'number');
});

test('保存后重新 loadInventory，shelf=0 不变', () => {
  seedInventory([{ name: NAME, qty: 1, unit: '个', shelf: 0 }]);
  const inv = loadInventory([]);
  saveInventory(inv);
  const reloaded = loadInventory([]);
  assert.equal(reloaded[0].shelf, 0);
});

test('shelf 缺失时优先用 catalog 里对应食材的 shelf 兜底，而不是硬编码 7', () => {
  seedInventory([{ name: NAME, qty: 1, unit: '个' }]);
  const [item] = loadInventory([{ name: NAME, unit: '个', shelf: 5 }]);
  assert.equal(item.shelf, 5);
});

test('非法字符串 shelf 回退默认值，而不是变成 NaN', () => {
  seedInventory([{ name: NAME, qty: 1, unit: '个', shelf: 'abc' }]);
  const [item] = loadInventory([]);
  assert.equal(item.shelf, 7);
});

// ── isMissingShelfValue / normalizeShelfValue 辅助函数本身 ──

test('isMissingShelfValue：只有 undefined/null/空白字符串算缺失，0 和 \'0\' 不算', () => {
  assert.equal(isMissingShelfValue(undefined), true);
  assert.equal(isMissingShelfValue(null), true);
  assert.equal(isMissingShelfValue(''), true);
  assert.equal(isMissingShelfValue('   '), true);
  assert.equal(isMissingShelfValue(0), false);
  assert.equal(isMissingShelfValue('0'), false);
  assert.equal(isMissingShelfValue(7), false);
});

test('normalizeShelfValue：合法数字/数字字符串转 Number，非法字符串回退 fallback', () => {
  assert.equal(normalizeShelfValue(0, 7), 0);
  assert.equal(normalizeShelfValue('0', 7), 0);
  assert.equal(normalizeShelfValue('14', 7), 14);
  assert.equal(normalizeShelfValue(undefined, 7), 7);
  assert.equal(normalizeShelfValue('abc', 7), 7);
});
