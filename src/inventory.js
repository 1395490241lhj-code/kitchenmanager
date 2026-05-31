import { S, todayISO } from './storage.js?v=185';
import {
  INGREDIENT_ALIASES,
  getCanonicalName,
  getDryGoodConfig,
  getDryPrepText,
  guessShelfDays,
  isDryGoodName
} from './ingredients.js?v=185';

export const RECIPE_GENERIC_MATCHES = {
  "猪肉": ["五花肉", "瘦肉"],
  "鸡肉": ["鸡腿", "鸡翅", "鸡脯肉"],
  "鲜鱼": ["鲫鱼", "鲤鱼", "草鱼", "鲢鱼"],
  "虾": ["虾仁"],
  "蘑菇": ["香菇", "口蘑"]
};

export const INVENTORY_STATES = [
  { value: 'ok', label: '够用', className: 'ok' },
  { value: 'low', label: '快没了', className: 'low' },
  { value: 'empty', label: '没有', className: 'empty' },
  { value: 'unknown', label: '不确定', className: 'unknown' }
];

export function getIngredientMatchNames(name) {
  const canonical = getCanonicalName(name || '');
  const names = new Set([canonical]);
  const aliases = INGREDIENT_ALIASES[canonical] || [];
  aliases.forEach(alias => names.add(getCanonicalName(alias)));
  (RECIPE_GENERIC_MATCHES[canonical] || []).forEach(item => names.add(getCanonicalName(item)));
  return Array.from(names).filter(Boolean);
}

export function isIngredientMatch(recipeName, stockName) {
  const recipeCanonical = getCanonicalName(recipeName || '');
  const stockCanonical = getCanonicalName(stockName || '');
  if (!recipeCanonical || !stockCanonical) return false;
  if (recipeCanonical === stockCanonical) return true;
  const recipeNames = getIngredientMatchNames(recipeCanonical);
  const stockNames = getIngredientMatchNames(stockCanonical);
  if (recipeNames.some(name => stockNames.includes(name))) return true;
  const recipeSpecifics = (RECIPE_GENERIC_MATCHES[recipeCanonical] || []).map(item => getCanonicalName(item));
  const stockSpecifics = (RECIPE_GENERIC_MATCHES[stockCanonical] || []).map(item => getCanonicalName(item));
  if (recipeSpecifics.includes(stockCanonical) || stockSpecifics.includes(recipeCanonical)) return true;
  if (recipeCanonical.length >= 2 && stockCanonical.length >= 2) {
    return recipeCanonical.includes(stockCanonical) || stockCanonical.includes(recipeCanonical);
  }
  return false;
}

export function isInventoryAvailable(item) {
  return item && item.stockStatus !== 'empty' && (+item.qty || 0) > 0;
}

export function findInventoryMatch(inv, recipeName) {
  return (inv || []).find(item => isInventoryAvailable(item) && isIngredientMatch(recipeName, item.name));
}

export function getMatchingInventoryItems(inv, recipeName) {
  return (inv || []).filter(item => item && item.stockStatus !== 'empty' && isIngredientMatch(recipeName, item.name));
}

/**
 * 分析库存对某食材需求的覆盖情况，返回置信度。
 *
 * @param {Array}  inv        - 当前库存数组
 * @param {string} recipeName - 菜谱中食材名称
 * @param {number} qty        - 菜谱中需要的数量
 * @param {string} unit       - 菜谱中需要的单位
 * @returns {{
 *   coveredQty: number,
 *   confidence: 'exact'|'unit-mismatch'|'status-only'|'none',
 *   matchedItems: Array
 * }}
 *
 * confidence 含义：
 *   exact        — 同名/别名匹配且单位一致，可精确比较数量
 *   unit-mismatch — 同名匹配但单位不同，无法直接比较
 *   status-only  — 找到同名但无可比数量（qty=0 而 stockStatus=ok），只能说"可能有"
 *   none         — 无匹配
 */
export function getStockCoverageAnalysis(inv, recipeName, qty, unit) {
  const matchedItems = getMatchingInventoryItems(inv, recipeName);
  if (!matchedItems.length) {
    return { coveredQty: 0, confidence: 'none', matchedItems: [] };
  }

  // 1. 同名且单位相同 → exact
  const sameUnitItems = matchedItems.filter(item => (item.unit || '') === (unit || ''));
  const sameUnitTotal = sameUnitItems.reduce((sum, item) => sum + (+item.qty || 0), 0);
  if (sameUnitTotal > 0) {
    return { coveredQty: sameUnitTotal, confidence: 'exact', matchedItems: sameUnitItems };
  }

  // 2. 同名但单位不同，且有实际数量 → unit-mismatch
  const differentUnitWithQty = matchedItems.filter(
    item => (item.unit || '') !== (unit || '') && (+item.qty || 0) > 0
  );
  if (differentUnitWithQty.length > 0) {
    return { coveredQty: 0, confidence: 'unit-mismatch', matchedItems: differentUnitWithQty };
  }

  // 3. 找到同名但 qty 为 0，stockStatus=ok → status-only（可能有货但数量未填）
  const statusOkItems = matchedItems.filter(item => (item.stockStatus || 'ok') === 'ok');
  if (statusOkItems.length > 0) {
    return { coveredQty: 0, confidence: 'status-only', matchedItems: statusOkItems };
  }

  return { coveredQty: 0, confidence: 'none', matchedItems: [] };
}

/**
 * 向后兼容包装：内部委托给 getStockCoverageAnalysis。
 * 旧行为：unit-mismatch / status-only 均视为"够用"（返回 qty），不影响现有调用方。
 * 新调用方应直接使用 getStockCoverageAnalysis 以获取置信度信息。
 */
export function getStockCoverageForNeed(inv, recipeName, qty, unit) {
  const analysis = getStockCoverageAnalysis(inv, recipeName, qty, unit);
  if (analysis.confidence === 'exact') return analysis.coveredQty;
  // unit-mismatch / status-only：保持旧行为，视为"刚好够用"
  if (analysis.confidence !== 'none') return +qty || 1;
  return 0;
}

export function inventoryStateInfo(value) {
  return INVENTORY_STATES.find(s => s.value === value) || INVENTORY_STATES[0];
}

export function nextInventoryState(value) {
  const index = INVENTORY_STATES.findIndex(s => s.value === value);
  return INVENTORY_STATES[(index + 1) % INVENTORY_STATES.length].value;
}

export function findStockItem(inv, name, kind = '') {
  return (inv || []).find(entry => isIngredientMatch(name, entry.name) && (!kind || (entry.kind || 'raw') === kind));
}

export function formatInventoryAmount(item) {
  const qty = Number(item.qty);
  if (!isFinite(qty) || qty <= 0) return '未填数量';
  return `${qty}${item.unit || ''}`;
}

export function formatStockLine(item, unit = '份') {
  if(!item || item.stockStatus === 'empty' || (+item.qty || 0) <= 0) return '库存：没有';
  const amount = formatInventoryAmount({...item, unit: item.unit || unit});
  const state = inventoryStateInfo(item.stockStatus).label;
  return `库存：${amount} · ${state}`;
}

export function ensureStockItem(inv, config, kind = 'raw', status = 'empty') {
  let item = findStockItem(inv, config.name, kind);
  if(!item) {
    item = { name: config.name, qty: status === 'empty' ? 0 : 1, unit: config.unit, buyDate: todayISO(), kind, shelf: kind === 'dry' ? 365 : guessShelfDays(config.name, config.unit), stockStatus: status };
    if(kind === 'dry') item.dryPrep = config.prep || getDryPrepText(config.name);
    inv.push(item);
  }
  return item;
}

export function loadInventory(catalog){
  const inv=S.load(S.keys.inventory,[]);
  for(const i of inv){
    if(!i.unit){i.unit=(catalog.find(c=>c.name===i.name)?.unit)||'g'}
    if(!i.shelf){i.shelf=(catalog.find(c=>c.name===i.name)?.shelf)||7}
    if(!i.stockStatus){i.stockStatus='ok'}
    if(isDryGoodName(i.name)){
      i.kind = 'dry';
      i.unit = i.unit || getDryGoodConfig(i.name)?.unit || '包';
      i.shelf = i.shelf && i.shelf > 180 ? i.shelf : 365;
      i.dryPrep = i.dryPrep || getDryPrepText(i.name);
      i.isFrozen = false;
    }
  }
  return inv;
}

export function saveInventory(inv){ S.save(S.keys.inventory, inv); }
export function daysBetween(a,b){ return Math.floor((new Date(b)-new Date(a))/86400000); }
export function remainingDays(e){ const age=daysBetween(e.buyDate||todayISO(), todayISO()); const shelf = (e.shelf === undefined || e.shelf === null || e.shelf === '') ? 7 : +e.shelf; return shelf-age; }

/**
 * 合并入库核心函数。
 * @param {Array} inv       - 当前库存数组（会被就地修改）
 * @param {Object} entry    - 要入库的条目 { name, qty, unit, kind, ... }
 * @param {Object} [options]
 * @param {'add'|'replace'|'newBatch'} [options.mode='add']
 *   add      - 同名同单位同类型累加数量（单位不同时退化为 newBatch）
 *   replace  - 同名同类型直接覆盖（保持旧 upsertInventory 行为）
 *   newBatch - 不论是否重名，始终新增一条
 * @param {boolean} [options.save=true] - 是否立即持久化
 */
export function mergeInventoryEntry(inv, entry, { mode = 'add', save = true } = {}) {
  if (mode === 'newBatch') {
    inv.push({ ...entry });
  } else if (mode === 'replace') {
    // 与旧 upsertInventory 等价：按名称+类型查找，存在则覆盖，否则新增
    const idx = inv.findIndex(
      x => x.name === entry.name && (x.kind || 'raw') === (entry.kind || 'raw')
    );
    if (idx >= 0) inv[idx] = { ...inv[idx], ...entry };
    else inv.push({ ...entry });
  } else {
    // mode === 'add'（默认）
    const entryKind = entry.kind || 'raw';
    const entryUnit = entry.unit || '';
    // 先尝试完整匹配：名称 + 单位 + 类型
    const exact = inv.find(
      x => x.name === entry.name
        && (x.kind || 'raw') === entryKind
        && (x.unit || '') === entryUnit
    );
    if (exact) {
      // 单位相同 → 累加
      exact.qty = (+exact.qty || 0) + (+entry.qty || 0);
      // 更新其余字段（保留旧的 buyDate 以免刷新保质期）
      if (entry.stockStatus) exact.stockStatus = entry.stockStatus;
      if (entry.isFrozen !== undefined) exact.isFrozen = entry.isFrozen;
      if (entryKind === 'dry') {
        exact.shelf = 365;
        exact.dryPrep = getDryPrepText(entry.name);
        exact.isFrozen = false;
      }
    } else {
      // 名称相同但单位不同（或尚未存在）→ 新增批次
      inv.push({ ...entry });
    }
  }
  if (save) saveInventory(inv);
}

/** 向后兼容：保持旧调用方（编辑弹窗等）的覆盖行为 */
export function upsertInventory(inv, e) {
  mergeInventoryEntry(inv, e, { mode: 'replace' });
}

/**
 * 按配方扣减库存（做完菜之后调用）。
 * @param {Array} inv - 库存数组（就地修改）
 * @param {Array<{name:string, qty:number, unit:string, allowMismatch:boolean}>} deductions - 要扣减的食材列表
 * @returns {{
 *   deducted: Array<{name:string, qty:number, unit:string}>,
 *   skipped: Array<{name:string, qty:number, unit:string, reason: 'unit-mismatch'|'no-stock'}>
 * }}
 */
export function deductInventoryForRecipe(inv, deductions) {
  const result = {
    deducted: [],
    skipped: []
  };

  for (const deduction of (deductions || [])) {
    const { name, qty, unit, allowMismatch } = deduction;
    if (!name || !(+qty > 0)) continue;

    let remaining = +qty;
    
    // 找所有匹配该食材且数量 > 0 且状态非 empty 的可用库存批次
    const matched = (inv || [])
      .filter(x => isIngredientMatch(name, x.name) && (+x.qty || 0) > 0 && x.stockStatus !== 'empty');

    if (matched.length === 0) {
      result.skipped.push({ name, qty, unit, reason: 'no-stock' });
      continue;
    }

    // 区分同单位批次与不同单位批次
    const sameUnit = matched.filter(x => (x.unit || '') === (unit || ''));
    const diffUnit = matched.filter(x => (x.unit || '') !== (unit || ''));

    // 按保质期快到期排序
    sameUnit.sort((a, b) => remainingDays(a) - remainingDays(b));
    diffUnit.sort((a, b) => remainingDays(a) - remainingDays(b));

    let deductedAmt = 0;

    // 优先扣同单位库存
    for (const batch of sameUnit) {
      if (remaining <= 0) break;
      const available = +batch.qty || 0;
      const take = Math.min(available, remaining);
      batch.qty = Math.max(0, available - take);
      remaining -= take;
      deductedAmt += take;
      if (batch.qty <= 0) {
        batch.qty = 0;
        batch.stockStatus = 'empty';
      }
    }

    // 如果还有剩余未扣，且明确允许跨单位扣减，则扣减不同单位库存
    if (remaining > 0 && allowMismatch) {
      for (const batch of diffUnit) {
        if (remaining <= 0) break;
        const available = +batch.qty || 0;
        const take = Math.min(available, remaining);
        batch.qty = Math.max(0, available - take);
        remaining -= take;
        deductedAmt += take;
        if (batch.qty <= 0) {
          batch.qty = 0;
          batch.stockStatus = 'empty';
        }
      }
    }

    // 记录结果
    if (deductedAmt > 0) {
      result.deducted.push({ name, qty: deductedAmt, unit });
    }

    if (remaining > 0) {
      if (!allowMismatch && diffUnit.length > 0) {
        result.skipped.push({ name, qty: remaining, unit, reason: 'unit-mismatch' });
      } else {
        result.skipped.push({ name, qty: remaining, unit, reason: 'no-stock' });
      }
    }
  }

  saveInventory(inv);
  return result;
}

export function addInventoryQty(inv, name, qty, unit, kind='raw'){
  const canonical = getCanonicalName(name);
  const itemKind = kind === 'dry' || isDryGoodName(canonical) ? 'dry' : kind;
  const itemUnit = unit || (itemKind === 'dry' ? getDryGoodConfig(canonical)?.unit : '') || 'g';
  const e=inv.find(x=>x.name===canonical && (x.kind||'raw')===itemKind);
  if(e){
    e.qty=(+e.qty||0)+qty;
    e.unit=itemUnit||e.unit;
    e.buyDate=e.buyDate||todayISO();
    e.stockStatus='ok';
    if(itemKind === 'dry') { e.shelf = 365; e.dryPrep = getDryPrepText(canonical); e.isFrozen = false; }
  } else {
    inv.push({name: canonical, qty, unit:itemUnit, buyDate:todayISO(), kind:itemKind, shelf:guessShelfDays(canonical, itemUnit), stockStatus:'ok', ...(itemKind === 'dry' ? {dryPrep:getDryPrepText(canonical), isFrozen:false} : {})});
  }
  saveInventory(inv);
}
