import test from 'node:test';
import assert from 'node:assert/strict';

import { nextTabIndex, TABLIST_KEYS } from '../src/utils/tablist-keyboard.js';

test('Left/Right move within the tablist and wrap at both ends', () => {
  assert.equal(nextTabIndex('ArrowRight', 0, 2), 1);
  assert.equal(nextTabIndex('ArrowLeft', 1, 2), 0);
  // 环绕：末尾按右回到第一个，开头按左回到最后一个。
  assert.equal(nextTabIndex('ArrowRight', 1, 2), 0);
  assert.equal(nextTabIndex('ArrowLeft', 0, 2), 1);
});

test('Home/End jump to the first and last tab', () => {
  assert.equal(nextTabIndex('Home', 2, 3), 0);
  assert.equal(nextTabIndex('End', 0, 3), 2);
  assert.equal(nextTabIndex('Home', 0, 3), 0);
  assert.equal(nextTabIndex('End', 2, 3), 2);
});

test('keys the tablist does not own are left for the browser', () => {
  // -1 让调用方直接 return，不 preventDefault —— 否则 Tab / Shift+Tab 会被吃掉，
  // 键盘用户就再也走不出这个 tablist。
  for (const key of ['Tab', 'Enter', ' ', 'Escape', 'ArrowUp', 'ArrowDown', 'a']) {
    assert.equal(nextTabIndex(key, 0, 2), -1, `${key} 不应被 tablist 拦截`);
  }
});

test('degenerate inputs never produce an out-of-range index', () => {
  assert.equal(nextTabIndex('ArrowRight', 0, 0), -1);
  assert.equal(nextTabIndex('ArrowRight', 5, 2), -1);
  assert.equal(nextTabIndex('ArrowRight', -1, 2), -1);
  assert.equal(nextTabIndex('Home', 0, undefined), -1);
});

test('every advertised tablist key is actually handled', () => {
  for (const key of TABLIST_KEYS) {
    assert.notEqual(nextTabIndex(key, 0, 2), -1, `${key} 应被处理`);
  }
});
