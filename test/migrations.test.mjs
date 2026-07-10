// test/migrations.test.mjs
// localStorage 数据迁移回归。用内存版 localStorage stub，零网络/零 DOM/不读真实 data JSON。
// 只锁稳定不变量（版本写入 / 补 id / 归一形态 / 幂等 / 不删无关 key / 合法 JSON），
// 不锁内部实现细节（具体字段集 / 默认单位 / 旧裸键名等）。
import { test, beforeEach } from 'node:test';
import assert from 'node:assert/strict';

import { installLocalStorageStub, resetLocalStorage } from './helpers/localstorage-stub.mjs';
import { S } from '../src/storage.js';
import {
  DATA_SCHEMA_VERSION,
  detectCurrentSchemaVersion,
  getStoredSchemaVersion,
  setStoredSchemaVersion,
  runLocalStorageMigrations,
  normalizeBackupForRestore
} from '../src/migrations.js';

beforeEach(() => {
  installLocalStorageStub();
  resetLocalStorage();
});

// ── 1) detectCurrentSchemaVersion ──
test('detectCurrentSchemaVersion 空存储返回初始版本 0', () => {
  assert.equal(detectCurrentSchemaVersion(), 0);
});

test('detectCurrentSchemaVersion 能识别已写入的版本', () => {
  setStoredSchemaVersion(2);
  assert.equal(detectCurrentSchemaVersion(), 2);
  assert.equal(getStoredSchemaVersion(), 2);
});

test('detectCurrentSchemaVersion 对异常 schema_version 不崩溃、回退为 0', () => {
  // 直接写入非 JSON 垃圾值，S.load 解析失败应兜底为默认
  globalThis.localStorage.setItem(S.keys.schema_version, 'not-a-number');
  assert.doesNotThrow(() => detectCurrentSchemaVersion());
  assert.equal(detectCurrentSchemaVersion(), 0);
});

// ── 2) runLocalStorageMigrations ──
test('runLocalStorageMigrations 从旧形态迁移到当前版本并写入 schema_version', () => {
  // 旧形态：购物项缺 id；计划项含多余字段且 servings 为字符串
  S.save(S.keys.shopping_items, [{ name: '苹果', qty: 1, unit: '个' }]);
  S.save(S.keys.plan, [{ id: 'r1', servings: '2', date: '2026-06-01', extra: 'x' }]);
  S.save(S.keys.favorite_recipes, ['fav1']);
  globalThis.localStorage.setItem('zzz_unrelated', 'keepme'); // 无关 key

  const res = runLocalStorageMigrations();
  assert.equal(res.fromVersion, 0);
  assert.equal(res.toVersion, DATA_SCHEMA_VERSION);
  assert.equal(res.changed, true);

  // schema_version 写到当前版本
  assert.equal(getStoredSchemaVersion(), DATA_SCHEMA_VERSION);

  // 购物项被补 id
  const shop = S.load(S.keys.shopping_items, []);
  assert.equal(shop.length, 1);
  assert.equal(shop[0].name, '苹果');
  assert.equal(typeof shop[0].id, 'string');
  assert.ok(shop[0].id.length > 0);

  // 计划项归一 id/servings/date（servings 转数字），但保留其余原有字段（如 extra）。
  const plan = S.load(S.keys.plan, []);
  assert.equal(plan.length, 1);
  assert.equal(plan[0].servings, 2);
  assert.equal(plan[0].id, 'r1');
  assert.equal(plan[0].date, '2026-06-01');
  assert.equal(plan[0].extra, 'x');

  // 无关 key 不被删除；已有数据保留
  assert.equal(globalThis.localStorage.getItem('zzz_unrelated'), 'keepme');
  assert.deepEqual(S.load(S.keys.favorite_recipes, []), ['fav1']);

  // 迁移结果是合法 JSON（能被 S.load 解析成对象/数组）
  assert.ok(Array.isArray(shop) && Array.isArray(plan));
});

// ── v4 plan migration：保留原对象字段，只归一 id/servings/date ──
test('v4 plan migration：已完成计划项保留 isCooked / cookedAt', () => {
  S.save(S.keys.plan, [{
    id: 'r1',
    servings: 2,
    date: '2026-07-09',
    isCooked: true,
    cookedAt: '2026-07-09T18:00:00.000Z'
  }]);

  runLocalStorageMigrations();

  const plan = S.load(S.keys.plan, []);
  assert.equal(plan.length, 1);
  assert.equal(plan[0].id, 'r1');
  assert.equal(plan[0].servings, 2);
  assert.equal(plan[0].date, '2026-07-09');
  assert.equal(plan[0].isCooked, true);
  assert.equal(plan[0].cookedAt, '2026-07-09T18:00:00.000Z');
});

test('v4 plan migration：即兴烹饪计划项保留 name', () => {
  S.save(S.keys.plan, [{
    id: 'adhoc-123',
    name: '临时煎蛋',
    servings: 1,
    date: '2026-07-09'
  }]);

  runLocalStorageMigrations();

  const plan = S.load(S.keys.plan, []);
  assert.equal(plan.length, 1);
  assert.equal(plan[0].id, 'adhoc-123');
  assert.equal(plan[0].name, '临时煎蛋');
  assert.equal(plan[0].servings, 1);
  assert.equal(plan[0].date, '2026-07-09');
});

test('v4 plan migration：未知扩展字段保留（source / note）', () => {
  S.save(S.keys.plan, [{
    id: 'r2',
    servings: 1,
    date: '2026-07-09',
    source: 'weekly-menu',
    note: 'test'
  }]);

  runLocalStorageMigrations();

  const plan = S.load(S.keys.plan, []);
  assert.equal(plan.length, 1);
  assert.equal(plan[0].source, 'weekly-menu');
  assert.equal(plan[0].note, 'test');
});

test('v4 plan migration：id / servings / date 仍然被正常归一化', () => {
  S.save(S.keys.plan, [
    { id: 'r3', servings: '3', isCooked: false }, // servings 字符串需转数字；date 缺失需补今天
    { id: 'r4', servings: 0, date: '2026-07-01' }, // servings 非正数需回退为 1
    'not-an-object' // 非对象项应被丢弃
  ]);

  const res = runLocalStorageMigrations();
  assert.equal(res.changed, true);

  const plan = S.load(S.keys.plan, []);
  assert.equal(plan.length, 2);
  assert.equal(plan[0].servings, 3);
  assert.match(plan[0].date, /^\d{4}-\d{2}-\d{2}$/);
  assert.equal(plan[0].isCooked, false);
  assert.equal(plan[1].servings, 1);
  assert.equal(plan[1].date, '2026-07-01');
});

// ── v2 复查：inventory / shopping migration 同样不应误删未知字段 ──
test('v2 inventory migration：保留 gear / opened / outOfStockAt 等未来字段', () => {
  S.save(S.keys.inventory, [{
    id: 'i1',
    name: '苹果',
    qty: 3,
    unit: '个',
    gear: 2,
    unitType: 'GEAR',
    opened: true,
    outOfStockAt: '2026-07-01T00:00:00.000Z'
  }]);

  runLocalStorageMigrations();

  const inv = S.load(S.keys.inventory, []);
  assert.equal(inv.length, 1);
  assert.equal(inv[0].name, '苹果');
  assert.equal(inv[0].gear, 2);
  assert.equal(inv[0].unitType, 'GEAR');
  assert.equal(inv[0].opened, true);
  assert.equal(inv[0].outOfStockAt, '2026-07-01T00:00:00.000Z');
});

test('v2 shopping migration：保留 completedAt / remark 等字段', () => {
  S.save(S.keys.shopping_items, [{
    id: 's1',
    name: '土豆',
    qty: 2,
    unit: '个',
    done: true,
    stockedIn: true,
    completedAt: '2026-07-09T12:00:00.000Z',
    remark: '菜谱缺货'
  }]);

  runLocalStorageMigrations();

  const shop = S.load(S.keys.shopping_items, []);
  assert.equal(shop.length, 1);
  assert.equal(shop[0].name, '土豆');
  assert.equal(shop[0].completedAt, '2026-07-09T12:00:00.000Z');
  assert.equal(shop[0].remark, '菜谱缺货');
});

test('runLocalStorageMigrations 重复运行幂等', () => {
  S.save(S.keys.shopping_items, [{ name: '苹果', qty: 1, unit: '个' }]);

  const first = runLocalStorageMigrations();
  assert.equal(first.toVersion, DATA_SCHEMA_VERSION);
  const idAfterFirst = S.load(S.keys.shopping_items, [])[0].id;

  const second = runLocalStorageMigrations();
  assert.equal(second.fromVersion, DATA_SCHEMA_VERSION);
  assert.equal(second.changed, false); // 已是当前版本 → 不再变更
  assert.equal(S.load(S.keys.shopping_items, [])[0].id, idAfterFirst); // id 稳定不变
  assert.equal(getStoredSchemaVersion(), DATA_SCHEMA_VERSION);
});

test('runLocalStorageMigrations 对超前版本抛错（不静默降级）', () => {
  setStoredSchemaVersion(DATA_SCHEMA_VERSION + 50);
  assert.throws(() => runLocalStorageMigrations());
});

// ── 3) normalizeBackupForRestore（纯函数，不依赖 localStorage）──
test('normalizeBackupForRestore 非法 payload 抛错', () => {
  assert.throws(() => normalizeBackupForRestore(null));
  assert.throws(() => normalizeBackupForRestore({}));
  assert.throws(() => normalizeBackupForRestore({ type: 'something-else' }));
});

test('normalizeBackupForRestore 旧 inventory-only 文件包装为标准备份', () => {
  const out = normalizeBackupForRestore({ type: 'kitchen-inventory', inventory: [{ name: '土豆' }] });
  assert.equal(out.type, 'kitchen-backup');
  assert.equal(out.schemaVersion, DATA_SCHEMA_VERSION);
  assert.equal(out.data.schemaVersion, DATA_SCHEMA_VERSION);
  assert.equal(out.data.inventory.length, 1);
});

test('normalizeBackupForRestore 空/缺字段备份补安全默认结构', () => {
  const out = normalizeBackupForRestore({ type: 'kitchen-backup', data: {} });
  assert.equal(out.schemaVersion, DATA_SCHEMA_VERSION);
  assert.equal(out.data.schemaVersion, DATA_SCHEMA_VERSION);
  assert.ok(Array.isArray(out.data.plan));
  assert.ok(Array.isArray(out.data.shopping_items));
  assert.ok(Array.isArray(out.data.inventory));
});

test('normalizeBackupForRestore 异常字段类型能兜底为安全结构', () => {
  const out = normalizeBackupForRestore({
    type: 'kitchen-backup',
    data: { shopping_items: 'not-an-array', plan: 5, inventory: null }
  });
  assert.ok(Array.isArray(out.data.shopping_items));
  assert.ok(Array.isArray(out.data.plan));
  assert.ok(Array.isArray(out.data.inventory));
});

test('normalizeBackupForRestore 清理空字符串 apiKey（真实行为）', () => {
  const out = normalizeBackupForRestore({ type: 'kitchen-backup', data: { settings: { apiKey: '' } } });
  // 当前实现仅删除空字符串 apiKey；不对非空 apiKey 做剥离（导出侧 buildKitchenBackup 负责）。
  assert.equal(out.data.settings.apiKey, undefined);
});

test('normalizeBackupForRestore 超前版本备份抛错', () => {
  assert.throws(() => normalizeBackupForRestore({
    type: 'kitchen-backup',
    schemaVersion: DATA_SCHEMA_VERSION + 50,
    data: {}
  }));
});
