/*
 * src/staples.js —— 常备品（Staples）双态模型 + 采购闭环
 *
 * 设计：
 *  - 除可计数项（鸡蛋、牛奶等，由首页「常备货架」按数量管理）外，调料 / 米面 / 干粉
 *    这类常备品的状态简化为双态布尔：SUFFICIENT（充足）/ INSUFFICIENT（不足）。
 *  - 状态持久化在 localStorage（key: km_v1_staples）：
 *      { [canonicalName]: { status: 'SUFFICIENT'|'INSUFFICIENT', updatedAt: ISO } }
 *    没有记录的常备品默认视为 SUFFICIENT。
 *
 * 闭环：
 *  1. 切换为 INSUFFICIENT  → 自动加入购物清单（source = '常备品'）。
 *  2. 切回 SUFFICIENT      → 移除该常备品仍未购买的清单项，并更新库存时间。
 *  3. 在购物清单中勾选「已买」/「入库」 → 调 restoreStapleByPurchase() 自动恢复
 *     为 SUFFICIENT 并更新库存时间（updatedAt）。
 */

import { S } from './storage.js?v=210';
import { getCanonicalName } from './ingredients.js?v=210';
import { addShoppingItem, loadShoppingItems, saveShoppingItems } from './shopping.js?v=210';

export const STAPLE_STATUS = { SUFFICIENT: 'SUFFICIENT', INSUFFICIENT: 'INSUFFICIENT' };
const STAPLE_SOURCE = '常备品';

// 双态常备品目录（不含鸡蛋/牛奶等可计数项——那些在首页常备货架按数量管理）。
export const STAPLE_CATALOG = [
  { group: '基础调味', items: ['盐', '糖', '生抽', '老抽', '醋', '料酒', '蚝油', '香油', '味精', '鸡精'] },
  { group: '酱料 / 腌菜', items: ['豆瓣酱', '甜面酱', '豆豉', '泡椒', '酸菜', '酸豆角'] },
  { group: '香料 / 干粉', items: ['淀粉', '花椒', '干辣椒', '胡椒粉', '八角', '桂皮', '香叶', '五香粉', '孜然'] },
  { group: '米面 / 油', items: ['大米', '面粉', '挂面', '菜油', '猪油'] },
  { group: '生鲜常备', items: ['葱', '姜', '蒜', '大葱', '香菜', '小米辣'] }
];

export const PANTRY_GROUP_OPTIONS = [
  ...STAPLE_CATALOG.map(group => group.group),
  '蛋奶',
  '干货'
];

const STAPLE_NAMES = new Set();
STAPLE_CATALOG.forEach(group => group.items.forEach(name => STAPLE_NAMES.add(getCanonicalName(name))));

function normalizePantryConfig(raw) {
  const config = (raw && typeof raw === 'object' && !Array.isArray(raw)) ? raw : {};
  return {
    hidden: (config.hidden && typeof config.hidden === 'object' && !Array.isArray(config.hidden)) ? config.hidden : {},
    overrides: (config.overrides && typeof config.overrides === 'object' && !Array.isArray(config.overrides)) ? config.overrides : {},
    custom: Array.isArray(config.custom) ? config.custom.filter(item => item && item.id && item.name) : []
  };
}

export function loadPantryConfig() {
  return normalizePantryConfig(S.load(S.keys.pantry_config, {}));
}

export function savePantryConfig(config) {
  return S.save(S.keys.pantry_config, normalizePantryConfig(config));
}

export function getPantryEntryId(type, group, name, kind = '') {
  return [type || 'staple', group || '', kind || '', getCanonicalName(name || '')].join('|');
}

function normalizePantryGroup(group, type = 'staple') {
  const name = String(group || '').trim();
  if (name) return name;
  return type === 'pantry' ? '干货' : STAPLE_CATALOG[0].group;
}

function groupPantryEntries(entries) {
  const groups = new Map();
  const order = [...PANTRY_GROUP_OPTIONS];
  entries.forEach(entry => {
    const group = normalizePantryGroup(entry.group, entry.type);
    if (!groups.has(group)) {
      groups.set(group, []);
      if (!order.includes(group)) order.push(group);
    }
    groups.get(group).push({ ...entry, group });
  });
  return order
    .map(group => ({ group, items: groups.get(group) || [] }))
    .filter(group => group.items.length > 0);
}

export function applyPantryCustomConfig(baseGroups, type = 'staple', defaults = {}) {
  const config = loadPantryConfig();
  const entries = [];
  (baseGroups || []).forEach(group => {
    (group.items || []).forEach(item => {
      const raw = typeof item === 'string' ? { name: item } : { ...item };
      const id = getPantryEntryId(type, group.group, raw.name, raw.kind || defaults.kind || '');
      if (config.hidden[id]) return;
      const override = config.overrides[id] || {};
      entries.push({
        ...defaults,
        ...raw,
        id,
        type,
        group: override.group || group.group,
        name: override.name || raw.name,
        originalName: raw.name,
        custom: false
      });
    });
  });

  config.custom
    .filter(item => item.type === type)
    .forEach(item => {
      if (!config.hidden[item.id]) entries.push({ ...defaults, ...item, custom: true });
    });

  return groupPantryEntries(entries);
}

export function getManagedStapleGroups() {
  return applyPantryCustomConfig(STAPLE_CATALOG, 'staple', {
    kind: 'staple',
    source: STAPLE_SOURCE,
    unit: ''
  });
}

export function addCustomPantryEntry({ name, group, type = 'staple', kind = 'staple', unit = '', source = STAPLE_SOURCE, prep = '' } = {}) {
  const cleanName = String(name || '').trim();
  if (!cleanName) return { ok: false, message: '名称不能为空。' };
  const targetType = type === 'pantry' ? 'pantry' : 'staple';
  const config = loadPantryConfig();
  const entry = {
    id: `custom|${targetType}|${Date.now().toString(36)}|${Math.random().toString(36).slice(2, 8)}`,
    type: targetType,
    group: normalizePantryGroup(group, targetType),
    name: cleanName,
    kind: kind || (targetType === 'pantry' ? 'dry' : 'staple'),
    unit: unit || '',
    source: source || STAPLE_SOURCE,
    prep: prep || '',
    custom: true,
    createdAt: new Date().toISOString()
  };
  config.custom.push(entry);
  savePantryConfig(config);
  return { ok: true, entry };
}

export function updatePantryEntry(entry, updates = {}) {
  if (!entry || !entry.id) return { ok: false, message: '没有找到要修改的常备项。' };
  const cleanName = String(updates.name || '').trim();
  if (!cleanName) return { ok: false, message: '名称不能为空。' };
  const config = loadPantryConfig();
  const group = normalizePantryGroup(updates.group || entry.group, entry.type);
  if (entry.custom) {
    const idx = config.custom.findIndex(item => item.id === entry.id);
    if (idx < 0) return { ok: false, message: '这个自定义项已经不存在。' };
    config.custom[idx] = {
      ...config.custom[idx],
      name: cleanName,
      group,
      updatedAt: new Date().toISOString()
    };
  } else {
    config.overrides[entry.id] = {
      ...(config.overrides[entry.id] || {}),
      name: cleanName,
      group,
      updatedAt: new Date().toISOString()
    };
  }
  savePantryConfig(config);
  return { ok: true };
}

export function removePantryEntry(entry) {
  if (!entry || !entry.id) return { ok: false, message: '没有找到要移除的常备项。' };
  const config = loadPantryConfig();
  if (entry.custom) {
    config.custom = config.custom.filter(item => item.id !== entry.id);
  } else {
    config.hidden[entry.id] = true;
  }
  savePantryConfig(config);
  if (entry.type === 'staple') removeOpenStapleShoppingItem(getCanonicalName(entry.name || entry.originalName || ''));
  return { ok: true };
}

function isConfiguredStaple(canonical) {
  return getManagedStapleGroups().some(group => group.items.some(item => getCanonicalName(item.name) === canonical));
}

export function isStaple(name) {
  const canonical = getCanonicalName(name || '');
  return STAPLE_NAMES.has(canonical) || isConfiguredStaple(canonical);
}

/**
 * 常备拦截 —— 判定一个食材是否属于「常备货架（Pantry / Staples）」。
 * 既支持传入字符串名称，也支持传入带 category / isPantry 标记的食材对象：
 *   · isPantry === true                         → 常备
 *   · category === '调味品' 或 category === '常备' → 常备
 *   · 命中常备目录（STAPLE_CATALOG / 自定义常备） → 常备
 */
export function isPantryStaple(ingredient) {
  if (ingredient && typeof ingredient === 'object') {
    if (ingredient.isPantry === true) return true;
    if (ingredient.category === '调味品' || ingredient.category === '常备') return true;
    return isStaple(ingredient.name || ingredient.item || '');
  }
  return isStaple(ingredient || '');
}

/**
 * 读取常备货架上某常备品的「货架状态」：
 *   · 返回 true  → 状态为 0（断货 / INSUFFICIENT），厨房里确实没有了；
 *   · 返回 false → 状态非 0（充足，货架上仍有），应从缺货明细中强制剔除。
 * 仅当返回 true 时，该常备品才允许作为缺货项出现。
 */
export function isStapleOutOfStock(name) {
  return getStapleState(name).status === STAPLE_STATUS.INSUFFICIENT;
}

function loadStaples() {
  const map = S.load(S.keys.staples, {});
  return (map && typeof map === 'object' && !Array.isArray(map)) ? map : {};
}

function saveStaples(map) {
  return S.save(S.keys.staples, map);
}

export function getStapleState(name) {
  const c = getCanonicalName(name || '');
  const entry = loadStaples()[c];
  const status = entry && entry.status === STAPLE_STATUS.INSUFFICIENT
    ? STAPLE_STATUS.INSUFFICIENT
    : STAPLE_STATUS.SUFFICIENT;
  return { status, updatedAt: (entry && entry.updatedAt) || null };
}

function writeStaple(canonical, status) {
  const map = loadStaples();
  map[canonical] = { status, updatedAt: new Date().toISOString() };
  saveStaples(map);
  return map[canonical];
}

// 移除某常备品仍未购买（未勾选）的清单项。
function removeOpenStapleShoppingItem(canonical) {
  const items = loadShoppingItems();
  const kept = items.filter(it => !(it.name === canonical && it.source === STAPLE_SOURCE && !it.done));
  if (kept.length !== items.length) saveShoppingItems(kept);
}

export function setStapleStatus(name, status) {
  const c = getCanonicalName(name || '');
  if (!c) return null;
  const next = status === STAPLE_STATUS.INSUFFICIENT ? STAPLE_STATUS.INSUFFICIENT : STAPLE_STATUS.SUFFICIENT;
  const entry = writeStaple(c, next);
  if (next === STAPLE_STATUS.INSUFFICIENT) {
    addShoppingItem(c, '', '', STAPLE_SOURCE); // 自动加入购物清单
  } else {
    removeOpenStapleShoppingItem(c); // 恢复充足时清掉未买的清单项
  }
  return entry;
}

export function toggleStaple(name) {
  const current = getStapleState(name).status;
  const next = current === STAPLE_STATUS.SUFFICIENT ? STAPLE_STATUS.INSUFFICIENT : STAPLE_STATUS.SUFFICIENT;
  return setStapleStatus(name, next);
}

// 采购闭环：购物清单中某常备品被勾选「已买」/「入库」时调用，恢复充足并更新库存时间。
// 返回 true 表示该名称确为常备品且已恢复。
export function restoreStapleByPurchase(name) {
  const c = getCanonicalName(name || '');
  if (!c) return false;
  if (!STAPLE_NAMES.has(c) && !loadStaples()[c] && !isConfiguredStaple(c)) return false;
  writeStaple(c, STAPLE_STATUS.SUFFICIENT);
  return true;
}

// 批量恢复（供「全部标记已买」/「逐项入库」使用）。
export function restoreStaplesByPurchase(names) {
  let count = 0;
  for (const name of (names || [])) {
    if (restoreStapleByPurchase(name)) count++;
  }
  return count;
}
