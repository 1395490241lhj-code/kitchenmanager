import { S, todayISO } from './storage.js?v=98';
import {
  INGREDIENT_ALIASES,
  getCanonicalName,
  getDryGoodConfig,
  getDryPrepText,
  guessShelfDays,
  isDryGoodName
} from './ingredients.js?v=1';

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
  return (inv || []).filter(item => isInventoryAvailable(item) && isIngredientMatch(recipeName, item.name));
}

export function getStockCoverageForNeed(inv, recipeName, qty, unit) {
  const matchedItems = getMatchingInventoryItems(inv, recipeName);
  if (!matchedItems.length) return 0;
  const sameUnitStock = matchedItems
    .filter(item => (item.unit || '') === (unit || ''))
    .reduce((sum, item) => sum + (+item.qty || 0), 0);
  if (sameUnitStock > 0) return sameUnitStock;
  if (matchedItems.some(item => (item.stockStatus || 'ok') === 'ok' && (+item.qty || 0) > 0)) return +qty || 1;
  if (matchedItems.some(item => (+item.qty || 0) > 0)) return +qty || 1;
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
export function remainingDays(e){ const age=daysBetween(e.buyDate||todayISO(), todayISO()); return (+e.shelf||7)-age; }

export function upsertInventory(inv, e){
  const i=inv.findIndex(x=>x.name===e.name && (x.kind||'raw')===(e.kind||'raw'));
  if(i>=0) inv[i]={...inv[i],...e};
  else inv.push(e);
  saveInventory(inv);
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
