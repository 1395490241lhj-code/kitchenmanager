/*
 * 示例厨房的数据完整性：进入失败要整体回滚，退出在缺快照时绝不删业务数据。
 *
 * 这些路径全部由 localStorage 写失败（配额满 / 隐私模式）触发，而 demo-kitchen.js
 * 的 enter / exit 都是纯数据逻辑（不碰 DOM），所以这里用一个可注入失败的假
 * localStorage 直接驱动真实模块，不需要 jsdom。
 */
import test, { beforeEach } from 'node:test';
import assert from 'node:assert/strict';

// 真实模块只在函数体内访问 localStorage，所以先装桩再动态导入。
const store = new Map();
let failWrite = () => false;

globalThis.localStorage = {
  getItem: key => (store.has(key) ? store.get(key) : null),
  setItem: (key, value) => {
    if (failWrite(key, String(value))) {
      const error = new Error('QuotaExceededError');
      error.name = 'QuotaExceededError';
      throw error;
    }
    store.set(key, String(value));
  },
  removeItem: key => { store.delete(key); }
};

const { S } = await import('../src/storage.js');
const { enterDemoKitchen, exitDemoKitchen, isDemoKitchenMode } = await import('../src/views/home/demo-kitchen.js');

const PACK = { recipe_ingredients: {} };

// 快照覆盖的 13 个业务键里，这几个足以证明「真实数据没被动过」。
const BUSINESS_KEYS = [S.keys.inventory, S.keys.plan, S.keys.shopping_items, S.keys.favorite_recipes];
const DEMO_KEYS = [S.keys.demo_mode, S.keys.demo_step, S.keys.demo_snapshot];

const REAL_INVENTORY = JSON.stringify([
  { name: '牛奶', qty: 1, unit: '盒', buyDate: '2026-08-20', kind: 'raw', shelf: 7, stockStatus: 'ok' }
]);
const REAL_PLAN = JSON.stringify([{ date: '2026-08-26', recipe: '我的真实计划' }]);
const REAL_FAVORITES = JSON.stringify(['我收藏的菜']);

function dump(keys) {
  return keys.map(key => [key, store.has(key) ? store.get(key) : null]);
}

function seedRealKitchen() {
  store.clear();
  localStorage.setItem(S.keys.inventory, REAL_INVENTORY);
  localStorage.setItem(S.keys.plan, REAL_PLAN);
  localStorage.setItem(S.keys.favorite_recipes, REAL_FAVORITES);
  // shopping_items 刻意不写：验证「进入前不存在的键，退出后仍不存在」。
}

function silenceConsoleError() {
  const original = console.error;
  console.error = () => {};
  return () => { console.error = original; };
}

beforeEach(() => {
  failWrite = () => false;
  seedRealKitchen();
});

test('snapshot 保存失败 → 不进入示例，业务数据一个字节都没改', () => {
  const before = dump(BUSINESS_KEYS);
  failWrite = key => key === S.keys.demo_snapshot;
  const restore = silenceConsoleError();

  try {
    assert.throws(
      () => enterDemoKitchen(PACK, { onRoute: () => {} }),
      err => err.code === 'DEMO_SNAPSHOT_FAILED'
    );
  } finally {
    restore();
  }

  assert.equal(isDemoKitchenMode(), false);
  for (const key of DEMO_KEYS) assert.equal(store.has(key), false, `${key} 不该被写入`);
  assert.deepEqual(dump(BUSINESS_KEYS), before);
});

test('示例食材写入中途失败 → 原库存恢复、示例状态清干净', () => {
  const before = dump(BUSINESS_KEYS);
  // 示例食材是逐条持久化的：让第 3 次库存写入失败，此时已有 2 条示例食材落地。
  let inventoryWrites = 0;
  failWrite = key => key === S.keys.inventory && ++inventoryWrites === 3;
  const restore = silenceConsoleError();

  try {
    assert.throws(
      () => enterDemoKitchen(PACK, { onRoute: () => {} }),
      err => err.code === 'STORAGE_WRITE_FAILED'
    );
  } finally {
    restore();
  }

  // 回滚用的那次写入必须真的发生过（否则说明失败点没落在循环中间）。
  assert.ok(inventoryWrites >= 3);
  assert.equal(isDemoKitchenMode(), false);
  for (const key of DEMO_KEYS) assert.equal(store.has(key), false, `${key} 应被回滚清除`);
  assert.deepEqual(dump(BUSINESS_KEYS), before);
  assert.equal(JSON.parse(store.get(S.keys.inventory)).length, 1);
});

test('onRoute 抛错也整体回滚，不留半个示例厨房', () => {
  const before = dump(BUSINESS_KEYS);
  const restore = silenceConsoleError();

  try {
    assert.throws(
      () => enterDemoKitchen(PACK, { onRoute: () => { throw new Error('render failed'); } }),
      /render failed/
    );
  } finally {
    restore();
  }

  assert.equal(isDemoKitchenMode(), false);
  for (const key of DEMO_KEYS) assert.equal(store.has(key), false);
  assert.deepEqual(dump(BUSINESS_KEYS), before);
});

test('正常 enter → exit 完整还原进入前的数据', () => {
  const before = dump(BUSINESS_KEYS);

  enterDemoKitchen(PACK, { onRoute: () => {} });
  assert.equal(isDemoKitchenMode(), true);
  // 示例食材确实写进去了（8 样示例 + 1 样真实）。
  assert.equal(JSON.parse(store.get(S.keys.inventory)).length, 9);

  const outcome = exitDemoKitchen({ onRoute: () => {} });

  assert.equal(outcome, 'restored');
  assert.equal(isDemoKitchenMode(), false);
  for (const key of DEMO_KEYS) assert.equal(store.has(key), false);
  assert.deepEqual(dump(BUSINESS_KEYS), before);
  // 进入前不存在的 shopping_items 退出后仍不存在。
  assert.equal(store.has(S.keys.shopping_items), false);
});

test('快照缺失时退出 → 只清示例状态，绝不批量删除业务数据', () => {
  enterDemoKitchen(PACK, { onRoute: () => {} });
  const withDemoItems = dump(BUSINESS_KEYS);
  // 模拟「快照丢了」：历史遗留数据、被清理、或写入时静默失败。
  store.delete(S.keys.demo_snapshot);

  const outcome = exitDemoKitchen({ onRoute: () => {} });

  assert.equal(outcome, 'invalid');
  assert.equal(isDemoKitchenMode(), false);
  for (const key of DEMO_KEYS) assert.equal(store.has(key), false);
  // 数据原样保留：宁可留下示例食材让用户手动删，也不能清空真实库存/计划/收藏。
  assert.deepEqual(dump(BUSINESS_KEYS), withDemoItems);
  assert.ok(JSON.parse(store.get(S.keys.inventory)).some(i => i.name === '牛奶'));
  assert.equal(store.get(S.keys.plan), REAL_PLAN);
  assert.equal(store.get(S.keys.favorite_recipes), REAL_FAVORITES);
});

test('快照损坏时退出同样不删业务数据', () => {
  enterDemoKitchen(PACK, { onRoute: () => {} });
  const withDemoItems = dump(BUSINESS_KEYS);
  store.set(S.keys.demo_snapshot, '{"version":1}'); // 有 JSON、但没有 keys

  const outcome = exitDemoKitchen({ onRoute: () => {} });

  assert.equal(outcome, 'invalid');
  assert.deepEqual(dump(BUSINESS_KEYS), withDemoItems);
});

test('引导入口：进入失败可重试，成功后才收尾 onboarding', async () => {
  const { runDemoKitchenEntry } = await import('../src/onboarding.js');
  const before = dump(BUSINESS_KEYS);
  const button = { disabled: false, textContent: '试用示例厨房' };
  let finished = 0;
  const entry = () => enterDemoKitchen(PACK, { onRoute: () => {} });

  failWrite = key => key === S.keys.demo_snapshot;
  const restore = silenceConsoleError();
  const failed = await runDemoKitchenEntry({ button, onTryDemoKitchen: entry, onEntered: () => { finished += 1; } });
  restore();

  assert.equal(failed, false);
  assert.equal(finished, 0);            // onboarding 没被完成
  assert.equal(button.disabled, false); // 可以重试
  assert.match(button.textContent, /重试/);
  assert.deepEqual(dump(BUSINESS_KEYS), before);

  // 存储恢复后重试成功。
  failWrite = () => false;
  const ok = await runDemoKitchenEntry({ button, onTryDemoKitchen: entry, onEntered: () => { finished += 1; } });

  assert.equal(ok, true);
  assert.equal(finished, 1);
  assert.equal(isDemoKitchenMode(), true);
  // 重试进入的示例仍持有干净快照，退出可完整还原。
  assert.equal(exitDemoKitchen({ onRoute: () => {} }), 'restored');
  assert.deepEqual(dump(BUSINESS_KEYS), before);
});

// ── 部分恢复失败：快照是唯一的干净锚点，任何情况下都不能连它一起丢 ──────────
// 场景：既有库存里已经有「鸡蛋 2 个」，示例厨房会把它 merge 成 8 个。
// 如果回滚时库存也写不回去，绝不能把 demo_snapshot 删掉——否则「鸡蛋 2 个」永远回不来了。

const EGGS_INVENTORY = JSON.stringify([
  { name: '鸡蛋', qty: 2, unit: '个', buyDate: '2026-08-20', kind: 'raw', shelf: 30, stockStatus: 'ok' }
]);

function seedKitchenWithEggs() {
  store.clear();
  localStorage.setItem(S.keys.inventory, EGGS_INVENTORY);
}

function eggQty() {
  return JSON.parse(store.get(S.keys.inventory)).find(i => i.name === '鸡蛋')?.qty;
}

function snapshotInventory() {
  return JSON.parse(store.get(S.keys.demo_snapshot)).keys.inventory.value;
}

test('回滚时库存也写不回去 → 保留干净快照与示例状态，不留「无锚点的污染数据」', () => {
  seedKitchenWithEggs();
  // 第 1 次写入把鸡蛋 merge 成 8 个并落盘；从第 3 次起持续失败，回滚的写回也会失败。
  let writes = 0;
  failWrite = key => key === S.keys.inventory && ++writes >= 3;
  const restore = silenceConsoleError();

  try {
    assert.throws(
      () => enterDemoKitchen(PACK, { onRoute: () => {} }),
      err => err.code === 'STORAGE_WRITE_FAILED'
    );
  } finally {
    restore();
  }

  // 当前库存确实被污染了（鸡蛋从 2 变成 8）。
  assert.equal(eggQty(), 8);
  // 但唯一的恢复锚点还在，而且记录的仍是进入前的「鸡蛋 2 个」。
  assert.equal(store.has(S.keys.demo_snapshot), true);
  assert.equal(snapshotInventory(), EGGS_INVENTORY);
  // 刻意停在示例模式：这样 saveDemoKitchenSnapshot() 会走复用分支，重试不会覆盖快照。
  assert.equal(isDemoKitchenMode(), true);
});

test('恢复不完整后重试：不会用被污染的数据覆盖那份干净快照', () => {
  seedKitchenWithEggs();
  let writes = 0;
  failWrite = key => key === S.keys.inventory && ++writes >= 3;
  const restore = silenceConsoleError();
  try {
    assert.throws(() => enterDemoKitchen(PACK, { onRoute: () => {} }));
    assert.equal(eggQty(), 8);

    // 存储仍然满：重试再失败一次，快照必须原封不动。
    assert.throws(() => enterDemoKitchen(PACK, { onRoute: () => {} }));
    assert.equal(snapshotInventory(), EGGS_INVENTORY, '快照被污染数据覆盖了');
    assert.equal(isDemoKitchenMode(), true);
  } finally {
    restore();
  }
});

test('存储恢复后退出 → 精确还原成原来的「鸡蛋 2 个」，而不是污染后的数量', () => {
  seedKitchenWithEggs();
  let writes = 0;
  failWrite = key => key === S.keys.inventory && ++writes >= 3;
  const restore = silenceConsoleError();
  try {
    assert.throws(() => enterDemoKitchen(PACK, { onRoute: () => {} }));
  } finally {
    restore();
  }
  assert.equal(eggQty(), 8);

  // 用户清理出空间后退出示例。
  failWrite = () => false;
  const outcome = exitDemoKitchen({ onRoute: () => {} });

  assert.equal(outcome, 'restored');
  assert.equal(store.get(S.keys.inventory), EGGS_INVENTORY);
  assert.equal(eggQty(), 2);
  for (const key of DEMO_KEYS) assert.equal(store.has(key), false);
});

test('存储恢复后重试进入 → 复用干净快照，之后退出仍还原「鸡蛋 2 个」', () => {
  seedKitchenWithEggs();
  let writes = 0;
  failWrite = key => key === S.keys.inventory && ++writes >= 3;
  const restore = silenceConsoleError();
  try {
    assert.throws(() => enterDemoKitchen(PACK, { onRoute: () => {} }));
  } finally {
    restore();
  }

  failWrite = () => false;
  enterDemoKitchen(PACK, { onRoute: () => {} }); // 重试成功
  assert.equal(isDemoKitchenMode(), true);
  assert.equal(snapshotInventory(), EGGS_INVENTORY, '重试成功也不能覆盖快照');
  // 重试是先退回基线再重新应用示例，所以是「一次示例」的量：2 + 6 = 8，不是 8 + 6 = 14。
  assert.equal(eggQty(), 8, '重试把示例食材二次累加了');

  assert.equal(exitDemoKitchen({ onRoute: () => {} }), 'restored');
  assert.equal(store.get(S.keys.inventory), EGGS_INVENTORY);
});

test('退出时部分恢复失败 → 保留快照并停在示例模式，随后成功退出才清除快照', () => {
  seedKitchenWithEggs();
  enterDemoKitchen(PACK, { onRoute: () => {} });
  assert.equal(eggQty(), 8);

  // 退出时存储写不进去。
  failWrite = key => key === S.keys.inventory;
  const restore = silenceConsoleError();
  const partial = exitDemoKitchen({ onRoute: () => {} });
  restore();

  assert.equal(partial, 'partial');
  // 绝不允许「恢复失败 + 快照已删」。
  assert.equal(store.has(S.keys.demo_snapshot), true);
  assert.equal(snapshotInventory(), EGGS_INVENTORY);
  assert.equal(isDemoKitchenMode(), true, '恢复失败时不应假装已退出示例');

  // 清理出空间后再退一次。
  failWrite = () => false;
  const done = exitDemoKitchen({ onRoute: () => {} });

  assert.equal(done, 'restored');
  assert.equal(store.get(S.keys.inventory), EGGS_INVENTORY);
  for (const key of DEMO_KEYS) assert.equal(store.has(key), false);
});

test('retry 幂等：污染后重试不会把示例食材二次累加，最终仍精确还原', () => {
  seedKitchenWithEggs();                       // ① 原始「鸡蛋 2 个」
  let writes = 0;
  failWrite = key => key === S.keys.inventory && ++writes >= 3;
  const restore = silenceConsoleError();
  try {
    assert.throws(() => enterDemoKitchen(PACK, { onRoute: () => {} }));
  } finally {
    restore();
  }
  assert.equal(eggQty(), 8);                   // ② 回滚不完整 → 当前是污染值
  assert.equal(isDemoKitchenMode(), true);
  assert.equal(snapshotInventory(), EGGS_INVENTORY);

  failWrite = () => false;                     // ③ 存储恢复后重试
  enterDemoKitchen(PACK, { onRoute: () => {} });

  // ④ 正常一次示例的量：基线 2 + 示例 6 = 8。若直接在污染值上再加一次会是 14。
  assert.equal(eggQty(), 8);
  const inv = JSON.parse(store.get(S.keys.inventory));
  assert.equal(inv.filter(i => i.name === '鸡蛋').length, 1, '不该出现重复批次');
  assert.equal(inv.find(i => i.name === '番茄').qty, 3, '其他示例食材也不能累加');
  assert.equal(snapshotInventory(), EGGS_INVENTORY, '快照必须始终是原始基线');

  // ⑤ 退出精确还原
  assert.equal(exitDemoKitchen({ onRoute: () => {} }), 'restored');
  assert.equal(store.get(S.keys.inventory), EGGS_INVENTORY);
  assert.equal(eggQty(), 2);
});

test('retry 时基线仍恢复不了 → 直接失败并原样保留快照，不写任何示例数据', () => {
  seedKitchenWithEggs();
  let writes = 0;
  failWrite = key => key === S.keys.inventory && ++writes >= 3;
  const restore = silenceConsoleError();
  try {
    assert.throws(() => enterDemoKitchen(PACK, { onRoute: () => {} }));
    const polluted = store.get(S.keys.inventory);

    // 存储仍然满：重试应该停在「恢复基线」这一步，而不是继续叠加示例食材。
    assert.throws(
      () => enterDemoKitchen(PACK, { onRoute: () => {} }),
      err => err.code === 'DEMO_BASELINE_RESTORE_FAILED'
    );
    assert.equal(store.get(S.keys.inventory), polluted, '基线恢复失败后不该再写入示例食材');
    assert.equal(snapshotInventory(), EGGS_INVENTORY);
    assert.equal(isDemoKitchenMode(), true);
  } finally {
    restore();
  }

  // 清理空间后仍能完整回到原始数据。
  failWrite = () => false;
  assert.equal(exitDemoKitchen({ onRoute: () => {} }), 'restored');
  assert.equal(store.get(S.keys.inventory), EGGS_INVENTORY);
});
