import { S } from './storage.js?v=219';
import {
  APP_VERSION,
  DATA_SCHEMA_VERSION,
  normalizeBackupForRestore,
  setStoredSchemaVersion
} from './migrations.js?v=219';
import { loadShoppingItems, saveShoppingItems } from './shopping.js?v=219';

export function emptyOverlay() {
  return { version: 1, recipes: {}, recipe_ingredients: {}, deletes: {} };
}

export function loadOverlay() {
  return S.load(S.keys.overlay, emptyOverlay());
}

export function saveOverlay(overlay) {
  if (!S.save(S.keys.overlay, overlay)) throw new Error('菜谱补丁写入失败，浏览器存储空间可能不足');
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

export function buildKitchenBackup() {
  const originalSettings = S.load(S.keys.settings, {});
  const settings = { ...originalSettings };
  delete settings.apiKey;

  return {
    type: 'kitchen-backup',
    version: 1,
    appVersion: APP_VERSION,
    schemaVersion: DATA_SCHEMA_VERSION,
    exportedAt: new Date().toISOString(),
    data: {
      schemaVersion: DATA_SCHEMA_VERSION,
      inventory: S.load(S.keys.inventory, []),
      plan: S.load(S.keys.plan, []),
      overlay: loadOverlay(),
      settings: settings,
      favorite_recipes: S.load(S.keys.favorite_recipes, []),
      recipe_usage: S.load(S.keys.recipe_usage, {}),
      recipe_activity: S.load(S.keys.recipe_activity, {}),
      shopping_items: loadShoppingItems(),
      staples: S.load(S.keys.staples, {})
    }
  };
}

export function restoreKitchenBackup(payload) {
  const backup = normalizeBackupForRestore(payload);
  const data = backup.data;

  if (Array.isArray(data.inventory) && !S.save(S.keys.inventory, data.inventory)) throw new Error('库存写入失败，浏览器存储空间可能不足');
  if (Array.isArray(data.plan) && !S.save(S.keys.plan, data.plan)) throw new Error('今日计划写入失败，浏览器存储空间可能不足');
  if (data.overlay) saveOverlay(data.overlay);
  if (data.settings) {
    const currentSettings = S.load(S.keys.settings, {});
    const newSettings = { ...data.settings };
    if (!newSettings.apiKey && currentSettings.apiKey) {
      newSettings.apiKey = currentSettings.apiKey;
    }
    if (!S.save(S.keys.settings, newSettings)) throw new Error('设置写入失败，浏览器存储空间可能不足');
  }
  if (Array.isArray(data.favorite_recipes) && !S.save(S.keys.favorite_recipes, data.favorite_recipes)) throw new Error('常做菜写入失败，浏览器存储空间可能不足');
  if (data.recipe_usage && typeof data.recipe_usage === 'object' && !S.save(S.keys.recipe_usage, data.recipe_usage)) throw new Error('菜谱记录写入失败，浏览器存储空间可能不足');
  if (data.recipe_activity && typeof data.recipe_activity === 'object' && !S.save(S.keys.recipe_activity, data.recipe_activity)) throw new Error('菜谱活动记录写入失败，浏览器存储空间可能不足');
  if (Array.isArray(data.shopping_items) && !saveShoppingItems(data.shopping_items)) throw new Error('购物清单写入失败，浏览器存储空间可能不足');
  if (data.staples && typeof data.staples === 'object' && !Array.isArray(data.staples) && !S.save(S.keys.staples, data.staples)) throw new Error('常备品状态写入失败，浏览器存储空间可能不足');
  setStoredSchemaVersion(DATA_SCHEMA_VERSION);
  if (typeof window !== 'undefined' && window.invalidatePackCache) {
    window.invalidatePackCache();
  }
  return backup;
}

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
