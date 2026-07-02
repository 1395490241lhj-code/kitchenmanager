/*
 * src/utils/cooked-meal.js
 *
 * “记录做完”入口的纯逻辑：只负责把自然语言转换成候选库存项。
 * 不读写 localStorage，不操作 DOM；真正扣减仍由首页确认弹窗调用 inventory 逻辑。
 */
import {
  explodeCombinedItems,
  getCanonicalName,
  getIngredientFamilyCandidates,
  guessKitchenUnit,
  isSmartIngredientMatch
} from '../ingredients.js?v=230';
import { classifyRecipeIngredient } from './recipe-sanitizer.js?v=230';
import { isInventoryAvailable } from '../inventory.js?v=230';

function compactText(text) {
  return String(text || '')
    .toLowerCase()
    .replace(/\s+/g, '')
    .replace(/[，,、/／\\;；:：。.!！?？'"“”‘’（）()【】[\]{}《》<>-]/g, '');
}

function normalizeDishText(text) {
  return compactText(text)
    .replace(/^我?(刚刚|刚|今天|今晚|晚上|中午|早上)?(做了|做|炒了|炒|煮了|煮|炖了|炖|蒸了|蒸|烤了|烤|弄了|弄|吃了|吃)(一道|一个|个)?/, '')
    .replace(/西红柿/g, '番茄')
    .replace(/鸡蛋/g, '蛋');
}

function splitMealTokens(text) {
  return String(text || '')
    .replace(/我刚刚|我刚|刚刚|今天|今晚|晚上|中午|早上|做了|炒了|煮了|炖了|蒸了|烤了|弄了|吃了/g, ' ')
    .split(/[\s,，、/／\\;；和跟与及+＋]+/)
    .map(token => token.trim())
    .filter(Boolean);
}

function isCoreName(name) {
  return !!name && classifyRecipeIngredient(name).role === 'core';
}

function availableCoreInventory(inventory) {
  return (inventory || [])
    .filter(item => item && isInventoryAvailable(item))
    .filter(item => isCoreName(item.name));
}

export function matchCookedMealRecipe(text, recipes = []) {
  const raw = normalizeDishText(text);
  if (!raw || raw.length < 2) return null;

  let best = null;
  for (const recipe of recipes || []) {
    if (!recipe || !recipe.name) continue;
    const name = normalizeDishText(recipe.name);
    if (!name) continue;

    let score = 0;
    if (raw === name) score = 120;
    else if (raw.includes(name)) score = 100 + Math.min(20, name.length);
    else if (name.includes(raw) && raw.length >= 3) score = 72 + raw.length;

    if (score > (best?.score || 0)) best = { recipe, score };
  }

  return best && best.score >= 72 ? best.recipe : null;
}

export function getRecipeCoreItems(recipe, pack) {
  if (!recipe || !pack) return [];
  const rawItems = explodeCombinedItems((pack.recipe_ingredients || {})[recipe.id] || []);
  return rawItems
    .filter(item => item && item.item)
    .filter(item => isCoreName(item.item))
    .map(item => ({
      item: item.item,
      qty: Number.isFinite(Number(item.qty)) && Number(item.qty) > 0 ? Number(item.qty) : 1,
      unit: item.unit || guessKitchenUnit(item.item) || '',
      reason: '来自菜谱'
    }));
}

function nameMentionedByText(text, inventoryName) {
  const compact = compactText(text);
  const name = getCanonicalName(inventoryName || '') || String(inventoryName || '').trim();
  if (!name) return false;

  const candidates = [
    name,
    inventoryName,
    ...getIngredientFamilyCandidates(name, { canonicalize: false })
  ]
    .map(candidate => getCanonicalName(candidate) || candidate)
    .filter(Boolean);

  for (const candidate of new Set(candidates)) {
    const needle = compactText(candidate);
    if (needle.length >= 2 && compact.includes(needle)) return true;
  }

  return splitMealTokens(text).some(token => isSmartIngredientMatch(token, name));
}

export function findCookedMealInventoryMatch(inventory, name) {
  const target = String(name || '').trim();
  if (!target || !isCoreName(target)) return null;
  return availableCoreInventory(inventory).find(item => isSmartIngredientMatch(target, item.name)) || null;
}

export function buildLocalCookedMealCandidates(text, inventory) {
  const raw = String(text || '').trim();
  if (!raw) return [];
  const seen = new Set();
  const candidates = [];

  for (const item of availableCoreInventory(inventory)) {
    if (!nameMentionedByText(raw, item.name)) continue;
    const canonical = getCanonicalName(item.name) || item.name;
    if (seen.has(canonical)) continue;
    seen.add(canonical);
    candidates.push({
      item: item.name,
      qty: 1,
      unit: item.unit || guessKitchenUnit(item.name) || '份',
      reason: '你刚刚提到',
      matchName: item.name
    });
  }

  return candidates;
}

export function normalizeAiCookedMealResult(result, inventory) {
  const source = result && typeof result === 'object' ? result : {};
  const dishes = Array.isArray(source.dishes) ? source.dishes : [];
  const seen = new Set();
  const candidates = [];

  for (const dish of dishes) {
    const used = Array.isArray(dish?.usedIngredients) ? dish.usedIngredients : [];
    for (const ingredient of used) {
      const name = String(ingredient?.name || ingredient?.item || '').trim();
      const match = findCookedMealInventoryMatch(inventory, name);
      if (!match) continue;
      const canonical = getCanonicalName(match.name) || match.name;
      if (seen.has(canonical)) continue;
      seen.add(canonical);
      const qty = Number(ingredient?.qty);
      candidates.push({
        item: match.name,
        qty: Number.isFinite(qty) && qty > 0 ? qty : 1,
        unit: ingredient?.unit || match.unit || guessKitchenUnit(match.name) || '份',
        reason: ingredient?.reason || 'AI 推测，需确认',
        matchName: match.name
      });
    }
  }

  return {
    dishes: dishes.map(dish => ({
      name: String(dish?.name || '').trim(),
      matchedRecipeName: String(dish?.matchedRecipeName || '').trim()
    })).filter(dish => dish.name || dish.matchedRecipeName),
    candidates,
    needsReview: source.needsReview !== false
  };
}

export function mergeCookedMealCandidates(...groups) {
  const map = new Map();
  for (const group of groups) {
    for (const item of group || []) {
      const name = item?.item || item?.name || item?.matchName;
      if (!name || !isCoreName(name)) continue;
      const key = getCanonicalName(name) || name;
      if (!map.has(key)) {
        map.set(key, {
          item: name,
          qty: Number.isFinite(Number(item.qty)) && Number(item.qty) > 0 ? Number(item.qty) : 1,
          unit: item.unit || guessKitchenUnit(name) || '份',
          reason: item.reason || '需确认',
          matchName: item.matchName || name
        });
      }
    }
  }
  return [...map.values()];
}
