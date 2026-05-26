import { S } from './storage.js?v=98';

export const APP_VERSION = '151';
export const DATA_SCHEMA_VERSION = 1;

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
    // 第一版正式 schema 只建立版本标记。
    // 旧用户的数据仍留在原来的 km_v* key 中，不做改名、不做删除，避免升级时误伤真实库存。
    return { data, changed: false };
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

function migrateDataObject(sourceData, fromVersion) {
  let data = cloneData(sourceData) || {};
  let changed = false;

  for (let targetVersion = fromVersion + 1; targetVersion <= DATA_SCHEMA_VERSION; targetVersion++) {
    const migration = DATA_MIGRATIONS[targetVersion];
    if (!migration) continue;
    const result = migration(data);
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

  try {
    const currentData = readCurrentKitchenData();
    const result = migrateDataObject(currentData, fromVersion);
    if (result.changed) writeCurrentKitchenData(result.data);
    setStoredSchemaVersion(DATA_SCHEMA_VERSION);
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
