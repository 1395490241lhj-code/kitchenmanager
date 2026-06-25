import { S, todayISO } from './storage.js?v=222';
import {
  UNIT_TYPE,
  getCanonicalName,
  getDryGoodConfig,
  getDryPrepText,
  getIngredientMatchNames as getSmartIngredientMatchNames,
  getUnitType,
  guessShelfDays,
  isDryGoodName,
  isSmartIngredientMatch
} from './ingredients.js?v=222';
import { isSeasoningName } from './utils/recipe-sanitizer.js?v=222';

export const FROZEN_DEFAULT_SHELF_DAYS = 30;

export const INVENTORY_STATES = [
  { value: 'ok', label: '够用', className: 'ok' },
  { value: 'low', label: '快没了', className: 'low' },
  { value: 'empty', label: '没有', className: 'empty' },
  { value: 'unknown', label: '不确定', className: 'unknown' }
];

export function getIngredientMatchNames(name) {
  return getSmartIngredientMatchNames(name);
}

export function isIngredientMatch(recipeName, stockName) {
  return isSmartIngredientMatch(recipeName, stockName);
}

export function isInventoryAvailable(item) {
  return item && item.stockStatus !== 'empty' && (+item.qty || 0) > 0;
}

/* ══════════════════════════════════════════════════════════════════════════
 * 断货物资智能生命周期（TTL 自蒸发）
 *  - 任一会改变存量/档位的操作后调用 syncOutOfStockTimestamp：
 *      · 断货（数量≤0 / 状态 empty / 档位 0）→ 若尚无时间戳则盖 outOfStockAt = Date.now()
 *      · 复活（数量>0 / 档位提升）→ 强制 outOfStockAt = null
 *  - 渲染前用 OUT_OF_STOCK_TTL_MS 过滤：断货超 7 天的食材物理蒸发。
 * ══════════════════════════════════════════════════════════════════════════ */
export const OUT_OF_STOCK_TTL_MS = 7 * 24 * 60 * 60 * 1000; // 7天（如需 10 天改为 10 * 24 * 60 * 60 * 1000）

// 判定食材当前是否「断货 / 没有」：数量≤0、状态 empty，或档位降到 0。
export function isOutOfStock(item) {
  if (!item) return false;
  if (item.stockStatus === 'empty') return true;
  if ((+item.qty || 0) <= 0) return true;
  if (typeof item.gear === 'number' && gearInfo(item.gear).value <= 0) return true;
  return false;
}

// 断货 → 打/保留时间戳；复活 → 清空时间戳。返回 item 以便链式调用。
export function syncOutOfStockTimestamp(item) {
  if (!item) return item;
  if (isOutOfStock(item)) {
    if (!item.outOfStockAt) item.outOfStockAt = Date.now();
  } else {
    item.outOfStockAt = null;
  }
  return item;
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
  if(!item || item.stockStatus === 'empty' || (+item.qty || 0) <= 0) return '厨房里没有';
  const amount = formatInventoryAmount({...item, unit: item.unit || unit});
  const state = inventoryStateInfo(item.stockStatus).label;
  return `厨房有：${amount} · ${state}`;
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
      if (entry.isFrozen !== undefined) {
        exact.isFrozen = entry.isFrozen;
        if (entry.isFrozen === true && entryKind !== 'dry') {
          const currentRemaining = remainingDays(exact);
          if (!(currentRemaining >= FROZEN_DEFAULT_SHELF_DAYS)) {
            exact.buyDate = todayISO();
            exact.shelf = FROZEN_DEFAULT_SHELF_DAYS;
          }
        }
      }
      if (entryKind === 'dry') {
        exact.shelf = 365;
        exact.dryPrep = getDryPrepText(entry.name);
        exact.isFrozen = false;
      }
      syncOutOfStockTimestamp(exact); // 再入库 → 复活，清空断货时间戳
    } else {
      // 名称相同但单位不同（或尚未存在）→ 新增批次
      inv.push(syncOutOfStockTimestamp({ ...entry }));
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
      syncOutOfStockTimestamp(batch); // 做菜扣减后捕捉断货时间戳
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
        syncOutOfStockTimestamp(batch); // 做菜扣减后捕捉断货时间戳
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
    syncOutOfStockTimestamp(e); // 补货复活 → 清空断货时间戳
  } else {
    inv.push({name: canonical, qty, unit:itemUnit, buyDate:todayISO(), kind:itemKind, shelf:guessShelfDays(canonical, itemUnit), stockStatus:'ok', outOfStockAt: null, ...(itemKind === 'dry' ? {dryPrep:getDryPrepText(canonical), isFrozen:false} : {})});
  }
  saveInventory(inv);
}

/* ══════════════════════════════════════════════════════════════════════════
 * 档位（GEAR / 油表）模型 + 做菜「预扣减」核心算法
 *  - 档位刻度统一为 [100,75,50,25,0] → 充足 / 大半 / 一半 / 见底 / 断货。
 *  - PIECE：按菜谱声明数量整数相减。
 *  - GEAR：当前档位索引自动向后移动一位（充足→大半→一半→见底→断货）。
 * ══════════════════════════════════════════════════════════════════════════ */
export const GEAR_SCALE = [100, 75, 50, 25, 0];
export const GEAR_LABELS = { 100: '充足', 75: '大半', 50: '一半', 25: '见底', 0: '断货' };

// 把任意数值吸附到最近的档位，返回 { value, index, label }。
export function gearInfo(value) {
  const v = Number(value);
  const snapped = GEAR_SCALE.reduce((best, g) =>
    Math.abs(g - v) < Math.abs(best - v) ? g : best, GEAR_SCALE[0]);
  const index = GEAR_SCALE.indexOf(snapped);
  return { value: snapped, index, label: GEAR_LABELS[snapped] };
}

// 档位降一级（已到断货则保持断货）。
export function nextGearDown(value) {
  const { index } = gearInfo(value);
  return GEAR_SCALE[Math.min(index + 1, GEAR_SCALE.length - 1)];
}

// 读出某库存项当前档位：优先 item.gear，否则从 stockStatus / qty 推导。
export function getItemGear(item) {
  if (!item) return 0;
  if (typeof item.gear === 'number') return gearInfo(item.gear).value;
  if (item.stockStatus === 'empty' || (+item.qty || 0) <= 0) return 0;
  if (item.stockStatus === 'low') return 25;
  return 100; // ok / unknown 视为充足
}

// 写回某库存项的档位，并同步 stockStatus / qty 以兼容旧逻辑。
function setItemGear(item, gearValue) {
  const g = gearInfo(gearValue).value;
  item.gear = g;
  item.unitType = UNIT_TYPE.GEAR;
  if (g === 0) { item.stockStatus = 'empty'; item.qty = 0; }
  else if (g <= 25) { item.stockStatus = 'low'; item.qty = (+item.qty > 0) ? item.qty : 1; }
  else { item.stockStatus = 'ok'; item.qty = (+item.qty > 0) ? item.qty : 1; }
  syncOutOfStockTimestamp(item); // 档位变更（含降到断货 / 提升复活）同步时间戳
}

/**
 * 计算做完一道菜后的「预扣减」结果（只计算、不写库）。
 * 仅纳入当前库存里有匹配的食材（你冰箱里真实存在、这道菜会消耗的）。
 * @param {Array} coreItems 菜谱核心食材（已 explode，形如 {item, qty, unit}）
 * @param {Array} inv       当前库存
 * @returns {Array} 每项：
 *   { name, unitType, match,
 *     unit, recipeQty, currentQty, predictedQty,   // PIECE
 *     currentGear, predictedGear }                  // GEAR
 */
export function computeCookDeductions(coreItems, inv) {
  const rows = [];
  const seen = new Set();
  for (const it of (coreItems || [])) {
    if (!it || !it.item) continue;
    // 【规则1】调料彻底免扣：盐糖油酱醋 / 水高汤 / 姜葱蒜等常备调味与非追踪物资一律跳过，
    //          绝不参与冰箱主库扣减与对账。
    if (isSeasoningName(it.item)) continue;
    // 【规则2】幽灵防御：冰箱里原本没有这项食材 → 直接跳过，
    //          绝不为从未拥有的资产初始化数量 0 / 断货的新卡片。
    const match = getMatchingInventoryItems(inv, it.item)[0] || null;
    if (!match) continue;
    if (seen.has(match)) continue; // 同一库存项只出现一次
    seen.add(match);

    const name = getCanonicalName(it.item) || it.item;
    const unitType = getUnitType(name, match.unit || it.unit);

    if (unitType === UNIT_TYPE.PIECE) {
      const currentQty = +match.qty || 0;
      const useQty = Math.max(1, Math.round(+it.qty || 1));
      rows.push({
        name, unitType, match,
        unit: match.unit || it.unit || '个',
        recipeQty: useQty,
        currentQty,
        predictedQty: Math.max(0, currentQty - useQty)
      });
    } else {
      const currentGear = getItemGear(match);
      rows.push({
        name, unitType, match,
        unit: match.unit || it.unit || '',
        currentGear,
        predictedGear: nextGearDown(currentGear)
      });
    }
  }
  return rows;
}

/**
 * 把「主厨校准舱」最终确认的结果持久化写入库存。
 * @param {Array} calibrations [{ match, unitType, finalQty(PIECE), finalGear(GEAR) }]
 */
export function applyCookCalibration(inv, calibrations) {
  for (const c of (calibrations || [])) {
    // 🛑 幽灵防护：只对「冰箱里原本就存在」的食材执行扣减 / 降档。
    //    找不到现有库存项（c.match 不在 inv，且按名也查不到）→ 直接跳过，
    //    绝不为未曾拥有的食材凭空 push 一个数量 0 / 断货的新卡片。
    const item = (c.match && inv.includes(c.match)) ? c.match : findStockItem(inv, c.name);
    if (!item) continue;
    if (c.unitType === UNIT_TYPE.PIECE) {
      const q = Math.max(0, Math.round(+c.finalQty || 0));
      item.qty = q;
      item.unitType = UNIT_TYPE.PIECE;
      item.stockStatus = q <= 0 ? 'empty' : 'ok';
      syncOutOfStockTimestamp(item); // 计件校准（含扣到 0）同步时间戳
    } else {
      setItemGear(item, c.finalGear); // GEAR 路径内部已 sync
    }
  }
  saveInventory(inv);
  return inv;
}
