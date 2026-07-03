import { S } from './storage.js?v=231';
import {
  APP_VERSION,
  DATA_SCHEMA_VERSION,
  normalizeBackupForRestore,
  setStoredSchemaVersion
} from './migrations.js?v=231';

export const BACKUP_APP_ID = 'kitchenmanager';
export const BACKUP_FORMAT_VERSION = 1;
export const BACKUP_NUDGE_DISMISS_DAYS = 7;
export const BACKUP_RECENT_EXPORT_DAYS = 30;

const BACKUP_KEY_NAMES = [
  'inventory',
  'plan',
  'shopping_items',
  'favorite_recipes',
  'recipe_usage',
  'recipe_activity',
  'settings',
  'staples',
  'pantry_config',
  'prep_done',
  'overlay',
  'local_recs',
  'ai_recs',
  'rec_time',
  'rec_signature'
];

const BACKUP_DEFAULTS = {
  inventory: [],
  plan: [],
  shopping_items: [],
  favorite_recipes: [],
  recipe_usage: {},
  recipe_activity: {},
  settings: {},
  staples: {},
  pantry_config: {},
  prep_done: {},
  overlay: null,
  local_recs: null,
  ai_recs: null,
  rec_time: 0,
  rec_signature: null
};

const DAY_MS = 24 * 60 * 60 * 1000;

const clone = value => JSON.parse(JSON.stringify(value ?? null));

const isPlainObject = value =>
  !!value && typeof value === 'object' && !Array.isArray(value);

function readTimestamp(key) {
  try {
    const raw = localStorage.getItem(key);
    if (!raw) return 0;
    const numeric = Number(raw);
    if (Number.isFinite(numeric) && numeric > 0) return numeric;
    const parsed = Date.parse(raw);
    return Number.isFinite(parsed) ? parsed : 0;
  } catch (e) {
    return 0;
  }
}

function writeTimestamp(key, now = Date.now()) {
  try {
    localStorage.setItem(key, String(now));
    return true;
  } catch (e) {
    return false;
  }
}

function wasWithinDays(key, now = Date.now(), days = 0) {
  const timestamp = readTimestamp(key);
  if (!timestamp) return false;
  const age = Number(now) - timestamp;
  return age >= 0 && age < days * DAY_MS;
}

function isUsableInventoryItem(item) {
  if (!item || !String(item.name || '').trim()) return false;
  const qty = Number(item.qty ?? 1);
  return !Number.isFinite(qty) || qty > 0;
}

function hasPlanItem(plan) {
  return (plan || []).some(item => item && item.id && !item.isCooked);
}

function hasOpenShoppingItems(items) {
  return (items || []).filter(item => item && item.name && !item.done && !item.stockedIn).length >= 3;
}

function hasUserRecipePatch(overlay) {
  if (!isPlainObject(overlay)) return false;
  return Object.keys(overlay.recipes || {}).length > 0
    || Object.keys(overlay.recipe_ingredients || {}).length > 0
    || Object.keys(overlay.deletes || {}).length > 0;
}

export function hasKitchenDataForBackupNudge({ inventory = [], plan = [], shoppingItems = [], overlay = null } = {}) {
  return (inventory || []).filter(isUsableInventoryItem).length >= 5
    || hasPlanItem(plan)
    || hasOpenShoppingItems(shoppingItems)
    || hasUserRecipePatch(overlay);
}

export function hasRecentBackupNudgeDismissal(now = Date.now()) {
  return wasWithinDays(S.keys.backup_nudge_dismissed_at, now, BACKUP_NUDGE_DISMISS_DAYS);
}

export function hasRecentKitchenBackupExport(now = Date.now()) {
  return wasWithinDays(S.keys.backup_last_exported_at, now, BACKUP_RECENT_EXPORT_DAYS);
}

export function markBackupNudgeDismissed(now = Date.now()) {
  return writeTimestamp(S.keys.backup_nudge_dismissed_at, now);
}

export function markKitchenBackupExported(now = Date.now()) {
  return writeTimestamp(S.keys.backup_last_exported_at, now);
}

export function shouldShowBackupNudge({
  inventory = [],
  plan = [],
  shoppingItems = [],
  overlay = null,
  isDemoMode = false,
  now = Date.now()
} = {}) {
  if (isDemoMode) return false;
  if (!hasKitchenDataForBackupNudge({ inventory, plan, shoppingItems, overlay })) return false;
  if (hasRecentBackupNudgeDismissal(now)) return false;
  if (hasRecentKitchenBackupExport(now)) return false;
  return true;
}

export function emptyOverlay() {
  return { version: 1, recipes: {}, recipe_ingredients: {}, deletes: {} };
}

export function loadOverlay() {
  return S.load(S.keys.overlay, emptyOverlay());
}

export function saveOverlay(overlay) {
  if (!S.save(S.keys.overlay, overlay)) throw new Error('菜谱补丁写入失败，浏览器存储空间可能不足');
}

export function getKitchenBackupKeyEntries() {
  return BACKUP_KEY_NAMES
    .filter(name => S.keys[name])
    .map(name => [name, S.keys[name]]);
}

function scrubSettingsForBackup(settings) {
  const next = isPlainObject(settings) ? { ...settings } : {};
  delete next.apiKey;
  return next;
}

function readBackupValue(name, key) {
  if (name === 'overlay') return loadOverlay();
  if (name === 'settings') return scrubSettingsForBackup(S.load(key, {}));
  return S.load(key, clone(BACKUP_DEFAULTS[name]));
}

export function downloadJsonFile(payload, filename) {
  const blob = new Blob([JSON.stringify(payload, null, 2)], { type: 'application/json' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 0);
}

export function exportKitchenBackup() {
  const keys = {};
  for (const [name, key] of getKitchenBackupKeyEntries()) {
    keys[key] = readBackupValue(name, key);
  }
  return {
    app: BACKUP_APP_ID,
    schemaVersion: DATA_SCHEMA_VERSION,
    backupVersion: BACKUP_FORMAT_VERSION,
    appVersion: APP_VERSION,
    exportedAt: new Date().toISOString(),
    keys
  };
}

export const buildKitchenBackup = exportKitchenBackup;

function parseBackupInput(input) {
  if (typeof input !== 'string') return input;
  try {
    return JSON.parse(input);
  } catch (error) {
    throw new Error('备份文件无法读取');
  }
}

function keysFromLegacyData(data = {}) {
  const keys = {};
  const setIfPresent = (name, value) => {
    if (value !== undefined && S.keys[name]) keys[S.keys[name]] = value;
  };
  setIfPresent('inventory', Array.isArray(data.inventory) ? data.inventory : []);
  setIfPresent('plan', Array.isArray(data.plan) ? data.plan : []);
  setIfPresent('shopping_items', Array.isArray(data.shopping_items) ? data.shopping_items : []);
  setIfPresent('favorite_recipes', Array.isArray(data.favorite_recipes) ? data.favorite_recipes : []);
  setIfPresent('recipe_usage', isPlainObject(data.recipe_usage) ? data.recipe_usage : {});
  setIfPresent('recipe_activity', isPlainObject(data.recipe_activity) ? data.recipe_activity : {});
  setIfPresent('settings', scrubSettingsForBackup(data.settings));
  setIfPresent('staples', isPlainObject(data.staples) ? data.staples : {});
  setIfPresent('pantry_config', isPlainObject(data.pantry_config) ? data.pantry_config : {});
  setIfPresent('prep_done', isPlainObject(data.prep_done) ? data.prep_done : {});
  setIfPresent('overlay', isPlainObject(data.overlay) ? data.overlay : emptyOverlay());
  setIfPresent('local_recs', data.local_recs ?? null);
  setIfPresent('ai_recs', data.ai_recs ?? null);
  setIfPresent('rec_time', data.rec_time ?? 0);
  setIfPresent('rec_signature', data.rec_signature ?? null);
  return keys;
}

function legacyBackupToCurrent(payload) {
  const backup = normalizeBackupForRestore(payload);
  return {
    app: BACKUP_APP_ID,
    schemaVersion: DATA_SCHEMA_VERSION,
    backupVersion: BACKUP_FORMAT_VERSION,
    appVersion: backup.appVersion || APP_VERSION,
    exportedAt: backup.exportedAt || new Date().toISOString(),
    migratedFromSchemaVersion: backup.migratedFromSchemaVersion,
    keys: keysFromLegacyData(backup.data)
  };
}

export function validateKitchenBackup(input) {
  const payload = parseBackupInput(input);
  if (!isPlainObject(payload)) {
    throw new Error('备份文件无法读取');
  }

  if (payload.app !== undefined && payload.app !== BACKUP_APP_ID) {
    throw new Error('这不是 Kitchen Manager 的备份文件');
  }

  if (payload.app === undefined && (payload.type === 'kitchen-backup' || payload.type === 'kitchen-inventory')) {
    return legacyBackupToCurrent(payload);
  }

  if (payload.app !== BACKUP_APP_ID) {
    throw new Error('这不是 Kitchen Manager 的备份文件');
  }

  const schemaVersion = Number(payload.schemaVersion);
  if (!Number.isFinite(schemaVersion) || schemaVersion < 1) {
    throw new Error('备份文件缺少数据版本');
  }
  if (schemaVersion > DATA_SCHEMA_VERSION) {
    throw new Error(`这个备份的数据版本是 v${schemaVersion}，当前应用只支持到 v${DATA_SCHEMA_VERSION}`);
  }
  if (!isPlainObject(payload.keys)) {
    throw new Error('备份文件缺少厨房数据');
  }

  const allowedKeys = new Set(getKitchenBackupKeyEntries().map(([, key]) => key));
  const keys = {};
  for (const [key, value] of Object.entries(payload.keys)) {
    if (!allowedKeys.has(key)) continue;
    let serialized;
    try {
      serialized = JSON.stringify(value);
    } catch (error) {
      throw new Error(`备份里的 ${key} 无法读取`);
    }
    if (serialized === undefined) {
      throw new Error(`备份里的 ${key} 无法读取`);
    }
    keys[key] = value;
  }
  if (!Object.keys(keys).length) {
    throw new Error('备份文件里没有可恢复的厨房数据');
  }

  return { ...payload, schemaVersion: DATA_SCHEMA_VERSION, keys };
}

function restoreBackupEntries(entries) {
  const serialized = entries.map(([key, value]) => [key, JSON.stringify(value)]);
  const allKeys = new Set([...getKitchenBackupKeyEntries().map(([, key]) => key), S.keys.schema_version]);
  const snapshot = new Map();
  for (const key of allKeys) snapshot.set(key, localStorage.getItem(key));

  try {
    for (const [key, value] of serialized) localStorage.setItem(key, value);
    setStoredSchemaVersion(DATA_SCHEMA_VERSION);
  } catch (error) {
    for (const [key, value] of snapshot.entries()) {
      if (value === null) localStorage.removeItem(key);
      else localStorage.setItem(key, value);
    }
    throw new Error(`导入失败，当前厨房数据没有被覆盖：${error.message || error}`);
  }
}

export function importKitchenBackup(input) {
  const backup = validateKitchenBackup(input);
  const allowedKeys = new Set(getKitchenBackupKeyEntries().map(([, key]) => key));
  const currentSettings = S.load(S.keys.settings, {});
  const entries = [];

  for (const [key, value] of Object.entries(backup.keys)) {
    if (!allowedKeys.has(key)) continue;
    if (key === S.keys.settings) {
      const settings = scrubSettingsForBackup(value);
      if (currentSettings.apiKey) settings.apiKey = currentSettings.apiKey;
      entries.push([key, settings]);
      continue;
    }
    entries.push([key, value]);
  }
  if (!entries.length) throw new Error('备份文件里没有可恢复的厨房数据');

  restoreBackupEntries(entries);
  if (typeof window !== 'undefined' && window.invalidatePackCache) {
    window.invalidatePackCache();
  }
  return backup;
}

export const restoreKitchenBackup = importKitchenBackup;

export function applyOverlay(base, overlay) {
  const recipes = [];
  const ingMap = JSON.parse(JSON.stringify(base.recipe_ingredients || {}));
  const baseMap = new Map((base.recipes || []).map(r => [r.id, { ...r }]));
  const del = overlay.deletes || {};
  for (const [id, flag] of Object.entries(del)) {
    if (flag) {
      baseMap.delete(id);
      delete ingMap[id];
    }
  }

  const ro = overlay.recipes || {};
  for (const [id, ov] of Object.entries(ro)) {
    if (del[id]) continue;
    if (!baseMap.has(id)) {
      baseMap.set(id, { id, name: '未命名', tags: [], method: '', ...ov });
    } else {
      const old = baseMap.get(id);
      const finalMethod = ov.method || old.staticMethod || old.method || '';
      baseMap.set(id, { ...old, ...ov, method: finalMethod });
    }
  }

  const io = overlay.recipe_ingredients || {};
  for (const [id, list] of Object.entries(io)) {
    if (del[id]) continue;
    ingMap[id] = list.slice();
  }

  for (const r of baseMap.values()) {
    if (!r.method && r.staticMethod) r.method = r.staticMethod;
    recipes.push(r);
  }

  for (const [id, ov] of Object.entries(ro)) {
    if (del[id]) continue;
    if (/^(u-|ai-search-)/.test(id) && !recipes.find(x => x.id === id)) {
      recipes.push({ id, name: '自定义', tags: ['自定义'], method: '', ...ov });
      if (!ingMap[id]) ingMap[id] = (io[id] || []);
    }
  }

  recipes.sort((a, b) => a.name.localeCompare(b.name, 'zh-Hans-CN'));
  return { recipes, recipe_ingredients: ingMap };
}
