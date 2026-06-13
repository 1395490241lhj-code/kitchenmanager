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
