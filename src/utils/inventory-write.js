/*
 * src/utils/inventory-write.js —— 批量入库统一写入（从 home-view 抽出的共享数据落地路径）。
 * 所有批量录入模式（示例厨房 / 拍小票 / 文本批量记）共用这一条写库逻辑，纯数据、无 DOM。
 */
import { todayISO } from '../storage.js?v=230';
import { buildCatalog, getCanonicalName, getDryPrepText, guessKitchenUnit, guessShelfDays, isDryGoodName } from '../ingredients.js?v=230';
import { loadInventory, mergeInventoryEntry } from '../inventory.js?v=230';
import { applyReceiptPantryItems } from './receipt-import.js?v=230';

// ── 批量入库统一写入：所有模式（小票 / 文本）共用同一条数据落地路径 ──────────
export function writeItemsToInventory(items, pack) {
  if (!Array.isArray(items) || !items.length) return 0;
  const catalog = buildCatalog(pack);
  const inv = loadInventory(catalog);
  const today = todayISO();
  let count = 0;
  for (const it of items) {
    const name = getCanonicalName(it.name || it.item || '');
    if (!name) continue;
    const qty = Number(it.qty);
    const safeQty = Number.isFinite(qty) && qty > 0 ? qty : 1;
    const unit = (it.unit && String(it.unit).trim()) || guessKitchenUnit(name) || '份';
    const kind = isDryGoodName(name) ? 'dry' : 'raw';
    const shelf = kind === 'dry' ? 365 : guessShelfDays(name, unit);
    const entry = { name, qty: safeQty, unit, buyDate: today, kind, shelf, stockStatus: 'ok' };
    if (kind === 'dry') { entry.dryPrep = getDryPrepText(name); entry.isFrozen = false; }
    mergeInventoryEntry(inv, entry, { mode: 'add' });
    count++;
  }
  return count;
}

export function writeReceiptPantryItems(items, pack) {
  if (!Array.isArray(items) || !items.length) return 0;
  const catalog = buildCatalog(pack);
  const inv = loadInventory(catalog);
  return applyReceiptPantryItems(items, inv);
}
