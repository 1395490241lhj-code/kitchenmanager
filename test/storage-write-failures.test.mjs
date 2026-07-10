// test/storage-write-failures.test.mjs
// S.save() 返回 boolean，但大量调用方从不检查——localStorage 写入失败
// （QuotaExceededError / 隐私模式限制等）时 UI 照样显示"已保存"，刷新后数据消失。
// 本文件覆盖第一阶段接入的关键路径：mustSave 本身 + inventory/plan/shopping_items/
// settings/overlay 的保存函数在写入失败时会抛错而不是静默假装成功，以及 backup
// import 的整体回滚。用真实的 localStorage.setItem 抛 DOMException 来模拟配额超限。
import test, { afterEach, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

import { installLocalStorageStub, resetLocalStorage } from './helpers/localstorage-stub.mjs';
import { S, STORAGE_WRITE_FAILED_MESSAGE, mustSave } from '../src/storage.js';
import { saveInventory } from '../src/inventory.js';
import { addShoppingItem, loadShoppingItems, saveShoppingItems } from '../src/shopping.js';
import { addRecipeToPlan } from '../src/recommendations.js';
import { addRecipeToPlanWithMissingCheck } from '../src/components/plan-missing-check.js';
import { loadOverlay, saveOverlay } from '../src/backup.js';
import { createUserRecipe } from '../src/components/recipe-create-modal.js';

const root = process.cwd();
function read(rel) {
  return readFileSync(join(root, rel), 'utf8');
}

beforeEach(() => {
  installLocalStorageStub();
  resetLocalStorage();
});

// 真实的 QuotaExceededError 模拟：让 localStorage.setItem 对指定 key（默认全部）抛错。
function makeQuotaExceeded() {
  return new DOMException('Quota exceeded', 'QuotaExceededError');
}

function withBrokenSetItem(matchKey, fn) {
  const original = localStorage.setItem;
  localStorage.setItem = function brokenSetItem(key, value) {
    if (!matchKey || key === matchKey) throw makeQuotaExceeded();
    return original.call(this, key, value);
  };
  try {
    return fn();
  } finally {
    localStorage.setItem = original;
  }
}

// ── 一：S.save / mustSave 本身 ──────────────────────────────────────────────

test('S.save：localStorage.setItem 抛 QuotaExceededError 时返回 false（不抛出）', () => {
  withBrokenSetItem(null, () => {
    assert.equal(S.save(S.keys.inventory, [{ name: '苹果' }]), false);
  });
});

test('mustSave：写入失败时抛出 Error，code 为 STORAGE_WRITE_FAILED', () => {
  withBrokenSetItem(null, () => {
    assert.throws(
      () => mustSave(S.keys.inventory, [{ name: '苹果' }]),
      err => err instanceof Error && err.code === 'STORAGE_WRITE_FAILED' && err.message === STORAGE_WRITE_FAILED_MESSAGE
    );
  });
});

test('mustSave：写入成功时返回 true，不抛出', () => {
  assert.equal(mustSave(S.keys.inventory, [{ name: '苹果' }]), true);
  assert.deepEqual(S.load(S.keys.inventory, []), [{ name: '苹果' }]);
});

// ── 二：inventory 保存 ───────────────────────────────────────────────────────

test('saveInventory：写入失败时抛出 STORAGE_WRITE_FAILED，不静默返回', () => {
  withBrokenSetItem(S.keys.inventory, () => {
    assert.throws(
      () => saveInventory([{ name: '苹果', qty: 1 }]),
      err => err.code === 'STORAGE_WRITE_FAILED'
    );
  });
  // 失败没有污染 localStorage：读回来仍是空。
  assert.deepEqual(S.load(S.keys.inventory, []), []);
});

test('inventory-view.js：批量记食材成功后才 showToast 成功提示，失败会走统一提示且不继续', () => {
  const source = read('src/views/inventory-view.js');
  const fn = source.slice(source.indexOf('const addTextInventoryItems ='), source.indexOf('// chips：'));
  assert.match(fn, /try\s*\{[\s\S]*mergeInventoryEntry/, '批量入库应包在 try 里');
  assert.match(fn, /catch\s*\(err\)[\s\S]*STORAGE_WRITE_FAILED[\s\S]*showToast\(STORAGE_WRITE_FAILED_MESSAGE/, '失败要走统一提示');
  // 成功 toast 必须在 try 块之后（失败时 catch 里 return，不会执行到这里）。
  const catchIdx = fn.indexOf('catch (err)');
  const successToastIdx = fn.indexOf("showToast(`已加入");
  assert.ok(catchIdx > 0 && successToastIdx > catchIdx, '成功提示应在失败处理之后，且失败时不会被执行到');
});

// ── 二.5：settings 保存 ──────────────────────────────────────────────────────

test('settings-view.js：BYOK 设置保存失败走统一提示，不显示"已保存，刷新后生效"', () => {
  const source = read('src/views/settings-view.js');
  const fn = source.slice(source.indexOf("div.querySelector('#saveSet').onclick"), source.indexOf("// 菜谱补丁 — 从原菜谱页迁来的"));
  assert.match(fn, /try\s*\{\s*mustSave\(S\.keys\.settings, newS\);/);
  assert.match(fn, /catch\s*\(err\)[\s\S]*STORAGE_WRITE_FAILED_MESSAGE[\s\S]*showToast\(STORAGE_WRITE_FAILED_MESSAGE/);
  const catchIdx = fn.indexOf('catch (err)');
  const successIdx = fn.indexOf('已保存，刷新后生效');
  assert.ok(catchIdx > 0 && successIdx > catchIdx, '成功提示必须在失败处理之后（失败时 return，不会执行到）');
});

// ── 三：plan 保存 ────────────────────────────────────────────────────────────

test('addRecipeToPlan：写入失败时抛出 STORAGE_WRITE_FAILED，plan 不落地', () => {
  withBrokenSetItem(S.keys.plan, () => {
    assert.throws(
      () => addRecipeToPlan('tomato-egg', null),
      err => err.code === 'STORAGE_WRITE_FAILED'
    );
  });
  assert.deepEqual(S.load(S.keys.plan, []), []);
});

test('addRecipeToPlanWithMissingCheck：plan 写入失败时 added=false，不当作成功处理，也不抛出给调用方', async () => {
  const pack = { recipes: [{ id: 'tomato-egg', name: '番茄炒蛋', method: '炒熟即可' }], recipe_ingredients: { 'tomato-egg': [] } };
  let confirmCalled = false;
  const result = await withBrokenSetItem(S.keys.plan, () => addRecipeToPlanWithMissingCheck('tomato-egg', pack, [], {
    toast: false, // Node 环境下 showToast 本身是 no-op；这里关掉只是让意图更清楚
    confirmMissing: () => { confirmCalled = true; return true; }
  }));

  assert.equal(result.added, false);
  assert.equal(confirmCalled, false); // 存储失败应直接短路，不应该继续走到缺料确认弹窗
  assert.deepEqual(S.load(S.keys.plan, []), []);
});

test('plan-missing-check.js：存储写入失败走统一提示，不显示"已加入"成功提示', () => {
  const source = read('src/components/plan-missing-check.js');
  const fn = source.slice(source.indexOf('export async function addRecipeToPlanWithMissingCheck'), source.indexOf('function normalizePlanPack'));
  assert.match(fn, /catch\s*\(err\)[\s\S]*STORAGE_WRITE_FAILED[\s\S]*showToast\(STORAGE_WRITE_FAILED_MESSAGE/);
  const catchReturnIdx = fn.indexOf("return { added: false");
  const firstSuccessToastIdx = fn.indexOf('已加入');
  assert.ok(catchReturnIdx > 0 && catchReturnIdx < firstSuccessToastIdx, '存储失败必须在任何"已加入"文案之前就 return');
});

// ── 四：shopping_items 保存 ──────────────────────────────────────────────────

test('saveShoppingItems：写入失败时抛出 STORAGE_WRITE_FAILED', () => {
  withBrokenSetItem(S.keys.shopping_items, () => {
    assert.throws(
      () => saveShoppingItems([{ name: '土豆', qty: 1 }]),
      err => err.code === 'STORAGE_WRITE_FAILED'
    );
  });
});

test('addShoppingItem：写入失败时抛出，购物清单不会假装已加入', () => {
  withBrokenSetItem(S.keys.shopping_items, () => {
    assert.throws(
      () => addShoppingItem('土豆', '', '', '手动', ''),
      err => err.code === 'STORAGE_WRITE_FAILED'
    );
  });
  assert.deepEqual(loadShoppingItems(), []);
});

test('shopping-view.js：快速加入失败走统一提示，不显示"已加入买菜清单"', () => {
  const source = read('src/views/shopping-view.js');
  const fn = source.slice(source.indexOf('const addQuickItem ='), source.indexOf("quickAdd.querySelector('#shoppingQuickAddBtn')"));
  assert.match(fn, /try\s*\{[\s\S]*addShoppingItem\(/);
  assert.match(fn, /catch\s*\(err\)[\s\S]*STORAGE_WRITE_FAILED[\s\S]*showToast\(STORAGE_WRITE_FAILED_MESSAGE/);
  const catchIdx = fn.indexOf('catch (err)');
  const successToastIdx = fn.indexOf("showToast('已加入买菜清单'");
  assert.ok(catchIdx > 0 && successToastIdx > catchIdx);
});

// ── 五：overlay / 用户菜谱保存 ────────────────────────────────────────────────

test('saveOverlay：写入失败时抛出 STORAGE_WRITE_FAILED，overlay 不落地', () => {
  withBrokenSetItem(S.keys.overlay, () => {
    assert.throws(
      () => saveOverlay({ version: 1, recipes: { r1: { name: '新菜' } }, recipe_ingredients: {}, deletes: {} }),
      err => err.code === 'STORAGE_WRITE_FAILED'
    );
  });
  assert.deepEqual(loadOverlay(), { version: 1, recipes: {}, recipe_ingredients: {}, deletes: {} });
});

test('createUserRecipe：写入失败时抛出，不返回新 id，也不留下半条菜谱', () => {
  const base = { recipes: [] };
  withBrokenSetItem(S.keys.overlay, () => {
    assert.throws(
      () => createUserRecipe(base, { name: '新自定义菜', ingredients: [{ item: '盐' }], method: '炒一下' }),
      err => err.code === 'STORAGE_WRITE_FAILED'
    );
  });
  assert.deepEqual(loadOverlay().recipes, {});
});

test('recipe-editor-view.js / recipe-create-modal.js：菜谱保存失败走统一提示，不显示"已保存菜谱"', () => {
  const editor = read('src/views/recipe-editor-view.js');
  const editorFn = editor.slice(editor.indexOf('overlay.recipe_ingredients[realId] = arr;'), editor.indexOf("wrap.querySelector('#hideBtn')"));
  assert.match(editorFn, /try\s*\{\s*saveOverlay\(overlay\);/);
  assert.match(editorFn, /catch\s*\(err\)[\s\S]*showToast\(STORAGE_WRITE_FAILED_MESSAGE/);
  const editorCatchIdx = editorFn.indexOf('catch (err)');
  const editorSuccessToastIdx = editorFn.indexOf('已保存菜谱');
  assert.ok(editorCatchIdx > 0 && editorSuccessToastIdx > editorCatchIdx);

  const createModal = read('src/components/recipe-create-modal.js');
  assert.match(createModal, /err && err\.code === 'STORAGE_WRITE_FAILED'/);
  assert.match(createModal, /showToast\(STORAGE_WRITE_FAILED_MESSAGE, \{ tone: 'error' \}\)/);
});

// ── 六：backup import 最终提交（多 key，任一失败必须整体回滚）────────────────

test('importKitchenBackup：真实 DOMException 触发写入失败时整体回滚，不留半导入数据', async () => {
  const { importKitchenBackup, validateKitchenBackup, BACKUP_APP_ID } = await import('../src/backup.js');
  const { DATA_SCHEMA_VERSION } = await import('../src/migrations.js');

  S.save(S.keys.inventory, [{ name: '旧土豆', qty: 1 }]);

  const backup = validateKitchenBackup({
    app: BACKUP_APP_ID,
    schemaVersion: DATA_SCHEMA_VERSION,
    keys: {
      [S.keys.inventory]: [{ name: '新番茄', qty: 3 }],
      [S.keys.plan]: [{ id: 'r1', servings: 1, date: '2026-06-12' }]
    }
  });

  withBrokenSetItem(S.keys.plan, () => {
    assert.throws(() => importKitchenBackup(backup), /没有被覆盖/);
  });

  // plan 这个 key 失败了 → inventory 这个已经写过的 key 也必须回滚，不留半导入状态。
  assert.deepEqual(S.load(S.keys.inventory, []), [{ name: '旧土豆', qty: 1 }]);
  assert.deepEqual(S.load(S.keys.plan, []), []);
});

// ── 七：正常写入路径不受影响 ──────────────────────────────────────────────────

test('正常写入路径不受影响：inventory/shopping/plan/overlay 在存储正常时行为不变', () => {
  assert.equal(saveInventory([{ name: '苹果', qty: 1 }]), true);
  assert.deepEqual(S.load(S.keys.inventory, []), [{ name: '苹果', qty: 1 }]);

  assert.doesNotThrow(() => addShoppingItem('土豆', '', '', '手动', ''));
  assert.equal(loadShoppingItems().length, 1);

  assert.equal(addRecipeToPlan('tomato-egg', null), true);
  assert.equal(S.load(S.keys.plan, []).length, 1);

  assert.doesNotThrow(() => saveOverlay({ version: 1, recipes: {}, recipe_ingredients: {}, deletes: {} }));
});
