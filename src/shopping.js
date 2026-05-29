import { S, todayISO } from './storage.js?v=171';
import {
  getCanonicalName,
  getDryPrepText,
  guessKitchenUnit,
  guessShelfDays,
  isDryGoodName,
  normalizeReceiptIngredientName,
  normalizeKitchenAmount
} from './ingredients.js?v=171';

export function genId(){
  return 'u-' + Math.random().toString(36).slice(2,8) + '-' + Date.now().toString(36).slice(-4);
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

    cleanedItems.push({
      id: normalizedId,
      name: canonicalName,
      qty: normalizedQty,
      unit: normalizedUnit,
      source: normalizedSource,
      done: normalizedDone,
      stockedIn: normalizedStockedIn,
      stockedInAt: normalizedStockedInAt
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
        rawItems: [raw],
        canSumQty: qty !== null
      });
      continue;
    }

    const item = map.get(key);
    if (raw.id && !item.ids.includes(raw.id)) item.ids.push(raw.id);
    if (source && !item.sources.includes(source)) item.sources.push(source);
    item.source = item.sources.join('、');
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
  const items = loadShoppingItems().map(item => ({ ...item, done: true }));
  saveShoppingItems(items);
  return items;
}

export function clearDoneShoppingItems() {
  const items = loadShoppingItems().filter(item => !item.done);
  saveShoppingItems(items);
  return items;
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

export function addShoppingItem(name, qty = '', unit = '', source = '手动') {
  const cleanName = getCanonicalName(name || '');
  if(!cleanName) return;
  const cleanUnit = unit || '';
  const cleanItemSource = cleanSource(source);
  const items = loadShoppingItems();
  const existing = items.find(item => item.name === cleanName && item.unit === cleanUnit && item.source === cleanItemSource && !item.done);
  if(existing) {
    const oldQty = parseQty(existing.qty);
    const nextQty = parseQty(qty);
    if (oldQty !== null && nextQty !== null) existing.qty = formatQty(oldQty + nextQty);
    else existing.qty = existing.qty || qty || '';
  } else {
    items.push({ id: genId(), name: cleanName, qty: qty || '', unit: cleanUnit, source: cleanItemSource, done: false });
  }
  saveShoppingItems(items);
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
  const items = loadShoppingItems().map(item => {
    if (idSet.has(item.id)) {
      return {
        ...item,
        done: true,
        stockedIn: true,
        stockedInAt: new Date().toISOString()
      };
    }
    return item;
  });
  saveShoppingItems(items);
}
