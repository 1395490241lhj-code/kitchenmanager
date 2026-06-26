import { test, beforeEach } from 'node:test';
import assert from 'node:assert/strict';

import { installLocalStorageStub, resetLocalStorage } from './helpers/localstorage-stub.mjs';
import { S } from '../src/storage.js';
import { DATA_SCHEMA_VERSION } from '../src/migrations.js';
import {
  BACKUP_APP_ID,
  exportKitchenBackup,
  getKitchenBackupKeyEntries,
  importKitchenBackup,
  markBackupNudgeDismissed,
  markKitchenBackupExported,
  shouldShowBackupNudge,
  validateKitchenBackup
} from '../src/backup.js';

beforeEach(() => {
  installLocalStorageStub();
  resetLocalStorage();
});

function validBackup(keys = {}) {
  return {
    app: BACKUP_APP_ID,
    schemaVersion: DATA_SCHEMA_VERSION,
    exportedAt: '2026-06-12T00:00:00.000Z',
    keys
  };
}

test('exportKitchenBackup 包含 app/schemaVersion/exportedAt/keys', () => {
  S.save(S.keys.inventory, [{ name: '土豆', qty: 2, unit: '个' }]);

  const backup = exportKitchenBackup();
  assert.equal(backup.app, BACKUP_APP_ID);
  assert.equal(backup.schemaVersion, DATA_SCHEMA_VERSION);
  assert.ok(Number.isFinite(Date.parse(backup.exportedAt)));
  assert.equal(typeof backup.keys, 'object');
  assert.deepEqual(backup.keys[S.keys.inventory], [{ name: '土豆', qty: 2, unit: '个' }]);
});

test('exportKitchenBackup 只导出允许的 S.keys，且不包含 apiKey', () => {
  S.save(S.keys.settings, { theme: 'dark', apiKey: 'secret' });
  localStorage.setItem('other_site_key', JSON.stringify({ keep: false }));

  const backup = exportKitchenBackup();
  const allowed = new Set(getKitchenBackupKeyEntries().map(([, key]) => key));
  assert.ok(Object.keys(backup.keys).length > 0);
  assert.deepEqual(Object.keys(backup.keys).filter(key => !allowed.has(key)), []);
  assert.equal(Object.hasOwn(backup.keys, 'other_site_key'), false);
  assert.equal(backup.keys[S.keys.settings].apiKey, undefined);
  assert.equal(backup.keys[S.keys.settings].theme, 'dark');
});

test('shouldShowBackupNudge 空厨房不显示', () => {
  assert.equal(shouldShowBackupNudge({
    inventory: [],
    plan: [],
    shoppingItems: [],
    overlay: null,
    now: 1000
  }), false);
});

test('shouldShowBackupNudge demo 模式不显示', () => {
  assert.equal(shouldShowBackupNudge({
    inventory: [
      { name: '鸡蛋', qty: 1 },
      { name: '番茄', qty: 1 },
      { name: '土豆', qty: 1 },
      { name: '青椒', qty: 1 },
      { name: '豆腐', qty: 1 }
    ],
    isDemoMode: true,
    now: 1000
  }), false);
});

test('shouldShowBackupNudge 库存达到 5 样时显示', () => {
  assert.equal(shouldShowBackupNudge({
    inventory: [
      { name: '鸡蛋', qty: 1 },
      { name: '番茄', qty: 1 },
      { name: '土豆', qty: 1 },
      { name: '青椒', qty: 1 },
      { name: '豆腐', qty: 1 }
    ],
    now: 1000
  }), true);
});

test('shouldShowBackupNudge 今日计划达到 1 道时显示', () => {
  assert.equal(shouldShowBackupNudge({
    plan: [{ id: 'recipe-1', date: '2026-06-25' }],
    now: 1000
  }), true);
});

test('shouldShowBackupNudge 买菜清单达到 3 项或有菜谱补丁时显示', () => {
  assert.equal(shouldShowBackupNudge({
    shoppingItems: [
      { name: '青椒' },
      { name: '牛肉' },
      { name: '面条' }
    ],
    now: 1000
  }), true);
  assert.equal(shouldShowBackupNudge({
    overlay: { version: 1, recipes: { custom: { name: '自定义菜' } }, recipe_ingredients: {}, deletes: {} },
    now: 1000
  }), true);
});

test('markBackupNudgeDismissed 后短期内不再显示', () => {
  const now = 1_800_000_000_000;
  markBackupNudgeDismissed(now);
  assert.equal(localStorage.getItem(S.keys.backup_nudge_dismissed_at), String(now));
  assert.equal(shouldShowBackupNudge({
    inventory: [
      { name: '鸡蛋', qty: 1 },
      { name: '番茄', qty: 1 },
      { name: '土豆', qty: 1 },
      { name: '青椒', qty: 1 },
      { name: '豆腐', qty: 1 }
    ],
    now: now + 6 * 24 * 60 * 60 * 1000
  }), false);
  assert.equal(shouldShowBackupNudge({
    inventory: [
      { name: '鸡蛋', qty: 1 },
      { name: '番茄', qty: 1 },
      { name: '土豆', qty: 1 },
      { name: '青椒', qty: 1 },
      { name: '豆腐', qty: 1 }
    ],
    now: now + 8 * 24 * 60 * 60 * 1000
  }), true);
});

test('markKitchenBackupExported 会记录导出时间并节流提醒', () => {
  const now = 1_800_000_000_000;
  markKitchenBackupExported(now);
  assert.equal(localStorage.getItem(S.keys.backup_last_exported_at), String(now));
  assert.equal(shouldShowBackupNudge({
    plan: [{ id: 'recipe-1', date: '2026-06-25' }],
    now: now + 2 * 24 * 60 * 60 * 1000
  }), false);
});

test('validateKitchenBackup 接受合法备份', () => {
  const backup = validBackup({ [S.keys.inventory]: [] });
  const out = validateKitchenBackup(JSON.stringify(backup));
  assert.equal(out.app, BACKUP_APP_ID);
  assert.deepEqual(out.keys[S.keys.inventory], []);
});

test('validateKitchenBackup 拒绝非 JSON / 非对象', () => {
  assert.throws(() => validateKitchenBackup('{ bad json'), /无法读取/);
  assert.throws(() => validateKitchenBackup(null), /无法读取/);
  assert.throws(() => validateKitchenBackup([]), /无法读取/);
});

test('validateKitchenBackup 拒绝 app 不匹配', () => {
  assert.throws(
    () => validateKitchenBackup({ app: 'other-app', schemaVersion: DATA_SCHEMA_VERSION, keys: {} }),
    /不是 Kitchen Manager/
  );
});

test('validateKitchenBackup 拒绝不支持的 schemaVersion', () => {
  assert.throws(
    () => validateKitchenBackup({
      app: BACKUP_APP_ID,
      schemaVersion: DATA_SCHEMA_VERSION + 1,
      keys: { [S.keys.inventory]: [] }
    }),
    /只支持/
  );
});

test('validateKitchenBackup 拒绝 keys 缺失', () => {
  assert.throws(
    () => validateKitchenBackup({ app: BACKUP_APP_ID, schemaVersion: DATA_SCHEMA_VERSION }),
    /缺少厨房数据/
  );
});

test('importKitchenBackup 只写允许 key', () => {
  importKitchenBackup(validBackup({
    [S.keys.inventory]: [{ name: '番茄', qty: 3, unit: '个' }],
    zzz_unrelated: { nope: true }
  }));

  assert.deepEqual(S.load(S.keys.inventory, []), [{ name: '番茄', qty: 3, unit: '个' }]);
  assert.equal(localStorage.getItem('zzz_unrelated'), null);
  assert.equal(S.load(S.keys.schema_version, 0), DATA_SCHEMA_VERSION);
});

test('importKitchenBackup 导入设置时不写入备份里的 apiKey，并保留当前 apiKey', () => {
  S.save(S.keys.settings, { apiKey: 'current-key', theme: 'light' });

  importKitchenBackup(validBackup({
    [S.keys.settings]: { apiKey: 'backup-key', theme: 'dark' }
  }));

  assert.deepEqual(S.load(S.keys.settings, {}), { theme: 'dark', apiKey: 'current-key' });
});

test('importKitchenBackup 校验失败时不破坏现有 localStorage', () => {
  S.save(S.keys.inventory, [{ name: '旧土豆', qty: 1 }]);

  assert.throws(
    () => importKitchenBackup({ app: 'wrong', schemaVersion: DATA_SCHEMA_VERSION, keys: { [S.keys.inventory]: [] } }),
    /不是 Kitchen Manager/
  );
  assert.deepEqual(S.load(S.keys.inventory, []), [{ name: '旧土豆', qty: 1 }]);
});

test('importKitchenBackup 写入中途失败会回滚，不留下半导入数据', () => {
  S.save(S.keys.inventory, [{ name: '旧土豆', qty: 1 }]);
  const originalSetItem = localStorage.setItem;
  localStorage.setItem = function setItemWithFailure(key, value) {
    if (key === S.keys.plan) throw new Error('quota');
    return originalSetItem.call(this, key, value);
  };

  try {
    assert.throws(
      () => importKitchenBackup(validBackup({
        [S.keys.inventory]: [{ name: '新番茄', qty: 3 }],
        [S.keys.plan]: [{ id: 'r1', servings: 1, date: '2026-06-12' }]
      })),
      /没有被覆盖/
    );
  } finally {
    localStorage.setItem = originalSetItem;
  }

  assert.deepEqual(S.load(S.keys.inventory, []), [{ name: '旧土豆', qty: 1 }]);
  assert.deepEqual(S.load(S.keys.plan, []), []);
});
