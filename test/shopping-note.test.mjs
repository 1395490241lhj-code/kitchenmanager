// test/shopping-note.test.mjs
// 纯函数回归：待买速记解析 / 购物项合并 / 已完成 24h 隐藏。
// 零网络、内存版 localStorage、零 DOM、不读真实 data JSON。运行：npm test（node --test）。
import { beforeEach, test } from 'node:test';
import assert from 'node:assert/strict';

import { S } from '../src/storage.js';
import {
  clearDoneShoppingItems,
  parseShoppingNoteText,
  mergeShoppingItems,
  shouldHideCompletedShoppingItem,
  getVisibleShoppingItems,
  isShoppingItemCompleted,
  COMPLETED_SHOPPING_VISIBLE_HOURS,
  loadShoppingItems,
  markShoppingItemActive
} from '../src/shopping.js';
import { installLocalStorageStub, resetLocalStorage } from './helpers/localstorage-stub.mjs';

const byName = (items) => items.reduce((m, it) => (m[it.name] = it, m), {});

beforeEach(() => {
  installLocalStorageStub();
  resetLocalStorage();
});

// ── 一、parseShoppingNoteText ──
test('parseShoppingNoteText 解析常见格式', () => {
  const { items, skipped } = parseShoppingNoteText('鸡蛋 1盒\n土豆*3\n苹果 x 4\n葱');
  const m = byName(items);
  assert.deepEqual(m['鸡蛋'], { name: '鸡蛋', qty: 1, unit: '盒' });
  assert.deepEqual(m['土豆'], { name: '土豆', qty: 3, unit: '' });
  assert.deepEqual(m['苹果'], { name: '苹果', qty: 4, unit: '' });
  assert.deepEqual(m['葱'], { name: '葱', qty: 1, unit: '' }); // 无数量 → 默认 qty 1、unit 空
  assert.equal(items.length, 4);
  assert.equal(skipped, 0);
});

test('parseShoppingNoteText 多行 + 逗号/顿号/空格分隔 + 空行跳过', () => {
  const { items, skipped } = parseShoppingNoteText('土豆*3, 苹果 x 4\n\n葱、香菜\n  ');
  const names = items.map(i => i.name);
  assert.ok(names.includes('土豆'));
  assert.ok(names.includes('苹果'));
  assert.ok(names.includes('葱'));
  assert.ok(names.includes('香菜'));
  assert.equal(items.length, 4); // 空行不产生条目、不计入 skipped
  assert.equal(skipped, 0);
});

test('parseShoppingNoteText 无数量名称保留合理默认值；纯符号行计入 skipped', () => {
  const { items, skipped } = parseShoppingNoteText('巧克力\n-');
  const m = byName(items);
  assert.deepEqual(m['巧克力'], { name: '巧克力', qty: 1, unit: '' }); // 仅名称 → 默认 qty 1
  assert.equal(items.length, 1);
  assert.equal(skipped, 1); // "-" 去项目符号后为空 → 跳过并计数
});

// ── 二、mergeShoppingItems ──
test('mergeShoppingItems 同名同单位合并数量', () => {
  const merged = mergeShoppingItems([
    { name: '苹果', qty: 2, unit: '个', done: false },
    { name: '苹果', qty: 3, unit: '个', done: false }
  ]);
  assert.equal(merged.length, 1);
  assert.equal(merged[0].name, '苹果');
  assert.equal(merged[0].unit, '个');
  assert.equal(merged[0].qty, 5); // 2 + 3
});

test('mergeShoppingItems 同名不同单位不合并', () => {
  const merged = mergeShoppingItems([
    { name: '苹果', qty: 2, unit: '个', done: false },
    { name: '苹果', qty: 1, unit: '箱', done: false }
  ]);
  assert.equal(merged.length, 2);
});

test('mergeShoppingItems 不同名称不合并', () => {
  const merged = mergeShoppingItems([
    { name: '苹果', qty: 1, unit: '个', done: false },
    { name: '香蕉', qty: 1, unit: '个', done: false }
  ]);
  assert.equal(merged.length, 2);
});

test('mergeShoppingItems done / 未完成 不被错误合并', () => {
  const merged = mergeShoppingItems([
    { name: '苹果', qty: 1, unit: '个', done: false },
    { name: '苹果', qty: 1, unit: '个', done: true }
  ]);
  assert.equal(merged.length, 2); // 完成状态不同 → 不合并
});

// ── 三、shouldHideCompletedShoppingItem / getVisibleShoppingItems（固定 now）──
const NOW = Date.parse('2026-06-08T12:00:00.000Z');
const H = 3600 * 1000;
const isoAgo = (hours) => new Date(NOW - hours * H).toISOString();

test('已完成 24h 阈值：刚完成可见、超 24h 隐藏；未完成始终可见', () => {
  assert.equal(COMPLETED_SHOPPING_VISIBLE_HOURS, 24);
  const recent = { name: '苹果', done: true, completedAt: isoAgo(1) };   // 1h 前
  const old = { name: '香蕉', done: true, completedAt: isoAgo(25) };     // 25h 前
  const open = { name: '土豆', done: false };                            // 未完成

  assert.equal(isShoppingItemCompleted(open), false);
  assert.equal(shouldHideCompletedShoppingItem(recent, NOW), false); // 刚完成不隐藏
  assert.equal(shouldHideCompletedShoppingItem(old, NOW), true);     // 超 24h 隐藏
  assert.equal(shouldHideCompletedShoppingItem(open, NOW), false);   // 未完成永不隐藏

  const visible = getVisibleShoppingItems([recent, old, open], { now: NOW }).map(i => i.name);
  assert.ok(visible.includes('苹果'), '刚完成应可见');
  assert.ok(visible.includes('土豆'), '未完成应可见');
  assert.ok(!visible.includes('香蕉'), '完成超 24h 应隐藏');
  assert.equal(visible.length, 2);
});

test('loadShoppingItems：历史 stockedIn=true 但 done=false 的项会归为已完成', () => {
  S.save(S.keys.shopping_items, [
    { id: 's1', name: '苹果', qty: 2, unit: '个', done: false, stockedIn: true, stockedInAt: isoAgo(1) }
  ]);
  const [item] = loadShoppingItems();
  assert.equal(item.done, true);
  assert.equal(item.stockedIn, true);
  assert.equal(item.stockedInAt, isoAgo(1));
  assert.equal(isShoppingItemCompleted(item), true);
});

test('clearDoneShoppingItems：stockedIn-only 历史完成项也会被清理', () => {
  S.save(S.keys.shopping_items, [
    { id: 's1', name: '苹果', qty: 2, unit: '个', done: false, stockedIn: true, stockedInAt: isoAgo(1) },
    { id: 's2', name: '土豆', qty: 1, unit: '个', done: false, stockedIn: false }
  ]);
  const left = clearDoneShoppingItems();
  assert.deepEqual(left.map(item => item.name), ['土豆']);
});

test('markShoppingItemActive：取消已买会清空入库状态和入库时间', () => {
  S.save(S.keys.shopping_items, [
    { id: 's1', name: '苹果', qty: 2, unit: '个', done: true, stockedIn: true, stockedInAt: isoAgo(1), completedAt: isoAgo(1) }
  ]);
  markShoppingItemActive('s1');
  const [item] = loadShoppingItems();
  assert.equal(item.done, false);
  assert.equal(item.stockedIn, false);
  assert.equal(item.stockedInAt, null);
  assert.equal(item.completedAt, null);
});
