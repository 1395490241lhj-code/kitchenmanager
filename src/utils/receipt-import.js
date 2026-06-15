import {
  getCanonicalName,
  getDryPrepText,
  guessKitchenUnit
} from '../ingredients.js?v=219';
import { mergeInventoryEntry } from '../inventory.js?v=219';
import {
  STAPLE_STATUS,
  addCustomPantryEntry,
  isStaple,
  loadPantryConfig,
  setStapleStatus
} from '../staples.js?v=219';
import { todayISO } from '../storage.js?v=219';

function hasCustomPantryEntry(name) {
  const canonical = getCanonicalName(name || '');
  const config = loadPantryConfig();
  return (config.custom || []).some(item =>
    item && item.type === 'pantry' && getCanonicalName(item.name) === canonical
  );
}

export function applyReceiptPantryItems(items, inv) {
  if (!Array.isArray(items) || !items.length || !Array.isArray(inv)) return 0;
  let count = 0;
  for (const item of items) {
    const name = getCanonicalName(item.name || item.item || '');
    if (!name) continue;
    const unit = (item.unit && String(item.unit).trim()) || guessKitchenUnit(name) || '份';
    const qty = Number(item.qty);
    const safeQty = Number.isFinite(qty) && qty > 0 ? qty : 1;

    if (isStaple(name)) {
      setStapleStatus(name, STAPLE_STATUS.SUFFICIENT);
      count++;
      continue;
    }

    if (!hasCustomPantryEntry(name)) {
      addCustomPantryEntry({
        name,
        group: '干货',
        type: 'pantry',
        kind: 'dry',
        unit,
        source: '常备干货',
        prep: getDryPrepText(name)
      });
    }

    mergeInventoryEntry(inv, {
      name,
      qty: safeQty,
      unit,
      buyDate: todayISO(),
      kind: 'dry',
      shelf: 365,
      stockStatus: 'ok',
      dryPrep: getDryPrepText(name),
      isFrozen: false
    }, { mode: 'add' });
    count++;
  }
  return count;
}
