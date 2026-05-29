import { S } from './storage.js?v=168';

export const APP_VERSION = '151';
export const DATA_SCHEMA_VERSION = 4;


// ─────────────────────────────────────────────────────────────────────────────
// Migration-internal helpers (inlined to avoid ESM circular/timing issues)
// ─────────────────────────────────────────────────────────────────────────────

const MIG_DRY_GOODS = new Set(['木耳', '黄花菜', '海带', '紫菜', '花生', '香菇', '竹荪']);
const MIG_DRY_UNIT = { '木耳': '包', '黄花菜': '包', '海带': '包', '紫菜': '包', '花生': '袋', '香菇': '包', '竹荪': '包' };
const MIG_DRY_PREP = { '木耳': '提前泡发', '黄花菜': '提前泡发', '海带': '泡发/冲洗', '紫菜': '直接用', '花生': '可炖煮', '香菇': '提前泡发', '竹荪': '提前泡发' };

const MIG_ALIASES = {
  '五花肉': ['五花猪肉', '猪五花', '三线肉'], '瘦肉': ['猪瘦肉', '里脊', '里脊肉', '猪里脊'],
  '猪肉': ['肉', '猪肉片', '猪肉丝', '肉丝', '肉片'], '鸡蛋': ['蛋', '鸡子'],
  '牛奶': ['奶', '鲜奶'], '土豆': ['马铃薯', '洋芋'], '番茄': ['西红柿', '洋柿子'],
  '姜': ['老姜', '生姜', '姜片'], '蒜': ['大蒜', '蒜瓣', '独蒜', '蒜头'],
  '葱': ['大葱', '小葱', '香葱', '葱白', '葱花'],
};
const MIG_ALIAS_REVERSE = (() => {
  const map = {};
  for (const [canonical, aliases] of Object.entries(MIG_ALIASES)) {
    for (const alias of aliases) map[alias] = canonical;
  }
  return map;
})();

function migGenId() {
  return 'u-' + Math.random().toString(36).slice(2, 8) + '-' + Date.now().toString(36).slice(-4);
}

function migGetCanonicalName(name) {
  if (!name) return '';
  const n = String(name).trim();
  if (!n) return '';
  if (MIG_ALIAS_REVERSE[n]) return MIG_ALIAS_REVERSE[n];
  return n;
}

function migIsDryGood(name) {
  return MIG_DRY_GOODS.has(migGetCanonicalName(name));
}

function migGuessShelfDays(name, unit) {
  if (migIsDryGood(name)) return 365;
  const n = String(name || '');
  const vegKeywords = ['菜', '叶', '苗', '芹', '葱', '椒', '瓜', '番茄', '西红柿', '豆腐', '豆角', '蘑', '菇'];
  if (vegKeywords.some(w => n.includes(w))) return 5;
  if (unit === 'ml') return 30;
  return 7;
}

function migGuessUnit(name) {
  const n = migGetCanonicalName(name);
  if (migIsDryGood(n)) return MIG_DRY_UNIT[n] || '包';
  if (['鸡蛋', '番茄', '西红柿', '土豆', '洋葱', '青椒', '茄子'].some(w => n.includes(w))) return '个';
  if (['豆腐', '酸奶'].some(w => n.includes(w))) return '盒';
  if (['酱油', '生抽', '老抽', '醋', '料酒', '油', '牛奶'].some(w => n.includes(w))) return '瓶';
  if (['葱', '香菜', '芹菜', '韭菜'].some(w => n.includes(w))) return '把';
  return '份';
}

function migTodayISO() {
  return new Date().toISOString().slice(0, 10);
}

const MIG_VALID_STOCK_STATUS = new Set(['ok', 'low', 'empty', 'unknown']);

function migNormalizeInventoryItem(item) {
  if (!item || typeof item !== 'object') return null;
  const rawName = String(item.name || '').trim();
  if (!rawName) return null;
  const name = migGetCanonicalName(rawName);
  if (!name) return null;

  const isDry = migIsDryGood(name);
  const kind = isDry ? 'dry' : (['raw', 'dry'].includes(item.kind) ? item.kind : 'raw');
  const rawQty = Number(item.qty);
  const qty = Number.isFinite(rawQty) && rawQty >= 0 ? rawQty : 0;
  const unit = isDry
    ? (MIG_DRY_UNIT[name] || item.unit || '包')
    : (item.unit || migGuessUnit(name));
  const stockStatus = MIG_VALID_STOCK_STATUS.has(item.stockStatus) ? item.stockStatus : 'ok';
  const rawShelf = Number(item.shelf);
  const shelf = isDry ? 365 : (Number.isFinite(rawShelf) && rawShelf > 0 ? rawShelf : migGuessShelfDays(name, unit));
  const buyDate = /^\d{4}-\d{2}-\d{2}$/.test(String(item.buyDate || '')) ? item.buyDate : migTodayISO();

  const result = {
    id: item.id || migGenId(),
    name,
    qty,
    unit,
    buyDate,
    kind,
    shelf,
    stockStatus,
    isFrozen: isDry ? false : !!item.isFrozen,
  };

  if (isDry) {
    result.dryPrep = item.dryPrep || MIG_DRY_PREP[name] || '按需处理';
    result.isFrozen = false;
    result.shelf = 365;
  }

  return result;
}

function migNormalizeShoppingItem(item) {
  if (!item || typeof item !== 'object') return null;
  const rawName = String(item.name || '').trim();
  if (!rawName) return null;
  const name = migGetCanonicalName(rawName);
  if (!name) return null;

  // Fix garbled source text (e.g. '鎵嬪姩' is corrupted UTF-8 for '手动')
  const rawSource = String(item.source || '').trim();
  const source = (!rawSource || rawSource === '鎵嬪姩' || rawSource.length > 30) ? '手动' : rawSource;

  return {
    id: item.id || migGenId(),
    name,
    qty: item.qty ?? '',
    unit: item.unit || '',
    source,
    done: !!item.done,
    stockedIn: !!item.stockedIn,
    stockedInAt: item.stockedInAt || null,
  };
}

function migNormalizeSettings(settings, getLocalStorageItem) {
  if (!settings || typeof settings !== 'object') settings = {};
  const result = { ...settings };

  // Migrate old km_include_seasoning bare key (only during localStorage migration)
  if (result.includeSeasoningsInShopping === undefined && typeof getLocalStorageItem === 'function') {
    const oldVal = getLocalStorageItem('km_include_seasoning');
    if (oldVal === 'true') result.includeSeasoningsInShopping = true;
    result._migrated_seasoning_key = true; // signal for cleanup
  }

  // Remove explicitly empty apiKey (don't store blank strings)
  if (result.apiKey === '') delete result.apiKey;

  return result;
}

function migNormalizeOverlay(overlay) {
  if (!overlay || typeof overlay !== 'object') {
    return { version: 1, recipes: {}, recipe_ingredients: {}, deletes: {} };
  }
  return {
    version: overlay.version || 1,
    recipes: (overlay.recipes && typeof overlay.recipes === 'object' && !Array.isArray(overlay.recipes)) ? overlay.recipes : {},
    recipe_ingredients: (overlay.recipe_ingredients && typeof overlay.recipe_ingredients === 'object' && !Array.isArray(overlay.recipe_ingredients)) ? overlay.recipe_ingredients : {},
    deletes: (overlay.deletes && typeof overlay.deletes === 'object' && !Array.isArray(overlay.deletes)) ? overlay.deletes : {},
  };
}

function cloneData(value) {
  return JSON.parse(JSON.stringify(value ?? null));
}

function normalizeVersion(value, fallback = 0) {
  const n = Number(value);
  return Number.isFinite(n) && n >= 0 ? Math.floor(n) : fallback;
}

function readCurrentKitchenData() {
  return {
    inventory: S.load(S.keys.inventory, []),
    plan: S.load(S.keys.plan, []),
    overlay: S.load(S.keys.overlay, { version: 1, recipes: {}, recipe_ingredients: {}, deletes: {} }),
    settings: S.load(S.keys.settings, {}),
    ai_recs: S.load(S.keys.ai_recs, null),
    local_recs: S.load(S.keys.local_recs, null),
    rec_time: S.load(S.keys.rec_time, 0),
    favorite_recipes: S.load(S.keys.favorite_recipes, []),
    recipe_usage: S.load(S.keys.recipe_usage, {}),
    recipe_activity: S.load(S.keys.recipe_activity, {}),
    shopping_items: S.load(S.keys.shopping_items, [])
  };
}

function writeCurrentKitchenData(data) {
  const requiredSaves = [
    [S.keys.inventory, data.inventory],
    [S.keys.plan, data.plan],
    [S.keys.overlay, data.overlay],
    [S.keys.settings, data.settings],
    [S.keys.ai_recs, data.ai_recs],
    [S.keys.local_recs, data.local_recs],
    [S.keys.rec_time, data.rec_time],
    [S.keys.favorite_recipes, data.favorite_recipes],
    [S.keys.recipe_usage, data.recipe_usage],
    [S.keys.recipe_activity, data.recipe_activity],
    [S.keys.shopping_items, data.shopping_items]
  ];

  for (const [key, value] of requiredSaves) {
    if (value !== undefined && !S.save(key, value)) {
      throw new Error(`无法写入 ${key}，浏览器存储空间可能不足`);
    }
  }
}

const DATA_MIGRATIONS = {
  1(data) {
    // v1 只建立版本标记，不修改数据。
    return { data, changed: false };
  },

  2(data, context) {
    let changed = false;
    const getLS = context && context.getLocalStorageItem;
    const removeLS = context && context.removeLocalStorageItem;

    // ── inventory ────────────────────────────────────────────────────────
    const rawInv = Array.isArray(data.inventory) ? data.inventory : [];
    const newInv = [];
    for (const item of rawInv) {
      const normalized = migNormalizeInventoryItem(item);
      if (!normalized) { changed = true; continue; }
      if (JSON.stringify(item) !== JSON.stringify(normalized)) changed = true;
      newInv.push(normalized);
    }
    if (newInv.length !== rawInv.length) changed = true;
    data.inventory = newInv;

    // ── shopping_items ───────────────────────────────────────────────────
    const rawShop = Array.isArray(data.shopping_items) ? data.shopping_items : [];
    const newShop = [];
    for (const item of rawShop) {
      const normalized = migNormalizeShoppingItem(item);
      if (!normalized) { changed = true; continue; }
      if (JSON.stringify(item) !== JSON.stringify(normalized)) changed = true;
      newShop.push(normalized);
    }
    if (newShop.length !== rawShop.length) changed = true;
    data.shopping_items = newShop;

    // ── settings ─────────────────────────────────────────────────────────
    const rawSettings = data.settings || {};
    const newSettings = migNormalizeSettings(rawSettings, getLS);
    const cleanSeasoningKey = newSettings._migrated_seasoning_key;
    delete newSettings._migrated_seasoning_key;
    if (JSON.stringify(rawSettings) !== JSON.stringify(newSettings)) changed = true;
    data.settings = newSettings;
    // Defer old key cleanup until after successful write (handled in runLocalStorageMigrations)
    if (cleanSeasoningKey) data._cleanOldSeasoningKey = true;

    // ── overlay ───────────────────────────────────────────────────────────
    const rawOverlay = data.overlay;
    const newOverlay = migNormalizeOverlay(rawOverlay);
    if (JSON.stringify(rawOverlay) !== JSON.stringify(newOverlay)) changed = true;
    data.overlay = newOverlay;

    // ── recipe_usage ─────────────────────────────────────────────────────
    const rawUsage = (data.recipe_usage && typeof data.recipe_usage === 'object') ? data.recipe_usage : {};
    const newUsage = {};
    for (const [id, value] of Object.entries(rawUsage)) {
      if (typeof value === 'string' || (value && typeof value === 'object')) {
        newUsage[id] = value; // keep string dates and future object records
      } else {
        changed = true; // dropped non-string/non-object values
      }
    }
    if (Object.keys(rawUsage).length !== Object.keys(newUsage).length) changed = true;
    data.recipe_usage = newUsage;

    return { data, changed };
  },

  3(data, context) {
    let changed = false;
    const rawActivity = (data.recipe_activity && typeof data.recipe_activity === 'object') ? data.recipe_activity : {};
    const newActivity = { ...rawActivity };

    const rawUsage = (data.recipe_usage && typeof data.recipe_usage === 'object') ? data.recipe_usage : {};
    for (const [id, val] of Object.entries(rawUsage)) {
      if (typeof val === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(val)) {
        if (!newActivity[id]) {
          newActivity[id] = {
            plannedAt: val,
            cookedAt: null,
            cookedCount: 0
          };
          changed = true;
        } else if (newActivity[id].plannedAt === undefined) {
          newActivity[id].plannedAt = val;
          changed = true;
        }
      }
    }

    data.recipe_activity = newActivity;
    return { data, changed };
  },

  4(data) {
    let changed = false;
    const rawPlan = Array.isArray(data.plan) ? data.plan : [];
    const newPlan = [];
    const today = migTodayISO();
    for (const item of rawPlan) {
      if (item && typeof item === 'object') {
        const id = item.id;
        const servings = Number(item.servings) || 1;
        const date = item.date || today;
        const newItem = { id, servings, date };
        if (item.date !== date || item.servings !== servings) {
          changed = true;
        }
        newPlan.push(newItem);
      } else {
        changed = true;
      }
    }
    data.plan = newPlan;
    return { data, changed };
  }
};

export function getStoredSchemaVersion() {
  return normalizeVersion(S.load(S.keys.schema_version, 0), 0);
}

export function setStoredSchemaVersion(version = DATA_SCHEMA_VERSION) {
  if (!S.save(S.keys.schema_version, normalizeVersion(version, DATA_SCHEMA_VERSION))) {
    throw new Error('无法写入数据版本号，浏览器存储空间可能不足');
  }
}

export function detectCurrentSchemaVersion() {
  return getStoredSchemaVersion();
}

function migrateDataObject(sourceData, fromVersion, context = {}) {
  let data = cloneData(sourceData) || {};
  let changed = false;

  for (let targetVersion = fromVersion + 1; targetVersion <= DATA_SCHEMA_VERSION; targetVersion++) {
    const migration = DATA_MIGRATIONS[targetVersion];
    if (!migration) continue;
    const result = migration(data, context);
    data = result?.data || data;
    changed = changed || !!result?.changed;
  }

  return { data, changed };
}

/**
 * 运行本机 localStorage 迁移。
 * 关键原则：先读取并迁移内存副本，全部成功后才写回；任何异常都不会清空旧 key。
 */
export function runLocalStorageMigrations() {
  const fromVersion = getStoredSchemaVersion();

  if (fromVersion > DATA_SCHEMA_VERSION) {
    throw new Error(`当前数据版本是 v${fromVersion}，高于此代码支持的 v${DATA_SCHEMA_VERSION}。请先导出备份，再使用更新版本的应用打开。`);
  }
  if (fromVersion === DATA_SCHEMA_VERSION) {
    return { fromVersion, toVersion: DATA_SCHEMA_VERSION, changed: false };
  }

  // Provide localStorage access context for migrations that need it (e.g. v2 settings migration)
  const lsContext = {
    getLocalStorageItem: (key) => {
      try { return localStorage.getItem(key); } catch (e) { return null; }
    },
    removeLocalStorageItem: (key) => {
      try { localStorage.removeItem(key); } catch (e) { /* ignore */ }
    }
  };

  try {
    const currentData = readCurrentKitchenData();
    const result = migrateDataObject(currentData, fromVersion, lsContext);
    if (result.changed) writeCurrentKitchenData(result.data);
    setStoredSchemaVersion(DATA_SCHEMA_VERSION);
    // Post-write cleanup: remove old bare localStorage keys that were migrated into settings
    if (result.data && result.data._cleanOldSeasoningKey) {
      lsContext.removeLocalStorageItem('km_include_seasoning');
    }
    return { fromVersion, toVersion: DATA_SCHEMA_VERSION, changed: result.changed };
  } catch (error) {
    throw new Error(`数据迁移失败，已保留原始数据：${error.message || error}`);
  }
}

/**
 * 统一整理导入的备份格式。
 * 支持旧的 inventory-only 文件、没有 schemaVersion 的旧完整备份，以及新的 schemaVersion 备份。
 */
export function normalizeBackupForRestore(payload) {
  if (payload && payload.type === 'kitchen-inventory' && Array.isArray(payload.inventory)) {
    return {
      type: 'kitchen-backup',
      version: 1,
      appVersion: APP_VERSION,
      schemaVersion: DATA_SCHEMA_VERSION,
      migratedFromSchemaVersion: 0,
      data: { inventory: cloneData(payload.inventory), schemaVersion: DATA_SCHEMA_VERSION }
    };
  }

  if (!payload || payload.type !== 'kitchen-backup' || !payload.data || typeof payload.data !== 'object') {
    throw new Error('不是有效的厨房备份文件');
  }

  const sourceVersion = normalizeVersion(payload.schemaVersion ?? payload.data.schemaVersion, 0);
  if (sourceVersion > DATA_SCHEMA_VERSION) {
    throw new Error(`这个备份的数据版本是 v${sourceVersion}，当前应用只支持到 v${DATA_SCHEMA_VERSION}。请先升级应用再导入。`);
  }

  try {
    const result = migrateDataObject(payload.data, sourceVersion);
    return {
      ...payload,
      version: payload.version || 1,
      appVersion: payload.appVersion || APP_VERSION,
      schemaVersion: DATA_SCHEMA_VERSION,
      migratedFromSchemaVersion: sourceVersion,
      data: { ...result.data, schemaVersion: DATA_SCHEMA_VERSION }
    };
  } catch (error) {
    throw new Error(`备份迁移失败，未写入任何导入数据：${error.message || error}`);
  }
}
