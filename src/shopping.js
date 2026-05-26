import { S } from './storage.js?v=98';
import { getCanonicalName } from './ingredients.js?v=1';

export function genId(){
  return 'u-' + Math.random().toString(36).slice(2,8) + '-' + Date.now().toString(36).slice(-4);
}

export function loadShoppingItems() {
  return S.load(S.keys.shopping_items, []).filter(item => item && item.name).map(item => ({
    id: item.id || genId(),
    name: String(item.name || '').trim(),
    qty: item.qty || '',
    unit: item.unit || '',
    source: item.source || '手动',
    done: !!item.done
  }));
}

export function saveShoppingItems(items) {
  return S.save(S.keys.shopping_items, items.filter(item => item && item.name));
}

export function addShoppingItem(name, qty = '', unit = '', source = '手动') {
  const cleanName = getCanonicalName(name || '');
  if(!cleanName) return;
  const items = loadShoppingItems();
  const existing = items.find(item => item.name === cleanName && item.unit === unit && item.source === source && !item.done);
  if(existing) existing.qty = existing.qty || qty || 1;
  else items.push({ id: genId(), name: cleanName, qty: qty || '', unit: unit || '', source, done: false });
  saveShoppingItems(items);
}
