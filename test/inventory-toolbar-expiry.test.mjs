import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';

import {
  FROZEN_DEFAULT_SHELF_DAYS,
  mergeInventoryEntry,
  remainingDays
} from '../src/inventory.js';
import { todayISO } from '../src/storage.js';

const root = process.cwd();

function read(rel) {
  return readFileSync(join(root, rel), 'utf8');
}

test('食材页顶部工具区把小票入口合并进“记进厨房”窗口', () => {
  const source = read('src/views/inventory-view.js');
  const styles = read('styles.css');

  assert.doesNotMatch(source, /inventory-camera-label/);
  assert.doesNotMatch(source, /更多选项/);
  assert.doesNotMatch(source, /inventoryAddMenu/);
  assert.doesNotMatch(source, /inventory-add-menu/);
  assert.doesNotMatch(source, /add-form-container/);
  assert.doesNotMatch(source, /id="camInput"/);
  assert.match(source, /id="inventoryAddBtn"/);
  assert.match(source, /openInventoryAddModal\('manual'\)/);
  assert.match(source, /id="inventoryAddTitle">记进厨房</);
  assert.match(source, /class="inventory-tool-row"/);
  assert.match(source, /class="inventory-tool-btn inventory-add-trigger is-primary"/);
  assert.match(source, />手动记食材<\/button>/);
  assert.match(source, />拍小票识别<\/button>/);
  assert.match(source, /id="inventoryModalText"/);
  assert.match(source, /id="inventoryModalSample"/);
  assert.match(source, /id="inventoryModalFrozen"/);
  assert.match(source, /id="inventoryModalReceiptInput" accept="image\/\*" class="visually-hidden"/);
  assert.doesNotMatch(source, /capture="environment"/);

  assert.match(styles, /\.inventory-tool-row\s*\{[\s\S]*?grid-template-columns: minmax\(0, 1fr\) minmax\(0, 1fr\) minmax\(0, 1fr\);/);
  assert.match(styles, /\.inventory-tool-btn\s*\{[\s\S]*?height: 44px;/);
  assert.match(styles, /\.inventory-add-modal\s*\{/);
  assert.match(styles, /\.inventory-add-tabs\s*\{/);
  assert.match(styles, /\.inventory-receipt-pick-card\s*\{/);
  assert.doesNotMatch(styles, /\.inventory-add-menu\s*\{/);
  assert.doesNotMatch(styles, /\.inventory-advanced-toggle\s*\{/);
});

test('编辑模式表达为剩余有效期，并按今天重新计算剩余天数', () => {
  const source = read('src/views/inventory-view.js');

  assert.match(source, /inv-ie-shelf-label">剩余<\/span>/);
  assert.match(source, /aria-label="剩余有效期天数"/);
  assert.doesNotMatch(source, /aria-label="保质期天数"/);
  assert.match(source, /const remainingInputValue = Math\.max\(0, Math\.round\(remainingDays\(e\)\)\);/);
  assert.match(source, /e\.buyDate = todayISO\(\);[\s\S]*?e\.shelf = n;/);
  assert.match(source, /const userEditedRemaining = inputRemaining !== remainingInputValue;/);
  assert.match(source, /if \(e\.isFrozen && !userEditedRemaining\)/);

  const item = { name: '番茄', qty: 1, unit: '个', buyDate: todayISO(), shelf: 5, stockStatus: 'ok' };
  assert.equal(remainingDays(item), 5);
});

test('冷冻食材默认剩余有效期为 30 天，且不会缩短更长手动天数', () => {
  assert.equal(FROZEN_DEFAULT_SHELF_DAYS, 30);

  const shortFresh = [{
    name: '鸡腿',
    qty: 1,
    unit: '份',
    kind: 'raw',
    buyDate: todayISO(),
    shelf: 3,
    stockStatus: 'ok'
  }];
  mergeInventoryEntry(shortFresh, {
    name: '鸡腿',
    qty: 1,
    unit: '份',
    kind: 'raw',
    buyDate: todayISO(),
    shelf: 3,
    isFrozen: true,
    stockStatus: 'ok'
  }, { save: false });
  assert.equal(shortFresh[0].isFrozen, true);
  assert.equal(remainingDays(shortFresh[0]), FROZEN_DEFAULT_SHELF_DAYS);

  const longFrozen = [{
    name: '牛肉',
    qty: 1,
    unit: '份',
    kind: 'raw',
    buyDate: todayISO(),
    shelf: 60,
    stockStatus: 'ok'
  }];
  mergeInventoryEntry(longFrozen, {
    name: '牛肉',
    qty: 1,
    unit: '份',
    kind: 'raw',
    buyDate: todayISO(),
    shelf: FROZEN_DEFAULT_SHELF_DAYS,
    isFrozen: true,
    stockStatus: 'ok'
  }, { save: false });
  assert.equal(longFrozen[0].isFrozen, true);
  assert.equal(remainingDays(longFrozen[0]), 60);
});
