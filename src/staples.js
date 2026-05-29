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

import { S } from './storage.js?v=163';
import { getCanonicalName } from './ingredients.js?v=163';
import { addShoppingItem, loadShoppingItems, saveShoppingItems } from './shopping.js?v=163';

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

const STAPLE_NAMES = new Set();
STAPLE_CATALOG.forEach(group => group.items.forEach(name => STAPLE_NAMES.add(getCanonicalName(name))));

export function isStaple(name) {
  return STAPLE_NAMES.has(getCanonicalName(name || ''));
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
  if (!STAPLE_NAMES.has(c) && !loadStaples()[c]) return false;
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
