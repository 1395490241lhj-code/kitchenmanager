import { S } from './storage.js?v=235';
import {
  APP_VERSION,
  DATA_SCHEMA_VERSION,
  normalizeBackupForRestore,
  setStoredSchemaVersion
} from './migrations.js?v=235';
import { genId } from './shopping.js?v=235';

export const BACKUP_APP_ID = 'kitchenmanager';
export const BACKUP_FORMAT_VERSION = 1;
export const BACKUP_NUDGE_DISMISS_DAYS = 7;
export const BACKUP_RECENT_EXPORT_DAYS = 30;

// ── 备份范围的三类数据 ───────────────────────────────────────────────────────
// 1. 用户持久数据（必须备份，丢了没法重建）：
//    inventory / plan / shopping_items / favorite_recipes / settings /
//    staples / pantry_config / overlay（用户菜谱补丁）/ ai_disliked_recipes
//    （AI「不喜欢/不合理」反馈）/ receipt_aliases（小票识别学到的别名纠正）。
// 2. 可重建缓存（不必备份，重新生成即可，纳入备份只是图省事）：
//    ai_recs / local_recs / rec_time / rec_signature（今日推荐缓存 + 签名）；
//    recipe_usage / recipe_activity（烹饪频次统计，丢了会重新累积，不影响可用性）；
//    prep_done（明日备菜勾选状态，跨天即失效）。
// 3. 设备级 UI 状态（按现有策略处理，不进备份 —— 这些只对「这台设备/这次会话」
//    有意义，换设备恢复备份时不应该被覆盖）：
//    demo_mode / demo_snapshot / demo_step / backup_nudge_dismissed_at /
//    backup_last_exported_at / pwa_install_dismissed_at / pwa_install_done。
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
  'rec_signature',
  'ai_disliked_recipes',
  'receipt_aliases'
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
  rec_signature: null,
  ai_disliked_recipes: {},
  receipt_aliases: {}
};

const DAY_MS = 24 * 60 * 60 * 1000;

const clone = value => JSON.parse(JSON.stringify(value ?? null));

const isPlainObject = value =>
  !!value && typeof value === 'object' && !Array.isArray(value);

// ── 备份导入结构校验 ─────────────────────────────────────────────────────────
// validateKitchenBackup 原来只检查顶层 key 名和 JSON 可序列化性，没验证每个 key 的
// 内部结构——合法 JSON 但形状不对（例如 overlay.recipe_ingredients.r1 是 {} 而不是
// 数组）能通过校验，之后 applyOverlay 里 list.slice 崩溃，导致应用启动失败。
// 这里给 inventory / plan / shopping_items / settings / overlay 各建一个运行时
// 校验 + 归一函数：容器形状错了直接抛错拒绝整份备份（零写入）；数组内的单项错误
// 只做安全归一/丢弃单项，不影响可用的部分。

const BACKUP_MAX_ARRAY_LENGTH = 5000; // 单个 key 允许的最大数组长度，避免超大数组卡死

const isSafeScalar = value =>
  value === null || typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean';

function safeStringOr(value, fallback = '') {
  if (typeof value === 'string') return value;
  if (typeof value === 'number' && Number.isFinite(value)) return String(value);
  return fallback;
}

// 深拷贝并剥离函数 / undefined / Symbol 等无法安全序列化的内容；真正的循环引用等
// 无法安全表示的结构直接抛错，交给调用方拒绝整份备份。
function safeCloneJson(value) {
  try {
    return JSON.parse(JSON.stringify(value));
  } catch (error) {
    throw new Error('备份内容包含无法安全读取的数据');
  }
}

function normalizeBackupInventory(value) {
  if (!Array.isArray(value)) throw new Error('备份里的 inventory 格式不对（不是数组）');
  if (value.length > BACKUP_MAX_ARRAY_LENGTH) throw new Error('备份里的 inventory 数据量异常，已拒绝导入');
  const items = [];
  for (const raw of value) {
    if (!isPlainObject(raw)) continue; // 至少是对象，否则跳过这一项
    const name = safeStringOr(raw.name ?? raw.item, '').trim();
    if (!name) continue; // name/item 归一不出字符串就丢弃这一项
    const clean = safeCloneJson(raw);
    const overrides = { name };
    // qty/unit/shelf/kind/storage 只做安全归一：不是函数/嵌套对象等"奇怪值"就原样保留，
    // 否则替换成安全默认值，不允许它们污染进 localStorage。
    if ('qty' in raw) overrides.qty = isSafeScalar(raw.qty) ? raw.qty : '';
    if ('unit' in raw) overrides.unit = safeStringOr(raw.unit, '');
    if ('shelf' in raw) overrides.shelf = isSafeScalar(raw.shelf) ? raw.shelf : '';
    if ('kind' in raw) overrides.kind = safeStringOr(raw.kind, '');
    if ('storage' in raw) overrides.storage = safeStringOr(raw.storage, '');
    items.push({ ...clean, ...overrides });
  }
  return items;
}

function normalizeBackupPlan(value) {
  if (!Array.isArray(value)) throw new Error('备份里的 plan 格式不对（不是数组）');
  if (value.length > BACKUP_MAX_ARRAY_LENGTH) throw new Error('备份里的 plan 数据量异常，已拒绝导入');
  const items = [];
  for (const raw of value) {
    if (!isPlainObject(raw)) continue; // 每项必须是对象，否则跳过
    const id = safeStringOr(raw.id, '').trim();
    const name = safeStringOr(raw.name, '').trim();
    if (!id && !name) continue; // id 或 name 至少一个存在，否则这一项没法定位对应的菜
    const clean = safeCloneJson(raw);
    const overrides = {};
    if (id) overrides.id = id;
    if (name) overrides.name = name;
    // servings/date/isCooked/cookedAt 保留但归一：只在原本存在时才归一类型，不凭空造字段。
    if ('servings' in raw) overrides.servings = isSafeScalar(raw.servings) ? raw.servings : 1;
    if ('date' in raw) overrides.date = typeof raw.date === 'string' ? raw.date : '';
    if ('isCooked' in raw) overrides.isCooked = !!raw.isCooked;
    if ('cookedAt' in raw) overrides.cookedAt = safeStringOr(raw.cookedAt, null);
    items.push({ ...clean, ...overrides });
  }
  return items;
}

function normalizeBackupShoppingItems(value) {
  if (!Array.isArray(value)) throw new Error('备份里的 shopping_items 格式不对（不是数组）');
  if (value.length > BACKUP_MAX_ARRAY_LENGTH) throw new Error('备份里的 shopping_items 数据量异常，已拒绝导入');
  const items = [];
  for (const raw of value) {
    if (!isPlainObject(raw)) continue; // 每项必须是对象，否则跳过
    const name = safeStringOr(raw.name, '').trim();
    if (!name) continue; // name 必须存在
    const clean = safeCloneJson(raw);
    // id 缺失可以补；类型不对（不是字符串）也当缺失处理，重新生成一个稳定 id。
    const id = typeof raw.id === 'string' && raw.id.trim() ? raw.id.trim() : genId();
    items.push({ ...clean, name, id });
  }
  return items;
}

function normalizeBackupSettings(value) {
  if (value === undefined || value === null) return {};
  if (!isPlainObject(value)) throw new Error('备份里的 settings 格式不对（不是普通对象）');
  // 只允许可序列化的 primitive / plain object / array：JSON 往返会自动剥离函数、
  // undefined、Symbol 等；真正无法安全表示的内容（如循环引用）会在这里被拒绝。
  return safeCloneJson(value);
}

function normalizeBackupOverlay(value) {
  if (value === undefined || value === null) return emptyOverlay();
  if (!isPlainObject(value)) throw new Error('备份里的 overlay 格式不对（不是普通对象）');

  if (value.recipes !== undefined && !isPlainObject(value.recipes)) {
    throw new Error('备份里的 overlay.recipes 格式不对（不是对象）');
  }
  const recipes = {};
  for (const [id, record] of Object.entries(value.recipes || {})) {
    if (!isPlainObject(record)) throw new Error(`备份里的 overlay.recipes.${id} 格式不对（不是对象）`);
    recipes[id] = safeCloneJson(record);
  }

  if (value.recipe_ingredients !== undefined && !isPlainObject(value.recipe_ingredients)) {
    throw new Error('备份里的 overlay.recipe_ingredients 格式不对（不是对象）');
  }
  const recipe_ingredients = {};
  for (const [id, list] of Object.entries(value.recipe_ingredients || {})) {
    // 这里就是背景描述的崩溃根因：value 必须是数组，否则后续 applyOverlay 里
    // list.slice() 会直接抛异常，导致应用启动失败——所以在导入这一步就拒绝。
    if (!Array.isArray(list)) throw new Error(`备份里的 overlay.recipe_ingredients.${id} 格式不对（不是数组）`);
    if (list.length > BACKUP_MAX_ARRAY_LENGTH) throw new Error('备份里的 overlay.recipe_ingredients 数据量异常，已拒绝导入');
    recipe_ingredients[id] = safeCloneJson(list);
  }

  if (value.deletes !== undefined && !isPlainObject(value.deletes)) {
    throw new Error('备份里的 overlay.deletes 格式不对（不是对象）');
  }
  const deletes = safeCloneJson(value.deletes || {});

  return {
    version: isSafeScalar(value.version) ? value.version : 1,
    recipes,
    recipe_ingredients,
    deletes
  };
}

const BACKUP_MAX_AI_DISLIKED_RECIPES = 100; // 与 src/utils/ai-disliked-recipes.js 的运行时上限一致
const BACKUP_MAX_RECEIPT_ALIASES = 500;

function normalizeBackupAiDislikedRecipes(value) {
  if (value === undefined || value === null) return {};
  if (!isPlainObject(value)) throw new Error('备份里的 ai_disliked_recipes 格式不对（不是普通对象）');
  const entries = [];
  for (const [key, raw] of Object.entries(value)) {
    const name = safeStringOr(key, '').trim();
    if (!name) continue; // 每一项必须至少有可识别菜名，否则丢弃这一项
    const record = isPlainObject(raw) ? raw : {};
    const reason = safeStringOr(record.reason, '用户标记不喜欢');
    const ts = (typeof record.ts === 'number' && Number.isFinite(record.ts)) ? record.ts : Date.now();
    entries.push([name, { name, reason, ts }]);
  }
  // 最多保留 100 条：与 markAiRecipeDisliked 的淘汰策略一致，优先保留时间戳较新的。
  entries.sort((a, b) => a[1].ts - b[1].ts);
  return Object.fromEntries(entries.slice(-BACKUP_MAX_AI_DISLIKED_RECIPES));
}

function normalizeBackupReceiptAliases(value) {
  if (value === undefined || value === null) return {};
  if (!isPlainObject(value)) throw new Error('备份里的 receipt_aliases 格式不对（不是普通对象）');
  const entries = [];
  for (const [rawKey, rawValue] of Object.entries(value)) {
    const key = rawKey.trim();
    if (!key || typeof rawValue !== 'string') continue; // key/value 都必须是非空字符串
    const val = rawValue.trim();
    if (!val) continue;
    entries.push([key, val]);
  }
  return Object.fromEntries(entries.slice(0, BACKUP_MAX_RECEIPT_ALIASES));
}

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
  // 旧版备份的容器形状本来就宽松兼容（不是数组就当空数组），这里保留这个宽容度；
  // 但数组内部单项 / overlay 的结构校验统一复用新的归一函数，堵住同一个崩溃根因。
  setIfPresent('inventory', normalizeBackupInventory(Array.isArray(data.inventory) ? data.inventory : []));
  setIfPresent('plan', normalizeBackupPlan(Array.isArray(data.plan) ? data.plan : []));
  setIfPresent('shopping_items', normalizeBackupShoppingItems(Array.isArray(data.shopping_items) ? data.shopping_items : []));
  setIfPresent('favorite_recipes', Array.isArray(data.favorite_recipes) ? data.favorite_recipes : []);
  setIfPresent('recipe_usage', isPlainObject(data.recipe_usage) ? data.recipe_usage : {});
  setIfPresent('recipe_activity', isPlainObject(data.recipe_activity) ? data.recipe_activity : {});
  setIfPresent('settings', scrubSettingsForBackup(normalizeBackupSettings(data.settings)));
  setIfPresent('staples', isPlainObject(data.staples) ? data.staples : {});
  setIfPresent('pantry_config', isPlainObject(data.pantry_config) ? data.pantry_config : {});
  setIfPresent('prep_done', isPlainObject(data.prep_done) ? data.prep_done : {});
  setIfPresent('overlay', normalizeBackupOverlay(data.overlay));
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
  // 有专门结构校验/归一函数的 key：容器/内部形状错了直接抛错，拒绝整份备份（零写入）。
  const keyNormalizers = {
    [S.keys.inventory]: normalizeBackupInventory,
    [S.keys.plan]: normalizeBackupPlan,
    [S.keys.shopping_items]: normalizeBackupShoppingItems,
    [S.keys.settings]: normalizeBackupSettings,
    [S.keys.overlay]: normalizeBackupOverlay,
    [S.keys.ai_disliked_recipes]: normalizeBackupAiDislikedRecipes,
    [S.keys.receipt_aliases]: normalizeBackupReceiptAliases
  };
  const keys = {};
  for (const [key, value] of Object.entries(payload.keys)) {
    if (!allowedKeys.has(key)) continue;
    const normalize = keyNormalizers[key];
    if (normalize) {
      keys[key] = normalize(value); // 内部已按需抛错，异常直接向上传播、不写入任何内容
      continue;
    }
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
