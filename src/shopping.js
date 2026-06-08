import { S, todayISO } from './storage.js?v=219';
import {
  getCanonicalName,
  getDryPrepText,
  guessKitchenUnit,
  guessShelfDays,
  isDryGoodName,
  normalizeReceiptIngredientName,
  normalizeKitchenAmount
} from './ingredients.js?v=219';

export function genId(){
  return 'u-' + Math.random().toString(36).slice(2,8) + '-' + Date.now().toString(36).slice(-4);
}

// 已完成（已买 / 已入库）购物项在默认清单里的可见时长：完成后 24 小时内仍展示在「最近完成」，
// 超过后默认隐藏（仅隐藏，不删除数据，保证最安全）。
export const COMPLETED_SHOPPING_VISIBLE_HOURS = 24;

// 「完成」= 已买(done) 或 已入库(stockedIn)。
export function isShoppingItemCompleted(item) {
  return !!(item && (item.done || item.stockedIn));
}

// 完成时间：优先 completedAt，回退入库时间 stockedInAt（历史数据兜底）。
export function getCompletedAt(item) {
  return (item && (item.completedAt || item.stockedInAt)) || null;
}

// 是否应从默认清单隐藏：已完成 + 有完成时间 + 距今已超过可见时长。
// 没有完成时间的（异常历史数据）一律保留，避免误隐藏。
export function shouldHideCompletedShoppingItem(item, now = Date.now(), hours = COMPLETED_SHOPPING_VISIBLE_HOURS) {
  if (!isShoppingItemCompleted(item)) return false;
  const completedAt = getCompletedAt(item);
  if (!completedAt) return false;
  const ts = Date.parse(completedAt);
  if (!Number.isFinite(ts)) return false;
  const ms = (Number(hours) || COMPLETED_SHOPPING_VISIBLE_HOURS) * 60 * 60 * 1000;
  return (now - ts) > ms;
}

// 默认清单可见项：未完成全部保留；已完成仅保留「最近 N 小时内」（可关闭）。
export function getVisibleShoppingItems(items, options = {}) {
  const {
    includeRecentlyCompleted = true,
    completedVisibleHours = COMPLETED_SHOPPING_VISIBLE_HOURS,
    now = Date.now()
  } = options;
  return (items || []).filter(item => {
    if (!isShoppingItemCompleted(item)) return true;
    if (!includeRecentlyCompleted) return false;
    return !shouldHideCompletedShoppingItem(item, now, completedVisibleHours);
  });
}

function cleanSource(source) {
  const text = String(source || '').trim();
  if (!text || text === '鎵嬪姩') return '手动';
  return text;
}

function parseQty(value) {
  if (value === '' || value === null || value === undefined) return null;
  const n = Number(value);
  return Number.isFinite(n) ? n : null;
}

function formatQty(value) {
  const n = Number(value);
  if (!Number.isFinite(n)) return '';
  return Math.round(n * 100) / 100;
}

function amountText(qty, unit) {
  const q = qty === '' || qty === null || qty === undefined ? '' : String(qty);
  const u = String(unit || '').trim();
  if (q && u) return `${q} ${u}`;
  return q || u || '';
}

function classifyShoppingSource(item) {
  const source = cleanSource(item.source);
  const sources = Array.isArray(item.sources) ? item.sources : source.split('、').filter(Boolean);
  const sourceText = sources.join('、');
  if (sourceText.includes('常备干货')) return '常备干货';
  if (sourceText.includes('日常补给')) return '日常补给';
  if (sourceText.includes('常备品')) return '常备品';
  if (sourceText.includes('今日计划') || sourceText.includes('菜谱缺货') || sourceText.includes('菜谱')) return '今日计划 / 菜谱缺货';
  if (sources.some(itemSource => itemSource && !['手动', '其他'].includes(itemSource))) return '今日计划 / 菜谱缺货';
  if (sourceText.includes('手动')) return '手动';
  return '其他';
}

let isNormalizing = false;

export function loadShoppingItems() {
  const rawItems = S.load(S.keys.shopping_items, []);
  if (!Array.isArray(rawItems)) {
    return [];
  }

  let needsSave = false;
  const cleanedItems = [];

  for (const item of rawItems) {
    if (!item || !item.name) {
      needsSave = true;
      continue;
    }

    const canonicalName = getCanonicalName(String(item.name || '').trim());
    if (!canonicalName) {
      needsSave = true;
      continue;
    }

    const normalizedId = item.id || genId();
    if (!item.id) {
      needsSave = true;
    }

    const normalizedQty = item.qty ?? '';
    if (item.qty !== normalizedQty) {
      needsSave = true;
    }

    const normalizedUnit = item.unit || '';
    if (item.unit !== normalizedUnit) {
      needsSave = true;
    }

    const normalizedSource = cleanSource(item.source);
    if (item.source !== normalizedSource) {
      needsSave = true;
    }

    const normalizedDone = !!item.done;
    if (item.done !== normalizedDone) {
      needsSave = true;
    }

    const normalizedStockedIn = !!item.stockedIn;
    if (item.stockedIn !== normalizedStockedIn) {
      needsSave = true;
    }

    const normalizedStockedInAt = item.stockedInAt || null;

    // 备注（手动添加 / 行内就地编辑）：必须在归一化重建对象时保留，否则刷新即丢失。
    const normalizedRemark = typeof item.remark === 'string' ? item.remark : '';

    // 完成时间 completedAt：用于「已完成 24h 后自动隐藏」。
    //   - 保留已有 completedAt（不重置，避免缓冲期被刷新）。
    //   - 安全回填：历史 done/stockedIn 但缺 completedAt 的项，回填一个时间给它 24h 缓冲（绝不立即删）。
    //     优先沿用 stockedInAt，否则记为当前时间。
    //   - 未完成项强制清空 completedAt，保持状态一致。
    let normalizedCompletedAt = (typeof item.completedAt === 'string' && item.completedAt) ? item.completedAt : null;
    const isCompleted = normalizedDone || normalizedStockedIn;
    if (isCompleted && !normalizedCompletedAt) {
      normalizedCompletedAt = normalizedStockedInAt || new Date().toISOString();
      needsSave = true;
    } else if (!isCompleted && normalizedCompletedAt) {
      normalizedCompletedAt = null;
      needsSave = true;
    }

    cleanedItems.push({
      id: normalizedId,
      name: canonicalName,
      qty: normalizedQty,
      unit: normalizedUnit,
      source: normalizedSource,
      done: normalizedDone,
      stockedIn: normalizedStockedIn,
      stockedInAt: normalizedStockedInAt,
      completedAt: normalizedCompletedAt,
      remark: normalizedRemark
    });
  }

  if (needsSave && !isNormalizing) {
    isNormalizing = true;
    try {
      saveShoppingItems(cleanedItems);
    } finally {
      isNormalizing = false;
    }
  }

  return cleanedItems;
}

export function saveShoppingItems(items) {
  return S.save(S.keys.shopping_items, items.filter(item => item && item.name));
}

export function mergeShoppingItems(items) {
  const map = new Map();
  for (const raw of items || []) {
    if (!raw || !raw.name) continue;
    const name = getCanonicalName(raw.name);
    if (!name) continue;
    const unit = raw.unit || '';
    const done = !!raw.done;
    const stockedIn = !!raw.stockedIn;
    // Include stockedIn in key so partially-stocked groups are never merged together
    const key = `${name}|${unit}|${done ? 'done' : 'open'}|${stockedIn ? 'stocked' : 'unstocked'}`;
    const source = cleanSource(raw.source);
    const qty = parseQty(raw.qty);

    if (!map.has(key)) {
      map.set(key, {
        id: raw.id || genId(),
        ids: raw.id ? [raw.id] : [],
        name,
        qty: qty === null ? (raw.qty || '') : qty,
        unit,
        source,
        sources: source ? [source] : [],
        done,
        stockedIn,
        stockedInAt: raw.stockedInAt || null,
        completedAt: getCompletedAt(raw),
        remark: (typeof raw.remark === 'string' ? raw.remark : ''),
        rawItems: [raw],
        canSumQty: qty !== null
      });
      continue;
    }

    const item = map.get(key);
    if (raw.id && !item.ids.includes(raw.id)) item.ids.push(raw.id);
    if (source && !item.sources.includes(source)) item.sources.push(source);
    item.source = item.sources.join('、');
    // 合并行的备注：取第一个有备注的底层项展示。
    if (!item.remark && typeof raw.remark === 'string' && raw.remark) item.remark = raw.remark;
    // 合并行的完成时间：取最新（最晚），让整组在最后一次完成满 24h 后才隐藏。
    const rawCompletedAt = getCompletedAt(raw);
    if (rawCompletedAt && (!item.completedAt || Date.parse(rawCompletedAt) > Date.parse(item.completedAt))) {
      item.completedAt = rawCompletedAt;
    }
    item.rawItems.push(raw);

    if (item.canSumQty && qty !== null) {
      item.qty = formatQty((Number(item.qty) || 0) + qty);
    } else if (qty !== null && (item.qty === '' || item.qty === null || item.qty === undefined)) {
      item.qty = qty;
    } else if (qty === null) {
      item.canSumQty = false;
    }
  }

  return Array.from(map.values()).map(item => ({
    ...item,
    qty: item.canSumQty ? formatQty(item.qty) : (item.qty || ''),
    amountText: amountText(item.canSumQty ? formatQty(item.qty) : item.qty, item.unit)
  }));
}

export function groupShoppingItemsBySource(items) {
  const labels = ['今日计划 / 菜谱缺货', '手动', '常备品', '常备干货', '日常补给', '其他'];
  const groups = labels.map(label => ({ label, items: [] }));
  for (const item of items || []) {
    const label = classifyShoppingSource(item);
    const group = groups.find(g => g.label === label) || groups[groups.length - 1];
    group.items.push(item);
  }
  return groups.filter(group => group.items.length);
}

function formatShoppingLine(item, sourceOverride = '') {
  const amount = amountText(item.qty, item.unit);
  const source = sourceOverride || item.source || (item.sources || []).join('、');
  const suffix = source ? `（${source}）` : '';
  return `- ${item.name}${amount ? ` ${amount}` : ''}${suffix}`;
}

export function buildCopyableShoppingList(missing, items) {
  const lines = [];
  const missingItems = (missing || []).filter(item => item && item.name);
  if (missingItems.length) {
    lines.push('今日计划缺货：');
    missingItems.forEach(item => {
      lines.push(formatShoppingLine(item, item.source || '菜谱'));
    });
  }

  const activeItems = mergeShoppingItems((items || []).filter(item => !item.done));
  const groups = groupShoppingItemsBySource(activeItems);
  groups.forEach(group => {
    if (lines.length) lines.push('');
    lines.push(`${group.label}：`);
    group.items.forEach(item => lines.push(formatShoppingLine(item, item.source)));
  });

  return lines.join('\n');
}

export function markAllShoppingItemsDone() {
  const now = new Date().toISOString();
  // 新变成已买的项写入 completedAt（启动 24h 隐藏倒计时）；已有 completedAt 的保留不动。
  const items = loadShoppingItems().map(item => ({
    ...item,
    done: true,
    completedAt: item.completedAt || now
  }));
  saveShoppingItems(items);
  return items;
}

export function clearDoneShoppingItems() {
  const items = loadShoppingItems().filter(item => !item.done);
  saveShoppingItems(items);
  return items;
}

// ── 按 id 修改单个购物项的完成状态（供视图 / 首页弹窗复用，统一维护 completedAt）──
function updateShoppingItemById(id, updater) {
  const items = loadShoppingItems().map(it => it.id === id ? updater({ ...it }) : it);
  saveShoppingItems(items);
}

// 标记为已买 / 已完成：设 done=true 并写完成时间（已有则保留）。
export function markShoppingItemCompleted(id) {
  const now = new Date().toISOString();
  updateShoppingItemById(id, it => ({ ...it, done: true, completedAt: it.completedAt || now }));
}

// 取消完成：回到待购买，清空完成 / 入库状态与时间。
export function markShoppingItemActive(id) {
  updateShoppingItemById(id, it => ({ ...it, done: false, stockedIn: false, completedAt: null }));
}

// 标记为已入库：done + stockedIn + 入库时间 + 完成时间。
export function markShoppingItemStocked(id) {
  const now = new Date().toISOString();
  updateShoppingItemById(id, it => ({
    ...it,
    done: true,
    stockedIn: true,
    stockedInAt: it.stockedInAt || now,
    completedAt: it.completedAt || now
  }));
}

export function convertShoppingItemToInventory(item, options = {}) {
  const name = getCanonicalName(options.name || item.name || '');
  const qtyValue = options.qty ?? item.qty;
  let qty = String(qtyValue ?? '').trim() === '' ? 1 : Number(qtyValue);
  if (!Number.isFinite(qty)) qty = 1;
  if (qty < 0) qty = 0;
  const unit = options.unit || item.unit || guessKitchenUnit(name) || '份';
  const kind = options.kind || (isDryGoodName(name) ? 'dry' : 'raw');
  const buyDate = options.buyDate || todayISO();
  const isFrozen = kind === 'dry' ? false : !!options.isFrozen;
  const shelf = Number(options.shelf) || (kind === 'dry' ? 365 : guessShelfDays(name, unit));

  return {
    name,
    qty,
    unit,
    buyDate,
    kind,
    shelf,
    isFrozen,
    stockStatus: 'ok',
    ...(kind === 'dry' ? { dryPrep: getDryPrepText(name) } : {})
  };
}

export function addShoppingItem(name, qty = '', unit = '', source = '手动', remark = '') {
  const cleanName = getCanonicalName(name || '');
  if(!cleanName) return;
  const cleanUnit = unit || '';
  const cleanItemSource = cleanSource(source);
  const cleanRemark = String(remark || '').trim();
  const items = loadShoppingItems();
  const existing = items.find(item => item.name === cleanName && item.unit === cleanUnit && item.source === cleanItemSource && !item.done);
  if(existing) {
    const oldQty = parseQty(existing.qty);
    const nextQty = parseQty(qty);
    if (oldQty !== null && nextQty !== null) existing.qty = formatQty(oldQty + nextQty);
    else existing.qty = existing.qty || qty || '';
    if (cleanRemark) existing.remark = cleanRemark; // 新备注覆盖（仅在填写时）
  } else {
    items.push({ id: genId(), name: cleanName, qty: qty || '', unit: cleanUnit, source: cleanItemSource, done: false, remark: cleanRemark });
  }
  saveShoppingItems(items);
}

// ──────────────────────────────────────────────────────────────────────────
// 待买速记：文本批量解析（纯本地，无 AI / 无后端）。
//   一行一个购物项；支持「名 数量单位」「名 数量 单位」「名*数量」「名 x 数量」「名×数量」，
//   简单中文数字（一二两三四五…半），以及中英文逗号 / 顿号 / 分号在一行内拆多项。
// ──────────────────────────────────────────────────────────────────────────
const CN_NUM = { 一: 1, 二: 2, 两: 2, 三: 3, 四: 4, 五: 5, 六: 6, 七: 7, 八: 8, 九: 9, 十: 10, 半: 0.5 };

function noteQtyToken(tok) {
  if (tok == null) return null;
  const t = String(tok).trim();
  if (t === '') return null;
  if (/^\d+(?:\.\d+)?$/.test(t)) { const n = Number(t); return Number.isFinite(n) ? n : null; }
  if (CN_NUM[t] != null) return CN_NUM[t];
  return null;
}

// 解析单个片段（已按分隔符拆好）。无法识别出有效名称时返回 null。
function parseShoppingNoteSegment(seg) {
  let s = String(seg || '').trim();
  if (!s) return null;
  s = s.replace(/^[-•·]\s*/, '').trim(); // 去掉可能粘贴进来的行首项目符号
  if (!s) return null;

  let name = s, qty = null, unit = '';

  // ① 名 *|x|× 数量 [单位]：土豆*3 / 苹果 x 4 / 牛奶×2瓶
  let m = s.match(/^(.+?)\s*[*xX×]\s*(\d+(?:\.\d+)?|[一二两三四五六七八九十半])\s*([^\d\s]*)$/);
  if (m) {
    name = m[1]; qty = noteQtyToken(m[2]); unit = (m[3] || '').trim();
  } else {
    // ② 名 数字 [单位]：鸡蛋 1盒 / 牛奶 2 瓶 / 鸡蛋 6 / 西红柿3个（无空格）
    m = s.match(/^(.+?)\s*(\d+(?:\.\d+)?)\s*([^\d\s]*)$/);
    if (m) {
      name = m[1]; qty = Number(m[2]); unit = (m[3] || '').trim();
    } else {
      // ③ 名 <空格> 中文数字 [单位]：豆腐 一块 / 排骨 两份 / 葱 半
      //    必须有空格分隔，避免把「十三香」「三鲜」等名字里的字误当数量。
      m = s.match(/^(.+?)\s+([一二两三四五六七八九十半])\s*([^\d\s]*)$/);
      if (m) { name = m[1]; qty = CN_NUM[m[2]]; unit = (m[3] || '').trim(); }
    }
  }

  name = String(name).trim();
  if (!name) return null;
  if (qty == null || !Number.isFinite(qty) || qty <= 0) qty = 1;
  return { name, qty, unit };
}

/**
 * 解析「待买速记」批量文本。
 * @param {string} text
 * @returns {{ items: Array<{name:string, qty:number, unit:string}>, skipped:number }}
 */
export function parseShoppingNoteText(text) {
  const items = [];
  let skipped = 0;
  const lines = String(text || '').split(/\r?\n/);
  for (const rawLine of lines) {
    const line = rawLine.trim();
    if (!line) continue; // 空行忽略，不计入 skipped
    const segments = line.split(/[，,、;；]+/).map(x => x.trim()).filter(Boolean);
    for (const seg of segments) {
      const parsed = parseShoppingNoteSegment(seg);
      if (parsed) items.push(parsed);
      else skipped++;
    }
  }
  return { items, skipped };
}

/**
 * 解析文本并批量写入购物清单（复用 addShoppingItem，自动合并同名同单位未完成项）。
 * @param {string} text
 * @param {string} [source='速记']
 * @returns {{ added:number, skipped:number, items:Array }}
 */
export function addShoppingItemsFromText(text, source = '速记') {
  const { items, skipped } = parseShoppingNoteText(text);
  for (const it of items) {
    addShoppingItem(it.name, it.qty, it.unit, source);
  }
  return { added: items.length, skipped, items };
}

function isQtyClose(q1, q2) {
  const num1 = parseFloat(q1);
  const num2 = parseFloat(q2);
  if (!isFinite(num1) || !isFinite(num2)) return false;
  if (num1 <= 0 || num2 <= 0) return false;
  if (num1 === num2) return true;
  const diff = Math.abs(num1 - num2);
  const max = Math.max(num1, num2);
  return (diff / max <= 0.2) || (diff <= 0.2);
}

export function matchReceiptItemsToShoppingItems(receiptItems, shoppingItems) {
  const openShoppingItems = (shoppingItems || []).filter(item => !item.done);
  const matchedShoppingIds = new Set();
  
  const results = receiptItems.map(item => {
    return {
      receiptItem: item,
      match: null
    };
  });

  // Pass 1: Exact unit match
  for (const res of results) {
    const rItem = res.receiptItem;
    const normReceipt = normalizeKitchenAmount(rItem.name, rItem.qty, rItem.unit, { source: 'receipt' });
    
    const matchItem = openShoppingItems.find(sItem => {
      if (matchedShoppingIds.has(sItem.id)) return false;
      const normShop = normalizeKitchenAmount(sItem.name, sItem.qty, sItem.unit);
      return normReceipt.name === normShop.name && normReceipt.unit === normShop.unit;
    });

    if (matchItem) {
      matchedShoppingIds.add(matchItem.id);
      const normShop = normalizeKitchenAmount(matchItem.name, matchItem.qty, matchItem.unit);
      const qtyClose = isQtyClose(normReceipt.qty, normShop.qty);
      res.match = {
        shoppingItem: matchItem,
        type: 'exact',
        confidence: qtyClose ? 'high' : 'low'
      };
    }
  }

  // Pass 2: Unit mismatch match
  for (const res of results) {
    if (res.match) continue;
    
    const rItem = res.receiptItem;
    const normReceipt = normalizeKitchenAmount(rItem.name, rItem.qty, rItem.unit, { source: 'receipt' });

    const matchItem = openShoppingItems.find(sItem => {
      if (matchedShoppingIds.has(sItem.id)) return false;
      const normShop = normalizeKitchenAmount(sItem.name, sItem.qty, sItem.unit);
      return normReceipt.name === normShop.name;
    });

    if (matchItem) {
      matchedShoppingIds.add(matchItem.id);
      res.match = {
        shoppingItem: matchItem,
        type: 'needsConfirm',
        confidence: 'low'
      };
    }
  }

  return results;
}

export function markShoppingItemsStockedIn(ids) {
  if (!ids || ids.length === 0) return;
  const idSet = new Set(ids);
  const now = new Date().toISOString();
  const items = loadShoppingItems().map(item => {
    if (idSet.has(item.id)) {
      return {
        ...item,
        done: true,
        stockedIn: true,
        stockedInAt: now,
        completedAt: item.completedAt || now
      };
    }
    return item;
  });
  saveShoppingItems(items);
}
